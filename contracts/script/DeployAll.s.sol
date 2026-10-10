// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// AMM Imports
import {Factory as AmmFactory, Router as AmmRouter} from "../src/Dex.sol";
import {MockWETH} from "../src/MockWETH.sol";

// P2P Imports
import {P2PTokenEscrows} from "../src/P2PTokenEscrow.sol";
import {UpgradeableDeploy} from "./lib/UpgradeableDeploy.sol";
import {UpgradeAuthority} from "./lib/UpgradeAuthority.sol";

// Limit Order Imports
import {LimitOrderProtocol} from "../src/limit_order/LimitOrderProtocol.sol";

// Perpetual Imports
import {MockUSDC} from "../src/new_perp/src/mocks/MockUSDC.sol";
import {MockOracle} from "../src/new_perp/src/mocks/MockOracle.sol";
import {OracleModule} from "../src/new_perp/src/oracle/OracleModule.sol";
import {DexPriceAdapter} from "../src/new_perp/src/oracle/DexPriceAdapter.sol";
import {Router as PerpRouter} from "../src/new_perp/src/router/Router.sol";
import {PositionManager} from "../src/new_perp/src/router/PositionManager.sol";
import {MarketFactory as PerpMarketFactory} from "../src/new_perp/src/core/MarketFactory.sol";
import {Market} from "../src/new_perp/src/core/Market.sol";
import {Vault as PerpVault} from "../src/new_perp/src/core/Vault.sol";

// Copy Trading Imports
import {CopyTradingFactory} from "../src/copy_trading/CopyTradingFactory.sol";
import {CopyTradingVault} from "../src/copy_trading/CopyTradingVault.sol";

// Mock Token for BTC/ETH
contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 10_000_000 * 10**18); // 10M tokens
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeployAll is UpgradeAuthority {
    function run() external {
        // ------------------------------------------------------------------
        // 0. Setup & Config
        // ------------------------------------------------------------------
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("\n=================================================================");
        console.log("Starting Full Deployment with Deployer:", deployer);
        console.log("=================================================================\n");

        vm.startBroadcast(deployerPrivateKey);

        // ------------------------------------------------------------------
        // 1. Deploy Tokens (USDC, BTC, ETH)
        // ------------------------------------------------------------------
        console.log("--- 1. Deploying Tokens ---");
        
        // MockUSDC (6 decimals)
        MockUSDC usdc = new MockUSDC();
        usdc.mint(deployer, 10_000_000 * 1e6); // 10M USDC
        console.log("MockUSDC deployed at:", address(usdc));

        // MockBTC (18 decimals)
        MockToken btc = new MockToken("Bitcoin", "BTC");
        console.log("MockBTC deployed at:", address(btc));

        // MockETH (18 decimals)
        MockToken eth = new MockToken("Ethereum", "ETH");
        console.log("MockETH deployed at:", address(eth));


        // ------------------------------------------------------------------
        // 2. Deploy & Setup DEX (AMM)
        // ------------------------------------------------------------------
        console.log("\n--- 2. Deploying AMM DEX ---");
        
        AmmFactory ammFactory = new AmmFactory();
        console.log("AMM Factory deployed at:", address(ammFactory));

        // Local/full-stack deploy — a throwaway wrapper stands in for WBNB.
        AmmRouter ammRouter = new AmmRouter(
            address(ammFactory),
            address(new MockWETH())
        );
        console.log("AMM Router deployed at:", address(ammRouter));

        // Approve tokens for Router
        btc.approve(address(ammRouter), type(uint256).max);
        eth.approve(address(ammRouter), type(uint256).max);
        usdc.approve(address(ammRouter), type(uint256).max);

        // Create Pairs & Add Liquidity
        // BTC/USDC
        ammRouter.addLiquidity(
            address(btc),
            address(usdc),
            100 * 1e18,     // 100 BTC
            6_000_000 * 1e6,// 6M USDC (Approx $60k BTC)
            0, 0, deployer, block.timestamp + 1000
        );
        address btcUsdcPair = ammFactory.getPair(address(btc), address(usdc));
        console.log("BTC/USDC Pair created at:", btcUsdcPair);

        // ETH/USDC
        ammRouter.addLiquidity(
            address(eth),
            address(usdc),
            1_000 * 1e18,   // 1000 ETH
            3_000_000 * 1e6,// 3M USDC (Approx $3k ETH)
            0, 0, deployer, block.timestamp + 1000
        );
        address ethUsdcPair = ammFactory.getPair(address(eth), address(usdc));
        console.log("ETH/USDC Pair created at:", ethUsdcPair);


        // ------------------------------------------------------------------
        // 3. Deploy P2P System
        // ------------------------------------------------------------------
        console.log("\n--- 3. Deploying P2P System ---");
        
        // Behind a TransparentUpgradeableProxy; `deployer` administers the whitelist.
        // Resolved once and reused for the perp beacons below.
        address upgradeAdmin = _resolveUpgradeAdmin(deployer);
        (P2PTokenEscrows p2p, address p2pImpl) = UpgradeableDeploy.deployP2P(deployer, upgradeAdmin);
        console.log("P2PTokenEscrows proxy:", address(p2p));
        console.log("P2PTokenEscrows implementation:", p2pImpl);

        // Whitelist tokens
        p2p.setTokenWhitelist(address(usdc), true);
        p2p.setTokenWhitelist(address(btc), true);
        p2p.setTokenWhitelist(address(eth), true);
        console.log("Whitelisted USDC, BTC, ETH on P2P");


        // ------------------------------------------------------------------
        // 4. Deploy Limit Order Protocol
        // ------------------------------------------------------------------
        console.log("\n--- 4. Deploying Limit Order Protocol ---");
        
        LimitOrderProtocol limitOrder = new LimitOrderProtocol();
        console.log("LimitOrderProtocol deployed at:", address(limitOrder));


        // ------------------------------------------------------------------
        // 5. Deploy Perpetuals System
        // ------------------------------------------------------------------
        console.log("\n--- 5. Deploying Perpetuals System ---");

        // Oracle Module
        OracleModule oracleModule = new OracleModule();
        console.log("Perp OracleModule deployed at:", address(oracleModule));

        // DexPriceAdapter (Real DEX price)
        address[] memory path = new address[](2);
        path[0] = address(eth);
        path[1] = address(usdc);
        DexPriceAdapter dexAdapter = new DexPriceAdapter(address(ammRouter), path, 8);
        address oracleAddress = address(dexAdapter);
        console.log("DexPriceAdapter (ETH/USDC) deployed at:", oracleAddress);

        // Perp Router (Quote = USDC)
        PerpRouter perpRouter = new PerpRouter(address(usdc));
        console.log("Perp Router deployed at:", address(perpRouter));

        // Position Manager
        PositionManager positionManager = new PositionManager(address(perpRouter));
        console.log("PositionManager deployed at:", address(positionManager));

        // Connect Router -> PM
        perpRouter.setPositionManager(address(positionManager));

        // Market Factory
        UpgradeableDeploy.Perp memory perp = UpgradeableDeploy.deployPerp(upgradeAdmin);
        PerpMarketFactory perpMarketFactory = perp.factory;
        console.log("Perp Market beacon:", address(perp.marketBeacon));
        console.log("Perp Vault beacon:", address(perp.vaultBeacon));
        console.log("Perp MarketFactory deployed at:", address(perpMarketFactory));

        // Create ETH-PERP Market
        // params: symbol, quoteToken, oracleModule, oracleAddress, positionManager
        (address marketAddress, address vaultAddress) = perpMarketFactory.createMarket(
            "ETH",
            address(usdc),
            address(oracleModule),
            oracleAddress,
            address(positionManager)
        );
        console.log("ETH-PERP Market created at:", marketAddress);
        console.log("ETH-PERP Vault created at:", vaultAddress);

        // Set PM in Market
        Market(marketAddress).setPositionManager(address(positionManager));
        console.log("PositionManager set in ETH Market");

        // --- Create BTC-PERP Market ---
        console.log("\n--- Creating BTC-PERP Market ---");
        // DexPriceAdapter for BTC
        address[] memory pathBtc = new address[](2);
        pathBtc[0] = address(btc);
        pathBtc[1] = address(usdc);
        DexPriceAdapter dexAdapterBtc = new DexPriceAdapter(address(ammRouter), pathBtc, 8);
        address oracleAddressBtc = address(dexAdapterBtc);
        console.log("DexPriceAdapter (BTC/USDC) deployed at:", oracleAddressBtc);

        (address marketAddressBtc, address vaultAddressBtc) = perpMarketFactory.createMarket(
            "BTC",
            address(usdc),
            address(oracleModule),
            oracleAddressBtc,
            address(positionManager)
        );
        console.log("BTC-PERP Market created at:", marketAddressBtc);
        
        // Set PM in BTC Market
        Market(marketAddressBtc).setPositionManager(address(positionManager));
        console.log("PositionManager set in BTC Market");

        // Seed Vault Liquidity
        // Approve USDC for Vault (Deployer has 10M, deposit 1M)
        uint256 vaultDeposit = 1_000_000 * 1e6; 
        usdc.approve(vaultAddress, vaultDeposit);
        PerpVault(vaultAddress).deposit(vaultDeposit, deployer);
        console.log("Seeded Perp Vault with 1M USDC");


        // ------------------------------------------------------------------
        // 6. Deploy Copy Trading System
        // ------------------------------------------------------------------
        console.log("\n--- 6. Deploying Copy Trading System ---");

        CopyTradingVault copyVaultImpl = new CopyTradingVault();
        console.log("CopyTrading Vault Impl deployed at:", address(copyVaultImpl));

        CopyTradingFactory copyFactory = new CopyTradingFactory(
            address(copyVaultImpl),
            deployer, // Executor (Deployer for now, usually a bot)
            address(ammRouter), // AMM Router for swaps
            deployer  // Owner
        );
        console.log("CopyTrading Factory deployed at:", address(copyFactory));


        vm.stopBroadcast();

        // ------------------------------------------------------------------
        // 7. Output Env Variables
        // ------------------------------------------------------------------
        console.log("\n\n=================================================================");
        console.log("                   DEPLOYMENT COMPLETE                           ");
        console.log("=================================================================");
        console.log("");
        console.log("### CONTRACT ADDRESSES (Copy to .env) ###");
        console.log("");
        console.log("VITE_MOCK_USDC_ADDRESS=%s", address(usdc));
        console.log("VITE_MOCK_BTC_ADDRESS=%s", address(btc));
        console.log("VITE_MOCK_ETH_ADDRESS=%s", address(eth));
        console.log("");
        console.log("VITE_DEX_FACTORY_ADDRESS=%s", address(ammFactory));
        console.log("VITE_DEX_ROUTER_ADDRESS=%s", address(ammRouter));
        console.log("");
        console.log("VITE_P2P_ESCROW_ADDRESS=%s", address(p2p));
        console.log("");
        console.log("VITE_LIMIT_ORDER_PROTOCOL_ADDRESS=%s", address(limitOrder));
        console.log("");
        console.log("VITE_PERP_ROUTER_ADDRESS=%s", address(perpRouter));
        console.log("VITE_PERP_POSITION_MANAGER_ADDRESS=%s", address(positionManager));
        console.log("VITE_PERP_MARKET_FACTORY_ADDRESS=%s", address(perpMarketFactory));
        console.log("VITE_PERP_MARKET_ETH_ADDRESS=%s", marketAddress);
        console.log("VITE_PERP_VAULT_ETH_ADDRESS=%s", vaultAddress);
        console.log("VITE_PERP_ORACLE_ETH_ADDRESS=%s", oracleAddress);
        console.log("");
        console.log("VITE_COPY_TRADING_FACTORY_ADDRESS=%s", address(copyFactory));
        console.log("VITE_COPY_TRADING_VAULT_IMPL_ADDRESS=%s", address(copyVaultImpl));
        console.log("");
        console.log("### BACKEND ENV ###");
        console.log("USDC_ADDRESS=%s", address(usdc));
        console.log("WETH_ADDRESS=%s", address(eth)); // Treating MockETH as WETH
        console.log("FACTORY_ADDRESS=%s", address(copyFactory));
        console.log("ROUTER_ADDRESS=%s", address(ammRouter));
        console.log("RPC_URL=http://127.0.0.1:8545");
        console.log("PRIVATE_KEY=%s", vm.toString(deployerPrivateKey));
        console.log("=================================================================");
    }
}
