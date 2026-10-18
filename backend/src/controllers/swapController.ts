import type { Request, Response } from 'express';
import SwapTrade from '../models/SwapTrade.js';
import User from '../models/User.js';
import { normalizeAddress } from '../utils/addressUtils.js';
import {
    loadConfirmedTx, assertSentByTo, sumTransfers, sumWithdrawals, tokenDecimals, toHuman, VerifyError, ZERO_ADDRESS
} from '../utils/chainVerify.js';

export const storeSwap = async (req: Request, res: Response) => {
    try {
        const { tokenIn, tokenOut, txHash } = req.body;
        // @ts-ignore
        const wallet = normalizeAddress(req.user?.walletAddress);
        const tIn = normalizeAddress(tokenIn);
        const tOut = normalizeAddress(tokenOut);
        if (!wallet || !tIn || !tOut || !txHash) {
            return res.status(400).json({ error: "Missing or invalid fields" });
        }
        // A body-supplied userAddress is never trusted; if one is sent it must be the signed-in wallet.
        if (req.body.userAddress !== undefined && normalizeAddress(req.body.userAddress) !== wallet) {
            return res.status(403).json({ error: "userAddress does not match your session" });
        }

        // Idempotent: the same transaction is recorded once.
        const existing = await SwapTrade.findOne({ txHash: String(txHash).toLowerCase() });
        if (existing) {
            if (existing.userAddress !== wallet) return res.status(403).json({ error: "Transaction belongs to another wallet" });
            return res.status(200).json({ message: "Swap already recorded", swap: existing });
        }

        // Verify on-chain: confirmed, sent by this wallet to the DEX router; amounts come from the receipt, not the body.
        const confirmed = await loadConfirmedTx(txHash);
        const router = process.env.DEX_ROUTER_ADDRESS;
        assertSentByTo(confirmed, wallet, [router]);
        const { tx, receipt } = confirmed;

        const amountInRaw = tIn === ZERO_ADDRESS ? tx.value : sumTransfers(receipt, tIn, 'from', wallet);
        const amountOutRaw = tOut === ZERO_ADDRESS
            ? sumWithdrawals(receipt, router as string)
            : sumTransfers(receipt, tOut, 'to', wallet);
        if (amountInRaw <= 0n || amountOutRaw <= 0n) {
            return res.status(422).json({ error: "This transaction does not contain the swap described" });
        }
        const amountIn = toHuman(amountInRaw, tIn === ZERO_ADDRESS ? 18 : await tokenDecimals(tIn));
        const amountOut = toHuman(amountOutRaw, tOut === ZERO_ADDRESS ? 18 : await tokenDecimals(tOut));

        const newSwap = new SwapTrade({
            userAddress: wallet,
            tokenIn: tIn,
            tokenOut: tOut,
            amountIn,
            amountOut,
            txHash: String(txHash).toLowerCase()
        });

        await newSwap.save();

        // Referral Logic
        try {
            // H1: validate address format before use in query (prevents regex injection/ReDoS)
            const swapAddr = wallet;
            if (swapAddr) {
                const currentUser = await User.findOne({ walletAddress: { $regex: `^${swapAddr}$`, $options: 'i' } });
                if (currentUser && !currentUser.hasDoneFirstTrade) {
                    if (currentUser.referredBy) {
                        const refAddr = normalizeAddress(currentUser.referredBy);
                        if (refAddr) {
                            await User.updateOne(
                                { walletAddress: { $regex: `^${refAddr}$`, $options: 'i' } },
                                { $inc: { referralPoints: 100 } }
                            );
                            console.log(`Referral Reward (Swap): received 100 points for referring ${swapAddr}`);
                        }
                    }
                    currentUser.hasDoneFirstTrade = true;
                    await currentUser.save();
                }
            }
        } catch (refError) {
            console.error("Referral Logic Error (Swap):", refError);
        }

        res.status(201).json({ message: "Swap recorded successfully", swap: newSwap });
    } catch (error) {
        if (error instanceof VerifyError) return res.status(error.status).json({ error: error.message });
        console.error("Error storing swap:", error);
        res.status(500).json({ error: "Internal server error" });
    }
};

export const getSwapsByUser = async (req: Request, res: Response) => {
    try {
        const addr = normalizeAddress(req.params.userAddress);
        // @ts-ignore
        const wallet = normalizeAddress(req.user?.walletAddress);
        if (!addr) {
            return res.status(400).json({ error: "A valid user address is required" });
        }
        // Swap history is private: only the owner may read it.
        if (addr !== wallet) {
            return res.status(403).json({ error: "You can only view your own swap history" });
        }

        // Older rows may hold a checksummed (mixed-case) address, so match case-insensitively (addr is validated hex).
        const swaps = await SwapTrade.find({ userAddress: { $regex: `^${addr}$`, $options: 'i' } }).sort({ timestamp: -1 });
        res.json(swaps);
    } catch (error) {
        console.error("Error fetching swaps:", error);
        res.status(500).json({ error: "Internal server error" });
    }
};
