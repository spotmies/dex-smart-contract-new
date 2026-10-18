import type { Request, Response } from 'express';
import PerpTrade, { type IPerpTrade, TradeType, TradeStatus } from '../models/PerpTrade.js';
import dotenv from 'dotenv';
dotenv.config();

import User from '../models/User.js';
import { normalizeAddress } from '../utils/addressUtils.js';
import { loadConfirmedTx, involvesWallet, VerifyError } from '../utils/chainVerify.js';

const MARKET_ADDRESS = process.env.PERP_MARKET_ADDRESS || "0x_UNKNOWN_MARKET";

const NUM_RE = /^\d{1,40}(\.\d{1,30})?$/;           // unsigned decimal string
const SIGNED_NUM_RE = /^-?\d{1,40}(\.\d{1,30})?$/;   // pnl may be negative
const SYMBOL_RE = /^[A-Za-z0-9]{2,12}$/;
const TYPES = new Set(['OPEN_LONG', 'OPEN_SHORT', 'CLOSE_LONG', 'CLOSE_SHORT', 'LIQUIDATION']);

export const createTrade = async (req: Request, res: Response): Promise<void> => {
    try {
        // legacy 'amount' mapped to 'size' if needed
        const { positionId, type, tokenSymbol, amount, size, collateral, price, pnl, txHash } = req.body;

        // The trade belongs to the signed-in wallet. A body-supplied walletAddress is never trusted.
        // @ts-ignore
        const walletAddress = normalizeAddress(req.user?.walletAddress);
        if (!walletAddress) {
            res.status(401).json({ message: 'Not authorized' });
            return;
        }
        if (req.body.walletAddress !== undefined && normalizeAddress(req.body.walletAddress) !== walletAddress) {
            res.status(403).json({ message: 'walletAddress does not match your session' });
            return;
        }

        // Normalize size
        const tradeSize = size || amount;

        if (!positionId || !type || !tokenSymbol || !tradeSize || !price || !txHash) {
            res.status(400).json({ message: 'Missing required fields' });
            return;
        }
        if (
            !/^\d{1,20}$/.test(String(positionId)) || !TYPES.has(String(type)) || !SYMBOL_RE.test(String(tokenSymbol)) ||
            !NUM_RE.test(String(tradeSize)) || !NUM_RE.test(String(price)) ||
            (collateral !== undefined && !NUM_RE.test(String(collateral))) ||
            (pnl !== undefined && pnl !== null && !SIGNED_NUM_RE.test(String(pnl)))
        ) {
            res.status(400).json({ message: 'Invalid field format' });
            return;
        }

        // The transaction must be confirmed on-chain, succeeded, touch the perp contracts, and involve this wallet.
        const perpContracts = [process.env.PERP_ROUTER_ADDRESS, process.env.PERP_POSITION_MANAGER_ADDRESS, process.env.PERP_MARKET_ADDRESS];
        const confirmed = await loadConfirmedTx(txHash);
        const to = confirmed.tx.to?.toLowerCase();
        if (!to || !perpContracts.some((a) => a?.toLowerCase() === to)) {
            res.status(422).json({ message: 'Transaction was not sent to the perps contracts' });
            return;
        }
        if (!involvesWallet(confirmed, walletAddress, perpContracts)) {
            res.status(403).json({ message: 'This transaction does not involve your wallet' });
            return;
        }

        // Ownership: a positionId already recorded for someone else cannot be overwritten.
        const owner = await PerpTrade.findOne({ positionId: String(positionId) }).select('walletAddress');
        if (owner && owner.walletAddress.toLowerCase() !== walletAddress) {
            res.status(403).json({ message: 'This position belongs to another wallet' });
            return;
        }

        const isClose = type.toString().startsWith('CLOSE');
        const side = type.toString().includes('LONG') ? TradeType.LONG : TradeType.SHORT;

        if (!isClose) {
            // OPEN TRADE (Optimistic UI update)
            // We use upsert so if listener beat us, we just update/confirm
            const trade = await PerpTrade.findOneAndUpdate(
                { positionId },
                {
                    walletAddress,
                    positionId,
                    type: side,
                    tokenSymbol,
                    market: MARKET_ADDRESS,
                    size: tradeSize,
                    collateral: collateral || "0", // Frontend might not send collateral initially if legacy
                    entryPrice: price,
                    status: TradeStatus.OPEN,
                    openTxHash: txHash
                },
                { upsert: true, returnDocument: "after", setDefaultsOnInsert: true }
            );

            // Referral Logic
            try {
                // H1: validate address format before use in query (prevents regex injection/ReDoS)
                const perpAddr = normalizeAddress(walletAddress);
                if (perpAddr) {
                    const currentUser = await User.findOne({ walletAddress: { $regex: `^${perpAddr}$`, $options: 'i' } });
                    if (currentUser && !currentUser.hasDoneFirstTrade) {
                        if (currentUser.referredBy) {
                            const refAddr = normalizeAddress(currentUser.referredBy);
                            if (refAddr) {
                                await User.updateOne(
                                    { walletAddress: { $regex: `^${refAddr}$`, $options: 'i' } },
                                    { $inc: { referralPoints: 100 } }
                                );
                                console.log(`Referral Reward (Perp): received 100 points for referring ${perpAddr}`);
                            }
                        }
                        currentUser.hasDoneFirstTrade = true;
                        await currentUser.save();
                    }
                }
            } catch (refError) {
                console.error("Referral Logic Error (Perp):", refError);
            }

            res.status(201).json(trade);
        } else {
            // CLOSE TRADE
            // Update existing
            const trade = await PerpTrade.findOneAndUpdate(
                { positionId },
                {
                    status: TradeStatus.CLOSED,
                    exitPrice: price,
                    pnl: pnl,
                    closeTxHash: txHash,
                    closedAt: new Date(),
                    size: "0", // Assume full close if frontend says Close? 
                    // Frontend 'CLOSE' usually implies full close in this context unless partial specified
                    collateral: "0"
                },
                { returnDocument: "after" }
            );

            if (trade) {
                res.status(200).json(trade);
            } else {
                // Orphaned close handling
                console.warn(`Orphaned close for position ${positionId}`);
                // Create a record anyway?
                const orphan = await PerpTrade.create({
                    walletAddress,
                    positionId,
                    type: side,
                    tokenSymbol,
                    market: MARKET_ADDRESS,
                    size: "0",
                    collateral: "0",
                    entryPrice: "0",
                    exitPrice: price,
                    pnl,
                    status: TradeStatus.CLOSED,
                    openTxHash: "unknown",
                    closeTxHash: txHash,
                    closedAt: new Date()
                });
                res.status(201).json(orphan);
            }
        }
    } catch (error: any) {
        if (error instanceof VerifyError) {
            res.status(error.status).json({ message: error.message });
            return;
        }
        console.error("Create Trade Error:", error);
        res.status(500).json({ message: 'Error saving trade' });
    }
};

export const getTradesByAddress = async (req: Request, res: Response): Promise<void> => {
    try {
        const addr = normalizeAddress(req.params.walletAddress);
        // @ts-ignore
        const wallet = normalizeAddress(req.user?.walletAddress);
        if (!addr) {
            res.status(400).json({ message: 'A valid wallet address is required' });
            return;
        }
        // Trade history is private: only the owner may read it.
        if (addr !== wallet) {
            res.status(403).json({ message: 'You can only view your own trade history' });
            return;
        }

        // Older rows may hold a mixed-case address, so match case-insensitively (addr is validated hex).
        const trades = await PerpTrade.find({ walletAddress: { $regex: `^${addr}$`, $options: 'i' } }).sort({ timestamp: -1 });
        res.status(200).json(trades);
    } catch (error: any) {
        console.error("Error fetching trades:", error);
        res.status(500).json({ message: 'Error fetching trades' });
    }
};
