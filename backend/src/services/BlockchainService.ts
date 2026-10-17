
import dotenv from 'dotenv';
import Trade from '../models/Trade.js';
import Listing from '../models/Listing.js';
import User from '../models/User.js';
import { normalizeAddress } from '../utils/addressUtils.js';
// @ts-ignore
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import {
    getContract,
    prepareContractCall,
    sendTransaction,
    watchContractEvents,
    toTokens,
    waitForReceipt,
    prepareEvent,
    readContract
} from "thirdweb";
import { privateKeyToAccount } from "thirdweb/wallets";
import { client, chain, p2pChain } from "../utils/client.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ablPath = path.resolve(__dirname, '../../abl.json');
const abl = JSON.parse(fs.readFileSync(ablPath, 'utf8'));
const SC_ABI = abl.abi;

dotenv.config();

class BlockchainService {
    private account: any;
    private contract: any;
    private factoryContract: any;
    private isListening: boolean = false;

    constructor() {
        const privateKey = process.env.PRIVATE_KEY;
        const contractAddress = process.env.CONTRACT_ADDRESS;

        if (!privateKey || !contractAddress) {
            console.error("Missing Blockchain Config: PRIVATE_KEY or CONTRACT_ADDRESS");
            return;
        }

        // Initialize Account
        this.account = privateKeyToAccount({
            client: client,
            privateKey: privateKey
        });

        // Initialize Contract
        this.contract = getContract({
            client: client,
            chain: p2pChain,
            address: contractAddress,
            abi: SC_ABI
        });

        // Initialize Copy Trading Factory
        const factoryAddress = process.env.COPY_TRADING_FACTORY_ADDRESS || "0xe6e340d132b5f46d1e472debcd681b2abc16e57e";
        this.factoryContract = getContract({
            client: client,
            chain: chain,
            address: factoryAddress,
        });

        console.log("BlockchainService Initialized with Thirdweb SDK");
    }

    /**
     * Reads one purchase straight from the escrow contract. This is the source of truth for who the
     * buyer/seller are and what state the trade is in; the DB is only an index and is user-writable
     * through createTrade, so access decisions must not rely on it.
     * Throws if the purchase does not exist or the RPC call fails (callers must fail closed).
     */
    public async getPurchase(purchaseId: number): Promise<{
        listingId: number;
        buyer: string;
        seller: string;
        quantityWei: bigint;
        pricePerTokenWei: bigint;
        status: 'Proposed' | 'Locked' | 'Released' | 'Refunded' | 'Cancelled' | 'Disputed';
    }> {
        if (!this.contract) throw new Error("Contract not initialized");
        if (!Number.isSafeInteger(purchaseId) || purchaseId < 0) throw new Error("Invalid purchaseId");

        const r = await readContract({
            contract: this.contract,
            method: "function purchases(uint256) view returns (uint256 listingId, address buyer, uint256 quantity, uint256 agreedPricePerToken, uint8 status, address seller, uint256 createdAt)",
            params: [BigInt(purchaseId)]
        });
        const STATUSES = ['Proposed', 'Locked', 'Released', 'Refunded', 'Cancelled', 'Disputed'] as const;
        const status = STATUSES[Number(r[4])];
        if (!status) throw new Error("Unknown purchase status");
        return {
            listingId: Number(r[0]),
            buyer: String(r[1]),
            seller: String(r[5]),
            quantityWei: r[2],
            pricePerTokenWei: r[3],
            status
        };
    }

    public async releasePurchase(purchaseId: number): Promise<string> {
        if (!this.contract || !this.account) throw new Error("Contract or Account not initialized");

        console.log(`Releasing purchase ${purchaseId}...`);

        const transaction = prepareContractCall({
            contract: this.contract,
            method: "function releasePurchase(uint256 purchaseId)",
            params: [BigInt(purchaseId)]
        });

        // Send transaction from the Admin Account
        const { transactionHash } = await sendTransaction({
            transaction,
            account: this.account
        });

        console.log(`Transaction submitted. Hash: ${transactionHash}`);

        // Wait for confirmation. A reverted or unconfirmed release must NOT be reported as success.
        const receipt = await waitForReceipt({
            client: client,
            chain: p2pChain,
            transactionHash: transactionHash
        });
        if (receipt.status !== "success") {
            throw new Error(`Release transaction ${transactionHash} reverted`);
        }
        console.log(`Purchase ${purchaseId} release confirmed in block ${receipt.blockNumber}.`);

        return transactionHash;
    }

    public async startEventListener(): Promise<void> {
        if (!this.contract || this.isListening) return;

        console.log("Starting Blockchain Event Listener (Thirdweb)...");
        this.isListening = true;

        let result: any;
        try {
            // Watch all events - use indexer to avoid block range issues
            result = watchContractEvents({
                contract: this.contract,
                useIndexer: true, // Use thirdweb indexer instead of direct RPC to avoid block range errors
                onEvents: (events) => {
                    events.forEach(event => {
                        // Handle each event processing asynchronously
                        this.processEvent(event).catch((error) => {
                            console.error("Error processing event in forEach:", error);
                        });
                    });
                }
            });

            // Watch Copy Trading Factory Events
            const vaultCreatedEvent = prepareEvent({
                signature: "event VaultCreated(address indexed user, address indexed vault)"
            });

            watchContractEvents({
                contract: this.factoryContract,
                events: [vaultCreatedEvent],
                onEvents: async (events) => {
                    for (const event of events) {
                        const { user, vault } = event.args;
                        console.log(`[CopyTrading] VaultCreated: User ${user}, Vault ${vault}`);
                        await this.rewardFirstTrade(user, "CopyTrading Vault");
                    }
                }
            });
        } catch (error: any) {
            console.error("Failed to start blockchain event listener (synchronous error):", error);
            console.error("Error details:", JSON.stringify(error, null, 2));
            this.isListening = false;
            // Retry after a delay
            setTimeout(() => {
                if (!this.isListening) {
                    console.log("Retrying to start event listener after synchronous error...");
                    this.startEventListener().catch(err => {
                        console.error("Failed to retry event listener:", err);
                    });
                }
            }, 5000);
            return;
        }

        // Handle if watchContractEvents returns a promise
        if (result && typeof result.then === 'function') {
            result.catch((error: any) => {
                // Ignore "invalid block range params" error - it's about historical queries
                // The listener will still work for new events going forward
                if (error?.code === -32000 && error?.message?.includes('invalid block range params')) {
                    console.warn("Block range error (historical queries may fail, but new events will be monitored):", error.message);
                    // Don't reset isListening or retry - the listener is still active for new events
                    return;
                }

                console.error("Error in watchContractEvents promise:", error);
                console.error("Error code:", error?.code);
                console.error("Error message:", error?.message);
                console.error("Full error:", JSON.stringify(error, null, 2));
                this.isListening = false;
                // Retry after a delay for other errors
                setTimeout(() => {
                    if (!this.isListening) {
                        console.log("Retrying to start event listener after promise rejection...");
                        this.startEventListener().catch(err => {
                            console.error("Failed to retry event listener:", err);
                        });
                    }
                }, 10000); // Longer delay for RPC errors
            });
        }
        // If watchContractEvents returns an unsubscribe function, store it
        else if (result && typeof result === 'function') {
            // Store unsubscribe function if needed for cleanup
            (this as any).unsubscribe = result;
            console.log("Event listener started successfully");
        }
        // If watchContractEvents returns an object with unsubscribe method
        else if (result && typeof result === 'object' && result !== null) {
            (this as any).unsubscribe = result;
            console.log("Event listener started successfully");
        } else {
            console.log("Event listener setup completed (no return value)");
        }
    }

    private async processEvent(event: any) {
        try {
            const { eventName, args } = event;
            // console.log("Received Event:", eventName, args);

            if (eventName === "ListingCreated") {
                const { listingId, seller, token, totalAmount, pricePerToken } = args;
                const lId = Number(listingId);
                const amt = toTokens(totalAmount, 18);
                const price = toTokens(pricePerToken, 18);

                console.log(`Event: ListingCreated - ID: ${lId}, Seller: ${seller}, Price: ${price}`);

                await Listing.findOneAndUpdate(
                    { listingId: lId },
                    {
                        listingId: lId,
                        seller: seller,
                        token: token,
                        totalAmount: Number(amt),
                        remaining: Number(amt),
                        pricePerToken: Number(price),
                        active: true
                    },
                    { upsert: true, returnDocument: "after" }
                );
                console.log(`Listing ${lId} indexed/updated.`);

                // Referral Logic: Reward referrer if this is the seller's first "sell activity"
                try {
                    const sellerAddr = normalizeAddress(seller);
                    if (sellerAddr) {
                        const currentUser = await User.findOne({ walletAddress: { $regex: `^${sellerAddr}$`, $options: 'i' } });
                        if (currentUser && !currentUser.hasDoneFirstTrade) {
                            if (currentUser.referredBy) {
                                const refAddr = normalizeAddress(currentUser.referredBy);
                                if (refAddr) {
                                    await User.updateOne(
                                        { walletAddress: { $regex: `^${refAddr}$`, $options: 'i' } },
                                        { $inc: { referralPoints: 100 } }
                                    );
                                    console.log(`Referral Reward (P2P Listing): received 100 points for referring ${sellerAddr}`);
                                }
                            }
                            currentUser.hasDoneFirstTrade = true;
                            await currentUser.save();
                            console.log(`User ${sellerAddr} marked as having done first trade (via Listing)`);
                        }
                    }
                } catch (refError) {
                    console.error("Referral Logic Error (P2P Listing Event):", refError);
                }
            }
            else if (eventName === "PurchaseProposed") {
                const { purchaseId, listingId, buyer, quantity, pricePerToken } = args;
                const pId = Number(purchaseId);
                const lId = Number(listingId);
                const q = toTokens(quantity, 18);
                const p = toTokens(pricePerToken, 18);

                console.log(`Event: PurchaseProposed - PurchaseID: ${pId}, ListingID: ${lId}, Buyer: ${buyer}`);

                // Always fetch the latest listing data to ensure we have the correct seller
                const listing = await Listing.findOne({ listingId: lId });

                if (listing) {
                    await Trade.findOneAndUpdate(
                        { purchaseId: pId },
                        {
                            purchaseId: pId,
                            listingId: lId,
                            buyer: buyer,
                            seller: listing.seller,
                            quantity: Number(q),
                            pricePerToken: Number(p),
                            status: 'Proposed'
                        },
                        { upsert: true, returnDocument: "after" }
                    );
                    console.log(`Trade ${pId} created/updated in DB.`);
                } else {
                    console.warn(`Listing ${lId} not found for Purchase ${pId}`);
                }
            }
            else if (eventName === "PurchaseLocked") {
                const { purchaseId } = args;
                const pId = Number(purchaseId);
                console.log(`Event: PurchaseLocked - ID: ${pId}`);

                const trade = await Trade.findOne({ purchaseId: pId });
                if (trade) {
                    trade.status = 'Locked';
                    await trade.save();
                    console.log(`Trade ${pId} updated to Locked.`);
                }
            }
            else if (eventName === "PurchaseReleased") {
                const { purchaseId } = args;
                const pId = Number(purchaseId);
                console.log(`Event: PurchaseReleased - ID: ${pId}`);
                await Trade.findOneAndUpdate({ purchaseId: pId }, { status: 'Released' });
            }
            else if (eventName === "PurchaseCancelled") {
                const { purchaseId } = args;
                const pId = Number(purchaseId);
                await Trade.findOneAndUpdate({ purchaseId: pId }, { status: 'Cancelled' });
            }
            else if (eventName === "ListingUpdatedRemaining") {
                const { listingId, remaining } = args;
                const lId = Number(listingId);
                const rem = toTokens(remaining, 18);
                await Listing.findOneAndUpdate({ listingId: lId }, { remaining: Number(rem) });
                if (Number(rem) === 0) {
                    await Listing.findOneAndUpdate({ listingId: lId }, { active: false });
                }
            }
            else if (eventName === "ListingCancelled") {
                const { listingId } = args;
                const lId = Number(listingId);
                await Listing.findOneAndUpdate({ listingId: lId }, { active: false });
            }

        } catch (error) {
            console.error("Error processing event:", error);
        }
    }

    private async rewardFirstTrade(walletAddress: string, source: string) {
        try {
            const addr = normalizeAddress(walletAddress);
            if (!addr) return;
            const currentUser = await User.findOne({ walletAddress: { $regex: `^${addr}$`, $options: 'i' } });

            if (currentUser && !currentUser.hasDoneFirstTrade) {
                if (currentUser.referredBy) {
                    const refAddr = normalizeAddress(currentUser.referredBy);
                    if (refAddr) {
                        await User.updateOne(
                            { walletAddress: { $regex: `^${refAddr}$`, $options: 'i' } },
                            { $inc: { referralPoints: 100 } }
                        );
                        console.log(`Referral Reward (${source}): received 100 points for referring ${addr}`);
                    }
                }
                currentUser.hasDoneFirstTrade = true;
                await currentUser.save();
                console.log(`User ${addr} marked as having done first trade (via ${source})`);
            }
        } catch (error) {
            console.error(`Error in rewardFirstTrade (${source}):`, error);
        }
    }
}

export default new BlockchainService();
