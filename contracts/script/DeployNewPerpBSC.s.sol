// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {OracleModule} from "../src/new_perp/src/oracle/OracleModule.sol";
import {Router} from "../src/new_perp/src/router/Router.sol";
import {PositionManager} from "../src/new_perp/src/router/PositionManager.sol";
import {MarketFactory} from "../src/new_perp/src/core/MarketFactory.sol";
import {Market} from "../src/new_perp/src/core/Market.sol";
import {Vault} from "../src/new_perp/src/core/Vault.sol";
import {UpgradeableDeploy} from "./lib/UpgradeableDeploy.sol";
import {UpgradeAuthority} from "./lib/UpgradeAuthority.sol";

/**
 * @notice Deploy New Perp contracts on BSC.
 *
 * C5 FIX: perp markets are priced from a **Chainlink** aggregator, NOT the DEX-spot
 * `DexPriceAdapter` (a single-tx flash-loan-manipulable source). `OracleModule.getPrice`
 * already validates round-completeness + staleness, and we set a per-feed staleness window
 * (M2) matched to the Chainlink feed's heartbeat.
 *
 * Required env (per market):
 *   PRICE_FEED_ADDRESS   - Chainlink <BASE>/USD aggregator on BSC (overrides the symbol default)
 *   BASE_SYMBOL          - e.g. ETH / BTC / BNB (default ETH)
 *   USDC_ADDRESS         - quote token (default BSC USDC)
 *   PRICE_FEED_MAX_STALE - seconds; match the feed heartbeat (default 3600 = 1h, conservative)
 *   PRICE_FEED_MIN_E18 / PRICE_FEED_MAX_E18 - optional sanity bounds on the 1e18 price (0 = skip)
 *
 * UPGRADEABILITY: Market and Vault are deployed as BeaconProxies (one beacon each), so a single
 * beacon upgrade moves every market. Who may upgrade is REQUIRED config (see UpgradeAuthority):
 *   UPGRADE_ADMIN            - use this address (an existing Safe / timelock), OR
 *   UPGRADE_TIMELOCK_DELAY   - seconds; deploys a TimelockController (UPGRADE_PROPOSER, default
 *                              the deployer, may propose and execute)
 * The script refuses to run on a real network without one of these, so the deployer key can never
 * become the upgrade owner by omission. (ALLOW_DEPLOYER_UPGRADE_ADMIN=true overrides, test nets only.)
 */
contract DeployNewPerpBSC is UpgradeAuthority {
    function run() external {
        vm.startBroadcast();

        address deployer = msg.sender;

        // BSC Mainnet USDC: 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d
        address usdcAddress = vm.envOr("USDC_ADDRESS", address(0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d));

        string memory baseSymbol = vm.envOr("BASE_SYMBOL", string("ETH"));

        // C5: resolve the Chainlink <BASE>/USD feed (BSC mainnet defaults; override via env).
        address priceFeed = _resolvePriceFeed(baseSymbol);
        require(priceFeed != address(0), "PRICE_FEED_ADDRESS must be set");

        uint256 maxStale = vm.envOr("PRICE_FEED_MAX_STALE", uint256(3600));
        uint256 minE18 = vm.envOr("PRICE_FEED_MIN_E18", uint256(0));
        uint256 maxE18 = vm.envOr("PRICE_FEED_MAX_E18", uint256(0));

        // Fail fast, before a single contract is deployed, if upgrade authority is not configured.
        address upgradeAdmin = _resolveUpgradeAdmin(deployer);

        console.log("Deploying New Perp on BSC...");
        console.log("Deployer:", deployer);
        console.log("Quote Token (USDC):", usdcAddress);
        console.log("Base Symbol:", baseSymbol);
        console.log("Chainlink Price Feed:", priceFeed);
        console.log("Feed max-stale (s):", maxStale);

        // 1. Oracle Module
        OracleModule oracleModule = new OracleModule();
        console.log("OracleModule:", address(oracleModule));

        // 2. C5/M2: configure the feed's staleness window (and optional sanity bounds).
        oracleModule.setFeedMaxStale(priceFeed, maxStale);
        if (minE18 != 0 || maxE18 != 0) {
            oracleModule.setFeedBounds(priceFeed, minE18, maxE18);
            console.log("Feed bounds set [min,max] (1e18):", minE18, maxE18);
        }

        // Sanity: the feed must already return a valid, fresh price, or markets can't price.
        uint256 spot = oracleModule.getPrice(priceFeed);
        console.log("Current feed price (1e18):", spot);

        // 3. Router
        Router router = new Router(usdcAddress);
        console.log("Router:", address(router));

        // 4. Position Manager
        PositionManager positionManager = new PositionManager(address(router));
        console.log("PositionManager:", address(positionManager));

        // 5. Link Router and Position Manager
        router.setPositionManager(address(positionManager));
        console.log("Linked Router and Position Manager");

        // 5b. Register the keeper(s) allowed to execute requests and liquidations.
        // Execution is deliberately NOT permissionless: combined with
        // minExecutionDelayBlocks this is what stops a trader self-executing at a
        // price they can already see. Nothing executes until a keeper is set here.
        address keeper = vm.envOr("PERP_KEEPER_ADDRESS", address(0));
        require(keeper != address(0), "PERP_KEEPER_ADDRESS required");
        positionManager.setKeeper(keeper, true);
        console.log("Keeper registered:", keeper);

        address liquidationKeeper = vm.envOr("PERP_LIQUIDATION_KEEPER_ADDRESS", address(0));
        if (liquidationKeeper != address(0) && liquidationKeeper != keeper) {
            positionManager.setKeeper(liquidationKeeper, true);
            console.log("Liquidation keeper registered:", liquidationKeeper);
        }

        // 6. Market + Vault implementations, their beacons (owned by upgradeAdmin), and the factory
        UpgradeableDeploy.Perp memory perp = UpgradeableDeploy.deployPerp(upgradeAdmin);
        MarketFactory factory = perp.factory;
        console.log("Market implementation:", perp.marketImpl);
        console.log("Vault implementation:", perp.vaultImpl);
        console.log("Market beacon:", address(perp.marketBeacon));
        console.log("Vault beacon:", address(perp.vaultBeacon));
        console.log("MarketFactory:", address(factory));

        // 7. Create Market priced by the Chainlink feed (C5).
        (address market, address vault) = factory.createMarket(
            baseSymbol,
            usdcAddress,
            address(oracleModule),
            priceFeed,
            address(positionManager)
        );
        console.log("Market (%s): %s", baseSymbol, market);
        console.log("Vault:", vault);

        vm.stopBroadcast();

        console.log("\n--- BSC Deployment Complete ---");
        console.log("Save these addresses for your .env:");
        console.log("VITE_PERP_ROUTER_ADDRESS=", address(router));
        console.log("VITE_PERP_MARKET_ADDRESS=", market);
        console.log("VITE_PERP_VAULT_ADDRESS=", vault);
        console.log("VITE_PERP_POSITION_MANAGER_ADDRESS=", address(positionManager));
        console.log("VITE_USDC_ADDRESS=", usdcAddress);
        console.log("MARKET_FACTORY_ADDRESS=", address(factory));
        console.log("MARKET_BEACON_ADDRESS=", address(perp.marketBeacon));
        console.log("VAULT_BEACON_ADDRESS=", address(perp.vaultBeacon));
        console.log("UPGRADE_ADMIN (owns both beacons):", upgradeAdmin);
        console.log("Execution delay (blocks):", positionManager.minExecutionDelayBlocks());
        console.log("Keeper (must match backend PRIVATE_KEY wallet):", keeper);
    }

    /// @dev BSC mainnet Chainlink <BASE>/USD aggregators; PRICE_FEED_ADDRESS overrides.
    function _resolvePriceFeed(string memory baseSymbol) internal view returns (address) {
        bytes32 sym = keccak256(bytes(baseSymbol));
        address fallbackFeed;
        if (sym == keccak256(bytes("ETH"))) {
            fallbackFeed = 0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e; // ETH/USD
        } else if (sym == keccak256(bytes("BTC"))) {
            fallbackFeed = 0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf; // BTC/USD
        } else if (sym == keccak256(bytes("BNB"))) {
            fallbackFeed = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE; // BNB/USD
        } else {
            fallbackFeed = address(0); // unknown symbol -> must pass PRICE_FEED_ADDRESS
        }
        return vm.envOr("PRICE_FEED_ADDRESS", fallbackFeed);
    }
}
