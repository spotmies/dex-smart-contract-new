import type { Request, Response } from 'express';
import BlockchainService from '../services/BlockchainService.js';
import Trade from '../models/Trade.js';
import User from '../models/User.js';
import Complaint from '../models/Complaint.js';
import { normalizeAddress } from '../utils/addressUtils.js';
import { toTokens } from 'thirdweb';

const sameAddress = (a?: string, b?: string) => !!a && !!b && a.toLowerCase() === b.toLowerCase();

// Never leak RPC/internal error text to clients.
const CHAIN_UNAVAILABLE = 'Could not verify this trade on-chain. Please try again.';


// The client only names a purchaseId. Everything else (parties, amounts, state) is read from the escrow
// contract, and the caller must be the buyer or seller on-chain, so nobody can record a trade for someone else.
export const createTrade = async (req: Request, res: Response): Promise<void> => {
    try {
        const { purchaseId } = req.body;
        const pId = Number(purchaseId);
        if (purchaseId === undefined || !Number.isSafeInteger(pId) || pId < 0) {
            res.status(400).json({ error: "A valid purchaseId is required" });
            return;
        }

        // @ts-ignore
        const caller = req.user.walletAddress as string;

        let purchase;
        try {
            purchase = await BlockchainService.getPurchase(pId);
        } catch (e) {
            console.error("createTrade chain read failed:", e instanceof Error ? e.message : e);
            res.status(502).json({ error: CHAIN_UNAVAILABLE });
            return;
        }

        if (!sameAddress(caller, purchase.buyer) && !sameAddress(caller, purchase.seller)) {
            res.status(403).json({ error: "You are not a party to this trade" });
            return;
        }

        const existingTrade = await Trade.findOne({ purchaseId: pId });
        if (existingTrade) {
            res.status(400).json({ error: "Trade already exists" });
            return;
        }

        const buyer = purchase.buyer;
        const seller = purchase.seller;
        const newTrade = await Trade.create({
            purchaseId: pId,
            listingId: purchase.listingId,
            buyer,
            seller,
            quantity: Number(toTokens(purchase.quantityWei, await BlockchainService.getQuantityDecimals(purchase.listingId))),
            pricePerToken: Number(toTokens(purchase.pricePerTokenWei, 18)),
            status: purchase.status
        });

        // Referral Logic: Reward referrer if this is the first trade for buyer or seller
        const processReferral = async (address: string, role: string) => {
            try {
                // H1: validate address format before use in query (prevents regex injection/ReDoS)
                const addr = normalizeAddress(address);
                if (!addr) return;
                const user = await User.findOne({ walletAddress: { $regex: `^${addr}$`, $options: 'i' } });
                if (user && !user.hasDoneFirstTrade) {
                    if (user.referredBy) {
                        const refAddr = normalizeAddress(user.referredBy);
                        if (refAddr) {
                            await User.updateOne(
                                { walletAddress: { $regex: `^${refAddr}$`, $options: 'i' } },
                                { $inc: { referralPoints: 100 } }
                            );
                            console.log(`Referral Reward (P2P ${role}): received 100 points for referring ${addr}`);
                        }
                    }
                    user.hasDoneFirstTrade = true;
                    await user.save();
                }
            } catch (refError) {
                console.error(`Referral Logic Error (P2P ${role}):`, refError);
            }
        };

        await processReferral(buyer, 'Buyer');
        await processReferral(seller, 'Seller');

        res.status(201).json(newTrade);
    } catch (error: any) {
        console.error("Create Trade Error:", error);
        res.status(500).json({ error: error.message || "Internal Server Error" });
    }
};

export const releaseFunds = async (req: Request, res: Response): Promise<void> => {
    console.log("Release funds got hit...")
    try {
        const { purchaseId } = req.body;

        if (purchaseId === undefined) {
            res.status(400).json({ error: "purchaseId is required" });
            return;
        }

        // @ts-ignore
        const userWallet = req.user.walletAddress as string;
        // H1: normalize address from session before use in query
        const walletAddr = normalizeAddress(userWallet);
        if (!walletAddr) {
            res.status(400).json({ error: 'Invalid wallet address in session' });
            return;
        }

        // On-chain check: only the escrow's recorded seller may trigger a release, and only while it is releasable.
        let purchase;
        try {
            purchase = await BlockchainService.getPurchase(Number(purchaseId));
        } catch (e) {
            console.error("releaseFunds chain read failed:", e instanceof Error ? e.message : e);
            res.status(502).json({ error: CHAIN_UNAVAILABLE });
            return;
        }
        if (!sameAddress(walletAddr, purchase.seller)) {
            res.status(403).json({ error: "Only the seller of this trade can release funds" });
            return;
        }
        if (purchase.status !== 'Locked' && purchase.status !== 'Disputed') {
            res.status(409).json({ error: `Trade is ${purchase.status} and cannot be released` });
            return;
        }

        // 2. Call Blockchain Service (throws if the transaction reverts)
        const txHash = await BlockchainService.releasePurchase(Number(purchaseId));

        // 3. Update DB
        await Trade.findOneAndUpdate({ purchaseId: Number(purchaseId) }, { status: 'Released' });

        console.log("Funds released successfully via Backend");

        res.status(200).json({ message: "Funds released successfully", txHash });

    } catch (error: any) {
        console.error("Release Funds Error:", error);
        res.status(500).json({ error: error.message || "Internal Server Error" });
    }
};


export const getTradesByUser = async (req: Request, res: Response): Promise<void> => {
    try {
        const { address } = req.params;

        if (!address) {
            res.status(400).json({ error: "Address is required" });
            return;
        }

        // H1: validate address format before use in query (prevents regex injection/ReDoS)
        const addr = normalizeAddress(address);
        if (!addr) {
            res.status(400).json({ error: "Invalid wallet address" });
            return;
        }

        const trades = await Trade.find({
            $or: [
                { buyer: { $regex: `^${addr}$`, $options: 'i' } },
                { seller: { $regex: `^${addr}$`, $options: 'i' } }
            ]
        }).sort({ createdAt: -1 });

        res.status(200).json(trades);
    } catch (error: any) {
        console.error("Get User Trades Error:", error);
        res.status(500).json({ error: error.message || "Internal Server Error" });
    }
};


export const reportNotReceived = async (req: Request, res: Response): Promise<void> => {
    console.log("Report not received got hit...")
    try {
        const { purchaseId } = req.body;

        if (purchaseId === undefined) {
            res.status(400).json({ error: "purchaseId is required" });
            return;
        }

        // @ts-ignore
        const userWallet = req.user.walletAddress as string;
        // H1: normalize address from session before use in query
        const walletAddr = normalizeAddress(userWallet);
        if (!walletAddr) {
            res.status(400).json({ error: 'Invalid wallet address in session' });
            return;
        }

        let purchase;
        try {
            purchase = await BlockchainService.getPurchase(Number(purchaseId));
        } catch (e) {
            console.error("reportNotReceived chain read failed:", e instanceof Error ? e.message : e);
            res.status(502).json({ error: CHAIN_UNAVAILABLE });
            return;
        }
        if (!sameAddress(walletAddr, purchase.seller)) {
            res.status(403).json({ error: "Only the seller of this trade can report non-receipt" });
            return;
        }
        if (purchase.status !== 'Locked') {
            res.status(409).json({ error: `Trade is ${purchase.status}; only a locked trade can be disputed` });
            return;
        }

        // Update status to Disputed (index only; the contract's dispute flow is separate)
        await Trade.findOneAndUpdate({ purchaseId: Number(purchaseId) }, { status: 'Disputed' });

        // Create Complaint entry
        await Complaint.create({
            purchaseId: Number(purchaseId),
            reporter: walletAddr,
            reason: 'Seller reported payment not received'
        });

        console.log(`Trade ${purchaseId} reported as not received and status updated to Disputed`);

        res.status(200).json({ message: "Report submitted successfully. Our team will review the case." });

    } catch (error: any) {
        console.error("Report Not Received Error:", error);
        res.status(500).json({ error: error.message || "Internal Server Error" });
    }
};

export const createTradeMetadata = async (data: any) => {
    return await Trade.create(data);
};
