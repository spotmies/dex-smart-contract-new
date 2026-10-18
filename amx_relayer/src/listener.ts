import { ethers } from "ethers";
import { config } from "./config.js";
import { getLastScannedBlock, setLastScannedBlock, recordDepositSeen } from "./db.js";
import amxSaleAbi from "./abis/AmxSale.json" with { type: "json" };

const bscProvider = new ethers.JsonRpcProvider(config.bscRpcUrl);
const amxSale = new ethers.Contract(config.amxSaleAddress, amxSaleAbi, bscProvider);

// Matches ethers' generic UNKNOWN_ERROR wrapping of a JSON-RPC -32602 from eth_getLogs when
// the toBlock we asked for is past what this specific backend node has. bsc-rpc.publicnode.com
// is load-balanced across multiple backend nodes, so the node that ends up serving eth_getLogs
// is occasionally a block behind the one that answered our earlier eth_blockNumber call — the
// range was valid when computed, just not against whichever node picked up this request.
const HEAD_LAG_ERROR = /block range extends beyond current head block: requested \d+, head (\d+)/;

/** Scans [fromBlock, toBlock] for Purchased events and returns the last block actually covered.
 * On a head-lag error, retries once clamped to what that node actually reports as its head,
 * rather than failing the whole tick — which previously also skipped runExecutorTick() (and
 * with it reconcileStaleReleases()) for that cycle, see the 2026-09-07 incident notes. */
async function scanRange(fromBlock: number, toBlock: number): Promise<number> {
    const filter = amxSale.filters.Purchased();
    let events;
    let actualToBlock = toBlock;

    try {
        events = await amxSale.queryFilter(filter, fromBlock, toBlock);
    } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        const match = message.match(HEAD_LAG_ERROR);
        if (!match) throw err;

        const actualHead = Number(match[1]);
        if (actualHead < fromBlock) {
            // This node is lagging behind our own scan position entirely — nothing valid to
            // request yet. Report no progress; catchUp() stops here and the next tick tries
            // again, likely hitting a different, caught-up backend node.
            return fromBlock - 1;
        }

        console.warn(
            `[listener] RPC head lag: requested up to ${toBlock}, this node only has ${actualHead} — retrying clamped`
        );
        events = await amxSale.queryFilter(filter, fromBlock, actualHead);
        actualToBlock = actualHead;
    }

    for (const event of events) {
        if (!("args" in event) || !event.args) continue; // skip malformed/unparsed logs
        // depositId is computed on-chain by AmxSale itself and emitted directly — the relayer
        // just reads it, it never re-derives it. See AmxSale.sol's computeDepositId().
        const { buyer, asset, amountIn, amxOut, depositId } = event.args;

        recordDepositSeen({
            depositId,
            txHash: event.transactionHash,
            logIndex: event.index,
            blockNumber: event.blockNumber,
            buyer,
            asset,
            amountIn: amountIn.toString(),
            amxOut: amxOut.toString(),
        });

        console.log(
            `[listener] Purchased seen: tx=${event.transactionHash} logIndex=${event.index} buyer=${buyer} amxOut=${amxOut.toString()}`
        );
    }

    return actualToBlock;
}

/** Scans from the last-recorded block up to the current chain tip, in safe-sized chunks
 * (bsc-rpc.publicnode.com is documented reliable up to ~5k blocks per getLogs call — default
 * chunk size stays well under that). Persists progress after every chunk, so a crash mid-scan
 * resumes from where it left off rather than re-scanning from scratch or, worse, silently
 * skipping ahead. */
export async function catchUp(): Promise<void> {
    const currentTip = await bscProvider.getBlockNumber();
    let fromBlock = getLastScannedBlock();

    if (fromBlock === null) {
        // Unreachable in practice — index.ts refuses to start without START_BLOCK when there's
        // no scan state. Kept as a guard so this can never silently degrade to tip-scanning if
        // catchUp() is ever called from somewhere that skipped the preflight.
        if (config.startBlock === undefined) {
            throw new Error(
                "No scan state and no START_BLOCK — refusing to scan from the tip, which would skip prior purchases."
            );
        }
        fromBlock = config.startBlock;
        console.log(`[listener] no prior scan state found; starting from START_BLOCK = ${fromBlock}`);
    } else {
        fromBlock += 1; // resume from the block after the last one we finished
    }

    while (fromBlock <= currentTip) {
        const toBlock = Math.min(fromBlock + config.backfillChunkSize - 1, currentTip);
        const actualToBlock = await scanRange(fromBlock, toBlock);
        if (actualToBlock < fromBlock) {
            // No progress this attempt (head-lagging node) — stop for this tick rather than
            // retrying the same range in a tight loop; the next tick tries again.
            break;
        }
        setLastScannedBlock(actualToBlock);
        fromBlock = actualToBlock + 1;
    }
}

export function getBscProvider(): ethers.JsonRpcProvider {
    return bscProvider;
}
