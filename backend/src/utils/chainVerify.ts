import { JsonRpcProvider, Contract, formatUnits, zeroPadValue, id } from 'ethers';
import type { TransactionReceipt, TransactionResponse } from 'ethers';

/**
 * Helpers to check a client-supplied transaction hash against the chain before the backend trusts it.
 * A request body is attacker-controlled; the chain is not. Anything we record on a user's behalf
 * (swap history, perp trades, referral rewards) should be derived from a confirmed transaction that the
 * user actually sent, never from the body.
 */

const RPC_URL = process.env.RPC_URL || 'https://bsc-dataseed.binance.org/';
export const provider = new JsonRpcProvider(RPC_URL, Number(process.env.CHAIN_ID) || 56, { staticNetwork: true });

export class VerifyError extends Error {
    constructor(public status: number, message: string) {
        super(message);
    }
}

export const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
export const TX_HASH_RE = /^0x[0-9a-fA-F]{64}$/;

const TRANSFER_TOPIC = id('Transfer(address,address,uint256)');
const WITHDRAWAL_TOPIC = id('Withdrawal(address,uint256)'); // WETH9-style unwrap, emitted when the router pays out native coin

const pad = (addr: string) => zeroPadValue(addr.toLowerCase(), 32).toLowerCase();

export interface ConfirmedTx {
    tx: TransactionResponse;
    receipt: TransactionReceipt;
}

/** Loads a transaction and its receipt. Throws VerifyError: 400 bad hash, 409 not yet mined, 422 reverted, 502 RPC trouble. */
export async function loadConfirmedTx(txHash: unknown): Promise<ConfirmedTx> {
    if (typeof txHash !== 'string' || !TX_HASH_RE.test(txHash)) throw new VerifyError(400, 'A valid txHash is required');
    let tx: TransactionResponse | null;
    let receipt: TransactionReceipt | null;
    try {
        [tx, receipt] = await Promise.all([provider.getTransaction(txHash), provider.getTransactionReceipt(txHash)]);
    } catch (e) {
        console.error('chainVerify RPC error:', e instanceof Error ? e.message : e);
        throw new VerifyError(502, 'Could not verify this transaction on-chain. Please try again.');
    }
    if (!tx || !receipt) throw new VerifyError(409, 'Transaction not found or not confirmed yet');
    if (receipt.status !== 1) throw new VerifyError(422, 'Transaction reverted on-chain');
    return { tx, receipt };
}

const same = (a?: string | null, b?: string | null) => !!a && !!b && a.toLowerCase() === b.toLowerCase();

/** The transaction must have been sent by `wallet` to one of `allowedTo`. */
export function assertSentByTo(c: ConfirmedTx, wallet: string, allowedTo: (string | undefined)[]): void {
    if (!same(c.tx.from, wallet)) throw new VerifyError(403, 'This transaction was not sent by your wallet');
    const allowed = allowedTo.filter((a): a is string => !!a);
    if (allowed.length === 0) throw new VerifyError(503, 'Server is not configured to verify this transaction type');
    if (!c.tx.to || !allowed.some((a) => same(a, c.tx.to))) {
        throw new VerifyError(422, 'Transaction was not sent to the expected contract');
    }
}

/** Sum of ERC-20 Transfer logs on `token` where the from/to side matches `wallet`. */
export function sumTransfers(receipt: TransactionReceipt, token: string, side: 'from' | 'to', wallet: string): bigint {
    const topicIdx = side === 'from' ? 1 : 2;
    let total = 0n;
    for (const log of receipt.logs) {
        if (!same(log.address, token) || log.topics[0] !== TRANSFER_TOPIC || log.topics.length < 3) continue;
        if (log.topics[topicIdx]?.toLowerCase() !== pad(wallet)) continue;
        total += BigInt(log.data);
    }
    return total;
}

/** Sum of WETH-style Withdrawal amounts made by `src` (the router unwrapping to pay native coin). */
export function sumWithdrawals(receipt: TransactionReceipt, src: string): bigint {
    let total = 0n;
    for (const log of receipt.logs) {
        if (log.topics[0] !== WITHDRAWAL_TOPIC || log.topics[1]?.toLowerCase() !== pad(src)) continue;
        total += BigInt(log.data);
    }
    return total;
}

/** True if the wallet is the sender or appears as an indexed address in any log emitted by one of `contracts`. */
export function involvesWallet(c: ConfirmedTx, wallet: string, contracts: (string | undefined)[]): boolean {
    if (same(c.tx.from, wallet)) return true;
    const set = contracts.filter((a): a is string => !!a).map((a) => a.toLowerCase());
    const w = pad(wallet);
    return c.receipt.logs.some((l) => set.includes(l.address.toLowerCase()) && l.topics.slice(1).some((t) => t.toLowerCase() === w));
}

const decimalsCache = new Map<string, number>();
export async function tokenDecimals(token: string): Promise<number> {
    const key = token.toLowerCase();
    const hit = decimalsCache.get(key);
    if (hit !== undefined) return hit;
    try {
        const d = Number(await new Contract(token, ['function decimals() view returns (uint8)'], provider).decimals!());
        decimalsCache.set(key, d);
        return d;
    } catch {
        throw new VerifyError(502, 'Could not read token details on-chain. Please try again.');
    }
}

export const toHuman = (raw: bigint, decimals: number) => formatUnits(raw, decimals);
