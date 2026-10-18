// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDC} from "../src/new_perp/src/mocks/MockUSDC.sol";
import {MockOracle} from "../src/new_perp/src/mocks/MockOracle.sol";
import {OracleModule} from "../src/new_perp/src/oracle/OracleModule.sol";
import {Router} from "../src/new_perp/src/router/Router.sol";
import {PositionManager} from "../src/new_perp/src/router/PositionManager.sol";
import {MarketFactory} from "../src/new_perp/src/core/MarketFactory.sol";
import {Market} from "../src/new_perp/src/core/Market.sol";
import {Vault} from "../src/new_perp/src/core/Vault.sol";
import {UpgradeableDeploy} from "./lib/UpgradeableDeploy.sol";
import {UpgradeAuthority} from "./lib/UpgradeAuthority.sol";

/**
 * @notice Deploy all new perpetual contracts in sequence
 * 
 * Deployment Order:
 * 1. Deploy MockUSDC (or use existing USDC address)
 * 2. Deploy OracleModule
 * 3. Deploy MockOracle (for testing) or use real Chainlink feed
 * 4. Deploy Router (quote = USDC)
 * 5. Deploy PositionManager (router address)
 * 6. Deploy MarketFactory
 * 7. Call MarketFactory.createMarket(...) to create a market
 * 8. Router: setPositionManager(pm)
 * 
 * Environment Variables:
 * - PRIVATE_KEY: Deployer private key
 * - USDC_ADDRESS: Existing USDC address (optional, will deploy MockUSDC if not set)
 * - DEPLOY_MOCK_USDC: Set to true to deploy MockUSDC even if USDC_ADDRESS is set
 * - BASE_SYMBOL: Base symbol for market (e.g., "ETH", "BTC") - default: "ETH"
 * - INITIAL_PRICE: Initial price in 8 decimals (e.g., 2000e8 for $2000) - default: 2000e8
 * - USE_REAL_ORACLE: Set to true to use real Chainlink feed (requires CHAINLINK_FEED_ADDRESS)
 * - CHAINLINK_FEED_ADDRESS: Real Chainlink feed address (if USE_REAL_ORACLE=true)
 * - INITIAL_VAULT_DEPOSIT: Initial USDC deposit to vault in 6 decimals (e.g., 100000e6 for 100k USDC) - default: 0 (skipped)
 */
contract DeployNewPerp is UpgradeAuthority {
    function run() external {
        // Use default Anvil account (has 10000 ETH)
        // Default: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
        // If PRIVATE_KEY env var is set, use it; otherwise use Anvil default
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(deployerPrivateKey);
        
        // Get configuration from environment
        address usdcAddress = vm.envOr("USDC_ADDRESS", address(0));
        bool deployMockUSDC = vm.envOr("DEPLOY_MOCK_USDC", false);
        string memory baseSymbol = vm.envOr("BASE_SYMBOL", string("ETH"));
        int256 initialPrice = int256(vm.envOr("INITIAL_PRICE", uint256(2000 * 1e8))); // 8 decimals
        bool useRealOracle = vm.envOr("USE_REAL_ORACLE", false);
        address chainlinkFeed = vm.envOr("CHAINLINK_FEED_ADDRESS", address(0));
        
        // Auto-deploy MockUSDC on Anvil (chain ID 31337) for testing
        // This ensures fresh MockUSDC with minted tokens for local testing
        uint256 chainId = block.chainid;
        if (chainId == 31337) {
            if (usdcAddress == address(0) || deployMockUSDC) {
                deployMockUSDC = true;
                console.log("\n=== Auto-deploying MockUSDC on Anvil for testing ===");
            } else {
                // On Anvil, always deploy fresh MockUSDC to ensure minting works
                // User can override with DEPLOY_MOCK_USDC=false if they want to use existing
                bool forceDeploy = vm.envOr("FORCE_DEPLOY_MOCK_USDC", true);
                if (forceDeploy) {
                    deployMockUSDC = true;
                    console.log("\n=== Force deploying fresh MockUSDC on Anvil (will mint tokens) ===");
                }
            }
        }
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Track if we deployed MockUSDC (needed for Step 10)
        bool isMockUSDC = false;
        MockUSDC mockUSDC;
        
        // Step 1: Deploy or use existing USDC
        if (usdcAddress == address(0) || deployMockUSDC) {
            console.log("\n=== Step 1: Deploying MockUSDC ===");
            mockUSDC = new MockUSDC();
            usdcAddress = address(mockUSDC);
            isMockUSDC = true;
            console.log("MockUSDC deployed at:", usdcAddress);
            
            // Mint some USDC to deployer for testing
            mockUSDC.mint(deployer, 1000000 * 1e6); // 1M USDC (6 decimals)
            console.log("Minted 1,000,000 USDC to deployer:", deployer);
            
            // Verify mint
            uint256 balance = mockUSDC.balanceOf(deployer);
            console.log("Deployer USDC balance:", balance / 1e6, "USDC");
        } else {
            console.log("\n=== Step 1: Using existing USDC ===");
            console.log("USDC address:", usdcAddress);
            console.log("Note: No USDC was minted. Make sure you have USDC balance for testing.");
        }
        
        // Step 2: Deploy OracleModule
        console.log("\n=== Step 2: Deploying OracleModule ===");
        OracleModule oracleModule = new OracleModule();
        console.log("OracleModule deployed at:", address(oracleModule));
        
        // Step 3: Deploy MockOracle or use real Chainlink feed
        address priceFeed;
        if (useRealOracle) {
            require(chainlinkFeed != address(0), "CHAINLINK_FEED_ADDRESS must be set when USE_REAL_ORACLE=true");
            console.log("\n=== Step 3: Using real Chainlink feed ===");
            priceFeed = chainlinkFeed;
            console.log("Chainlink feed address:", priceFeed);
        } else {
            console.log("\n=== Step 3: Deploying MockOracle ===");
            MockOracle mockOracle = new MockOracle(initialPrice);
            priceFeed = address(mockOracle);
            console.log("MockOracle deployed at:", priceFeed);
            console.log("Initial price set to:", uint256(initialPrice) / 1e8, "USD (8 decimals)");
        }
        
        // Step 4: Deploy Router
        console.log("\n=== Step 4: Deploying Router ===");
        Router router = new Router(usdcAddress);
        console.log("Router deployed at:", address(router));
        
        // Step 5: Deploy PositionManager
        console.log("\n=== Step 5: Deploying PositionManager ===");
        PositionManager positionManager = new PositionManager(address(router));
        console.log("PositionManager deployed at:", address(positionManager));
        
        // Step 6: Set PositionManager in Router
        console.log("\n=== Step 6: Setting PositionManager in Router ===");
        router.setPositionManager(address(positionManager));
        console.log("PositionManager set in Router");
        
        // Step 7: Deploy MarketFactory
        console.log("\n=== Step 7: Deploying MarketFactory ===");
        // Market/Vault are BeaconProxies. On a local chain the deployer owns the beacons; elsewhere
        // set UPGRADE_ADMIN or UPGRADE_TIMELOCK_DELAY (see UpgradeAuthority).
        address upgradeAdmin = _resolveUpgradeAdmin(deployer);
        UpgradeableDeploy.Perp memory perp = UpgradeableDeploy.deployPerp(upgradeAdmin);
        MarketFactory factory = perp.factory;
        console.log("Market beacon:", address(perp.marketBeacon));
        console.log("Vault beacon:", address(perp.vaultBeacon));
        console.log("MarketFactory deployed at:", address(factory));
        
        // Step 8: Create Market via Factory
        console.log("\n=== Step 8: Creating Market ===");
        (address market, address vault) = factory.createMarket(
            baseSymbol,
            usdcAddress,
            address(oracleModule),
            priceFeed,
            address(positionManager)
        );
        console.log("Market created at:", market);
        console.log("Vault created at:", vault);
        
        // Step 9: Set PositionManager in Market
        // Note: MarketFactory doesn't set positionManager automatically, so we need to set it here
        // The Market owner is the factory owner (deployer), so we can call setPositionManager
        console.log("\n=== Step 9: Setting PositionManager in Market ===");
        Market marketContract = Market(market);
        marketContract.setPositionManager(address(positionManager));
        console.log("PositionManager set in Market");
        
        // Step 10: Optional - Seed initial vault liquidity
        uint256 initialVaultDeposit = vm.envOr("INITIAL_VAULT_DEPOSIT", uint256(0));
        if (initialVaultDeposit > 0) {
            console.log("\n=== Step 10: Seeding Vault with initial liquidity ===");
            Vault vaultContract = Vault(vault);
            
            // Check if we have MockUSDC (for testing) or need to use IERC20
            // If we deployed MockUSDC, we can use it directly; otherwise user must approve manually
            if (isMockUSDC) {
                // We have MockUSDC, can use it directly
                
                // Check deployer has enough balance
                uint256 deployerBalance = mockUSDC.balanceOf(deployer);
                if (deployerBalance < initialVaultDeposit) {
                    console.log("Warning: Deployer balance insufficient. Minting additional USDC...");
                    uint256 needed = initialVaultDeposit - deployerBalance;
                    mockUSDC.mint(deployer, needed);
                    console.log("Minted", needed / 1e6, "additional USDC to deployer");
                }
                
                // Approve vault to spend USDC
                mockUSDC.approve(vault, initialVaultDeposit);
                console.log("Approved", initialVaultDeposit / 1e6, "USDC for vault");
                
                // Deposit to vault
                vaultContract.deposit(initialVaultDeposit, deployer);
                console.log("Deposited", initialVaultDeposit / 1e6, "USDC to vault");
                console.log("LP tokens received:", vaultContract.balanceOf(deployer) / 1e18);
                console.log("Vault total assets:", vaultContract.totalAssets() / 1e6, "USDC");
            } else {
                // Using real USDC - user must have approved the script or have allowance
                // For real USDC, we assume user has already approved or will approve manually
                console.log("Note: Using real USDC. Make sure deployer has:");
                console.log("  1. Sufficient USDC balance (USDC):", initialVaultDeposit / 1e6);
                console.log("  2. Approved vault to spend USDC");
                console.log("  3. Or approve vault address:", vault);
                console.log("You can deposit manually by calling:");
                console.log("  Vault.deposit(amount, deployer)");
                console.log("  Vault address:", vault);
                console.log("  Amount:", initialVaultDeposit);
            }
        } else {
            console.log("\n=== Step 10: Skipping initial vault deposit ===");
            console.log("Set INITIAL_VAULT_DEPOSIT env var to seed vault (e.g., 100000e6 for 100k USDC)");
            console.log("Note: Vault needs liquidity for traders to open positions");
            console.log("Users can deposit USDC to vault to earn fees from trading");
        }
        
        // Summary
        console.log("\n=== Deployment Summary ===");
        console.log("USDC:", usdcAddress);
        console.log("OracleModule:", address(oracleModule));
        console.log("PriceFeed:", priceFeed);
        console.log("Router:", address(router));
        console.log("PositionManager:", address(positionManager));
        console.log("MarketFactory:", address(factory));
        console.log("Market:", market);
        console.log("Vault:", vault);
        console.log("Base Symbol:", baseSymbol);
        console.log("Deployer:", deployer);
        
        console.log("\n=== Environment Variables for Frontend ===");
        console.log("VITE_PERP_ROUTER_ADDRESS=", address(router));
        console.log("VITE_PERP_MARKET_ADDRESS=", market);
        console.log("VITE_PERP_VAULT_ADDRESS=", vault);
        console.log("VITE_PERP_POSITION_MANAGER_ADDRESS=", address(positionManager));
        console.log("VITE_USDC_ADDRESS=", usdcAddress);
        
        console.log("\n=== Environment Variables for Backend ===");
        console.log("PERP_ROUTER_ADDRESS=", address(router));
        console.log("PERP_MARKET_ADDRESS=", market);
        console.log("PERP_VAULT_ADDRESS=", vault);
        console.log("PERP_POSITION_MANAGER_ADDRESS=", address(positionManager));
        console.log("USDC_ADDRESS=", usdcAddress);
        console.log("ORACLE_MODULE_ADDRESS=", address(oracleModule));
        console.log("PRICE_FEED_ADDRESS=", priceFeed);
        
        console.log("\n=== Next Steps ===");
        console.log("1. Update your .env files with the addresses above");
        console.log("2. If using MockOracle, you can update prices by calling:");
        console.log("   MockOracle.setAnswer(newPriceIn8Decimals)");
        console.log("   MockOracle address:", priceFeed);
        console.log("3. Vault Liquidity:");
        console.log("   - LPs can deposit USDC to vault to earn trading fees");
        console.log("   - Call Vault.deposit(amount, to) after approving USDC");
        console.log("   - Vault address:", vault);
        console.log("   - LPs receive pLP tokens representing their share");
        console.log("   - Withdraw by calling Vault.withdraw(shares, to)");
        console.log("4. Users can now create increase/decrease requests via Router");
        console.log("   - Use positionId = 0 for new positions");
        console.log("   - Use positionId > 0 to add to existing positions");
        console.log("   - Always specify positionId when closing positions");
        console.log("   - Users can have multiple long and short positions simultaneously");
        console.log("5. Keepers can execute requests via PositionManager");
        console.log("6. Frontend should track positionIds per user and display all positions");
        console.log("7. Liquidation now requires positionId - check each position individually");
        
        vm.stopBroadcast();
    }
}

