// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {console} from "forge-std/Script.sol";
import {AmxSale} from "../src/AmxSale.sol";
import {AmxUpgradeableDeploy} from "./lib/AmxUpgradeableDeploy.sol";
import {UpgradeAuthority} from "./lib/UpgradeAuthority.sol";

/// @notice Deploys AmxSale on BSC behind a TransparentUpgradeableProxy. Defaults for
/// USDC/USDT/the BNB-USD Chainlink feed are the real BSC mainnet addresses already used elsewhere
/// in this workspace (Amerox-dex's .env.production, DeployNewPerpBSC.s.sol) — override via env for
/// testnet.
///
/// The PROXY address is the sale's permanent address (frontend VITE_AMX_SALE_ADDRESS, relayer
/// AMX_SALE_ADDRESS); depositIds are bound to it. The relayer's START_BLOCK must be the block this
/// deployment lands in.
///
/// Required env vars:
///   PRIVATE_KEY                - deployer key, pays gas
///   ADMIN_ADDRESS               - holds DEFAULT_ADMIN_ROLE
///   PAUSER_ADDRESS               - holds PAUSER_ROLE
///   BNB_TREASURY_ADDRESS          - sweepBNB() destination
///   USDC_TREASURY_ADDRESS          - sweepToken(usdc) destination
///   USDT_TREASURY_ADDRESS           - sweepToken(usdt) destination
/// Upgrade authority (required on a real network; AMX contracts have their own, see UpgradeAuthority):
///   AMX_UPGRADE_ADMIN=<address>, OR
///   AMX_UPGRADE_TIMELOCK_DELAY=<secs> + AMX_UPGRADE_PROPOSER=<address>
/// Optional env vars:
///   USDC_ADDRESS (default: BSC mainnet Binance-Peg USDC)
///   USDT_ADDRESS (default: BSC mainnet Binance-Peg USDT)
///   BNB_USD_PRICE_FEED (default: BSC mainnet Chainlink BNB/USD)
///   AMX_PRICE_USD_E18 (default: 0.5e18 = $0.50/AMX)
///   MIN_PURCHASE_USD_E18 (default: 1e18 = $1)
///   MAX_PURCHASE_USD_E18 (default: 10000e18 = $10,000)
contract DeployAmxSale is UpgradeAuthority {
    address constant BSC_MAINNET_USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant BSC_MAINNET_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant BSC_MAINNET_BNB_USD_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        AmxUpgradeableDeploy.SaleConfig memory c = AmxUpgradeableDeploy.SaleConfig({
            admin: vm.envAddress("ADMIN_ADDRESS"),
            pauser: vm.envAddress("PAUSER_ADDRESS"),
            usdc: vm.envOr("USDC_ADDRESS", BSC_MAINNET_USDC),
            usdt: vm.envOr("USDT_ADDRESS", BSC_MAINNET_USDT),
            bnbPriceFeed: vm.envOr("BNB_USD_PRICE_FEED", BSC_MAINNET_BNB_USD_FEED),
            bnbTreasury: vm.envAddress("BNB_TREASURY_ADDRESS"),
            usdcTreasury: vm.envAddress("USDC_TREASURY_ADDRESS"),
            usdtTreasury: vm.envAddress("USDT_TREASURY_ADDRESS"),
            amxPriceUsdE18: vm.envOr("AMX_PRICE_USD_E18", uint256(0.5e18)),
            minPurchaseUsdE18: vm.envOr("MIN_PURCHASE_USD_E18", uint256(1e18)),
            maxPurchaseUsdE18: vm.envOr("MAX_PURCHASE_USD_E18", uint256(10_000e18))
        });

        vm.startBroadcast(deployerPrivateKey);

        // Fail fast, before the sale is deployed, if upgrade authority is not configured.
        address upgradeAdmin = _resolveUpgradeAdmin("AMX_", vm.addr(deployerPrivateKey));

        (AmxSale sale, address impl) = AmxUpgradeableDeploy.deploySale(c, upgradeAdmin);
        console.log("AmxSale PROXY (use this address):", address(sale));
        console.log("Implementation:", impl);
        console.log("Upgrade admin (owns the ProxyAdmin):", upgradeAdmin);
        console.log("Price (USD 1e18) / feed:", sale.amxPriceUsdE18(), sale.bnbPriceFeed());

        vm.stopBroadcast();
    }
}
