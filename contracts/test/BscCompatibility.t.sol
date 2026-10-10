// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/new_perp/src/core/Market.sol";
import "../src/new_perp/src/core/Vault.sol";
import "../src/new_perp/src/oracle/OracleModule.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {UpgradeableDeploy} from "../script/lib/UpgradeableDeploy.sol";

contract MockUSDC18 is ERC20 {
    constructor() ERC20("Mock USDC 18", "mUSDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockOracle {
    uint256 public price = 60000 * 1e8; // 60k USD
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, int256(price), 0, block.timestamp, 0);
    }
}

contract BscCompatibilityTest is Test {
    Market market;
    Vault vault;
    OracleModule oracleMod;
    MockUSDC18 usdc;
    MockOracle priceFeed;
    address user = address(0x123);
    address pm = address(0x456);

    function setUp() public {
        usdc = new MockUSDC18();
        oracleMod = new OracleModule();
        priceFeed = new MockOracle();
        
        vault = UpgradeableDeploy.deployVault(address(usdc), address(this), address(this));
        market = UpgradeableDeploy.deployMarket(
            "BTC", address(usdc), address(vault), address(oracleMod), address(priceFeed), address(this), address(this)
        );
        
        vault.setMarket(address(market));
        market.setPositionManager(pm);
        
        vm.prank(user);
        usdc.mint(user, 10000 * 1e18); // 10k USDC
    }

    function testVaultDepositScalingBSC() public {
        vm.startPrank(user);
        usdc.approve(address(vault), 1000 * 1e18);
        vault.deposit(1000 * 1e18, user);
        vm.stopPrank();

        // On BSC (18 decimals) quoteScale is 1 (10^(18-18)), so minted = amount.
        // H2: the first deposit permanently locks MINIMUM_LIQUIDITY (1e3) dead shares to block
        // first-depositor inflation, so the depositor receives amount - 1e3.
        uint256 minimumLiquidity = 1e3;
        assertEq(
            vault.balanceOf(user),
            1000 * 1e18 - minimumLiquidity,
            "first depositor gets amount minus locked dead shares on BSC"
        );
        assertEq(
            vault.balanceOf(address(0xdead)),
            minimumLiquidity,
            "dead shares locked on first deposit"
        );
    }

    function testMarketCollateralScalingBSC() public {
        uint256 collateralAmount = 1000 * 1e18; // 1000 USDC
        vm.prank(user);
        usdc.transfer(address(vault), collateralAmount); // Simulate PM moving funds

        uint256 sizeDelta = 5000 * 1e18; // 5k USD notional
        uint256 price = market.getOraclePrice(); // 60k * 1e18 (scaled by oracleMod)

        vm.prank(pm);
        market.increasePosition(user, 0, sizeDelta, collateralAmount, true, price);

        Market.Position memory p = market.getPosition(1);
        
        uint256 expectedFee = (sizeDelta * market.FEE_BPS()) / market.BPS_DIV();
        uint256 expectedCollateral = collateralAmount - expectedFee;
        
        assertEq(p.size, sizeDelta, "Size should match");
        assertEq(p.collateral, expectedCollateral, "Collateral should match net of fee on BSC");
    }
}
