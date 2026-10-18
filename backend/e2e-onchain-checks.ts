/**
 * On-chain verification checks for the trade/swap/perp endpoints (P2P release, swap recording, perp trade recording,
 * chain reconciler). Runs real transactions on a LOCAL Anvil node and calls the controllers directly with forged
 * requests, so it needs no running API and touches no real network. Uses Anvil's public well-known test keys only.
 *
 * Run (from dex-smart-contract-new/):
 *   anvil --port 8598 &
 *   (cd contracts && PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
 *      forge script script/DeployAll.s.sol --tc DeployAll --rpc-url http://127.0.0.1:8598 --broadcast)
 *   then export E2E_ADDRS='{"USDC":..,"ETH":..,"BTC":..,"ROUTER":..,"P2P":..,"PROUTER":..}' from the deploy output and run, in backend/:
 *   RPC_URL=http://127.0.0.1:8598 P2P_RPC_URL=http://127.0.0.1:8598 CHAIN_ID=31337 CONTRACT_ADDRESS=<P2P> \
 *   PRIVATE_KEY=<anvil key 0> DEX_ROUTER_ADDRESS=<router> PERP_ROUTER_ADDRESS=<perp router> PERP_POSITION_MANAGER_ADDRESS=<pm> \
 *   PERP_MARKET_ADDRESS=<eth market> MONGO_URI=mongodb://localhost:27017/e2e-onchain THIRDWEB_CLIENT_ID=x npx tsx e2e-onchain-checks.ts
 * It drops the e2e-onchain database when done. Never point MONGO_URI at a real database.
 */
import { Wallet, JsonRpcProvider, Contract, MaxUint256, id } from 'ethers';
import mongoose from 'mongoose';
import Trade from './src/models/Trade.js';
import SwapTrade from './src/models/SwapTrade.js';
import PerpTrade from './src/models/PerpTrade.js';
import { createTrade, releaseFunds } from './src/controllers/TradeController.js';
import { storeSwap, getSwapsByUser } from './src/controllers/swapController.js';
import { createTrade as perpCreate, getTradesByAddress } from './src/controllers/PerpTradeController.js';
import BlockchainService from './src/services/BlockchainService.js';

const A = JSON.parse(process.env.E2E_ADDRS!);
const provider = new JsonRpcProvider(process.env.RPC_URL!, undefined, { cacheTimeout: -1 });
const KEYS = [
  '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80', '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d',
  '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a', '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6',
];
const [owner, seller, buyer, imposter] = KEYS.map((k) => new Wallet(k, provider));
const ERC20 = ['function mint(address,uint256)', 'function approve(address,uint256)', 'function balanceOf(address) view returns (uint256)'];
const P2P = ['function createListing(address,uint256,uint256) returns (uint256)', 'function proposePurchase(uint256,uint256,uint256)', 'function lockPurchase(uint256)', 'function purchases(uint256) view returns (uint256,address,uint256,uint256,uint8,address,uint256)'];
const ROUTER = ['function swapExactTokensForTokens(uint256,uint256,address[],address,uint256) returns (uint256[])'];
const mockRes = () => { const r: any = { code: 200, body: undefined }; r.status = (c: number) => { r.code = c; return r; }; r.json = (b: any) => { r.body = b; return r; }; return r; };
const req = (wallet: string, body: any = {}, params: any = {}) => ({ user: { walletAddress: wallet }, body, params }) as any;
let pass = 0, fail = 0;
const check = (name: string, ok: boolean, extra?: any) => { ok ? pass++ : fail++; console.log(ok ? 'PASS' : 'FAIL', name, ok ? '' : JSON.stringify(extra)); };
const call = async (fn: any, r: any) => { const res = mockRes(); await fn(r, res); return res; };
const wait = async (tx: any) => { const t = await tx; await t.wait(); return t; };
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

(async () => {
  await mongoose.connect(process.env.MONGO_URI!); await mongoose.connection.dropDatabase();
  const usdc = (s: Wallet) => new Contract(A.USDC, ERC20, s) as any, p2p = (s: Wallet) => new Contract(A.P2P, P2P, s) as any;

  // ---------- real P2P flow on-chain ----------
  await wait(usdc(seller).mint(seller.address, 1_000_000_000n)); await wait(usdc(seller).approve(A.P2P, MaxUint256));
  await wait(p2p(seller).createListing(A.USDC, 500_000_000n, 10n ** 18n));
  await wait(p2p(buyer).proposePurchase(0, 10_000_000n, 10n ** 18n));      // purchase 0
  await wait(p2p(buyer).proposePurchase(0, 20_000_000n, 10n ** 18n));      // purchase 1

  let r = await call(createTrade, req(imposter.address, { purchaseId: 0 }));
  check('createTrade: outsider rejected (403)', r.code === 403, r);
  r = await call(createTrade, req(buyer.address, { purchaseId: 0, buyer: imposter.address, seller: imposter.address, quantity: 999999, pricePerToken: 1 }));
  const t0 = await Trade.findOne({ purchaseId: 0 }).lean() as any;
  check('createTrade: buyer ok (201), parties+amounts from CHAIN not body', r.code === 201 && t0?.buyer.toLowerCase() === buyer.address.toLowerCase() && t0?.seller.toLowerCase() === seller.address.toLowerCase() && t0.quantity === 10, { code: r.code, t0 });
  r = await call(createTrade, req(buyer.address, { purchaseId: 0 }));
  check('createTrade: duplicate rejected (400)', r.code === 400, r);
  r = await call(createTrade, req(buyer.address, { purchaseId: 99 }));
  check('createTrade: nonexistent purchase fails closed (502)', r.code === 502, r);
  r = await call(createTrade, req(buyer.address, { purchaseId: '1; drop' }));
  check('createTrade: malformed id rejected (400)', r.code === 400, r);

  await wait(p2p(seller).lockPurchase(0));
  r = await call(releaseFunds, req(buyer.address, { purchaseId: 0 }));
  check('releaseFunds: buyer rejected (403)', r.code === 403, r);
  r = await call(releaseFunds, req(imposter.address, { purchaseId: 0 }));
  check('releaseFunds: outsider rejected (403)', r.code === 403, r);
  // attacker plants a fake DB row naming themselves seller: must not help
  await Trade.create({ purchaseId: 1, listingId: 0, buyer: buyer.address, seller: imposter.address, quantity: 1, pricePerToken: 1, status: 'Locked' });
  r = await call(releaseFunds, req(imposter.address, { purchaseId: 1 }));
  check('releaseFunds: forged DB row does not authorise (403)', r.code === 403, r);
  r = await call(releaseFunds, req(seller.address, { purchaseId: 1 }));
  check('releaseFunds: purchase still only Proposed on-chain -> 409', r.code === 409, r);
  r = await call(releaseFunds, req(seller.address, { purchaseId: 0 }));
  const chain0 = await p2p(owner).purchases(0);
  check('releaseFunds: real seller ok (200) and chain status Released', r.code === 200 && Number(chain0[4]) === 2, { code: r.code, body: r.body, st: Number(chain0[4]) });
  r = await call(releaseFunds, req(seller.address, { purchaseId: 0 }));
  check('releaseFunds: already released -> 409', r.code === 409, r);

  // ---------- reconciler rebuilds the index from chain ----------
  await Trade.deleteMany({});
  process.env.P2P_START_BLOCK = '1';
  await BlockchainService.startPurchaseReconciler();
  const rows = await Trade.find({}).sort({ purchaseId: 1 }).lean() as any[];
  check('reconciler: backfilled both purchases from chain with real status', rows.length === 2 && rows[0].status === 'Released' && rows[1].status === 'Proposed' && rows[1].seller.toLowerCase() === seller.address.toLowerCase(), rows);

  // ---------- real swap ----------
  const eth = new Contract(A.ETH, ERC20, owner) as any;
  await wait(eth.mint(buyer.address, 5n * 10n ** 18n)); await wait((eth.connect(buyer) as any).approve(A.ROUTER, MaxUint256));
  const swapTx = await wait((new Contract(A.ROUTER, ROUTER, buyer) as any).swapExactTokensForTokens(10n ** 18n, 0, [A.ETH, A.USDC], buyer.address, Math.floor(Date.now() / 1000) + 600));
  const body = { userAddress: imposter.address, tokenIn: A.ETH, tokenOut: A.USDC, amountIn: '999', amountOut: '999', txHash: swapTx.hash };
  r = await call(storeSwap, req(buyer.address, body));
  check('storeSwap: body userAddress mismatch rejected (403)', r.code === 403, r);
  r = await call(storeSwap, req(imposter.address, { ...body, userAddress: undefined }));
  check("storeSwap: someone else's tx rejected (403)", r.code === 403, r);
  r = await call(storeSwap, req(buyer.address, { ...body, userAddress: buyer.address }));
  const s = r.body?.swap;
  check('storeSwap: ok (201), amounts from RECEIPT not body (1.0 ETH in, >0 out)', r.code === 201 && s?.amountIn === '1.0' && Number(s?.amountOut) > 2900 && s?.amountOut !== '999', r);
  r = await call(storeSwap, req(buyer.address, { ...body, userAddress: buyer.address }));
  check('storeSwap: replay is idempotent (200, no duplicate)', r.code === 200 && (await SwapTrade.countDocuments()) === 1, r);
  r = await call(storeSwap, req(buyer.address, { ...body, userAddress: buyer.address, tokenOut: A.BTC, txHash: swapTx.hash.replace(/.$/, swapTx.hash.endsWith('0') ? '1' : '0') }));
  check('storeSwap: unknown/unconfirmed tx rejected (409)', r.code === 409, r);
  r = await call(getSwapsByUser, req(buyer.address, {}, { userAddress: buyer.address }));
  check('getSwapsByUser: owner sees own (1)', r.code === 200 && r.body.length === 1, r);
  r = await call(getSwapsByUser, req(imposter.address, {}, { userAddress: buyer.address }));
  check("getSwapsByUser: other user's history refused (403)", r.code === 403, r);

  // ---------- perp trade recording ----------
  const perpBody = { positionId: '1', type: 'OPEN_LONG', tokenSymbol: 'ETH', size: '100', collateral: '10', price: '3000' };
  const okPerpTx = await wait(buyer.sendTransaction({ to: A.PROUTER, data: id('owner()').slice(0, 10) }));
  const imposterPerpTx = await wait(imposter.sendTransaction({ to: A.PROUTER, data: id('owner()').slice(0, 10) }));
  r = await call(perpCreate, req(buyer.address, { ...perpBody, txHash: okPerpTx.hash, walletAddress: imposter.address }));
  check('perp: body walletAddress mismatch rejected (403)', r.code === 403, r);
  r = await call(perpCreate, req(buyer.address, { ...perpBody, txHash: okPerpTx.hash, size: '1e999' }));
  check('perp: malformed number rejected (400)', r.code === 400, r);
  r = await call(perpCreate, req(buyer.address, { ...perpBody, txHash: swapTx.hash }));
  check('perp: tx to a non-perp contract rejected (422)', r.code === 422, r);
  r = await call(perpCreate, req(buyer.address, { ...perpBody, txHash: imposterPerpTx.hash }));
  check("perp: someone else's tx rejected (403)", r.code === 403, r);
  r = await call(perpCreate, req(buyer.address, { ...perpBody, txHash: okPerpTx.hash }));
  const pt = await PerpTrade.findOne({ positionId: '1' }).lean() as any;
  check('perp: valid trade recorded (201) under session wallet', r.code === 201 && pt?.walletAddress === buyer.address.toLowerCase(), r);
  r = await call(perpCreate, req(imposter.address, { ...perpBody, txHash: imposterPerpTx.hash, price: '1' }));
  const pt2 = await PerpTrade.findOne({ positionId: '1' }).lean() as any;
  check("perp: cannot overwrite another wallet's position (403), record untouched", r.code === 403 && pt2.entryPrice === '3000', { code: r.code, pt2 });
  r = await call(getTradesByAddress, req(buyer.address, {}, { walletAddress: buyer.address }));
  check('perp history: owner sees own', r.code === 200 && r.body.length === 1, r);
  r = await call(getTradesByAddress, req(imposter.address, {}, { walletAddress: buyer.address }));
  check("perp history: other user's refused (403)", r.code === 403, r);

  await mongoose.connection.dropDatabase();
  console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('HARNESS ERROR', e); process.exit(2); });
