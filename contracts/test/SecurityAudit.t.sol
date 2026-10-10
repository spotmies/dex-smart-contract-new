// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/new_perp/src/mocks/MockUSDC.sol";
import "../src/new_perp/src/mocks/MockOracle.sol";
import "../src/new_perp/src/oracle/OracleModule.sol";
import "../src/new_perp/src/core/MarketFactory.sol";
import "../src/new_perp/src/core/Market.sol";
import "../src/new_perp/src/core/Vault.sol";
import "../src/new_perp/src/router/Router.sol";
import "../src/new_perp/src/router/PositionManager.sol";
import {UpgradeableDeploy} from "../script/lib/UpgradeableDeploy.sol";

contract SecurityAuditTest is Test {
    MockUSDC usdc;
    MockOracle oracle;
    OracleModule oracleModule;
    MarketFactory factory;
    Router router;
    PositionManager pm;
    Market market;
    Vault vault;

    address lp = address(0x1);
    address trader = address(0x2);
    address hacker = address(0x666); // The malicious actor
    address keeper = address(0x999); // The authorised executor

    uint256 constant WAD = 1e18;

    function setUp() public {
        // 1. Setup Contracts
        usdc = new MockUSDC();
        oracle = new MockOracle(2_000 * 1e8); // ETH $2000
        oracleModule = new OracleModule();
        router = new Router(address(usdc));
        pm = new PositionManager(address(router));
        // Market/Vault are beacon proxies now; this test contract owns the beacons.
        factory = UpgradeableDeploy.deployPerp(address(this)).factory;

        (address marketAddr, address vaultAddr) = factory.createMarket(
            "ETH",
            address(usdc),
            address(oracleModule),
            address(oracle),
            address(pm)
        );
        market = Market(marketAddr);
        vault = Vault(vaultAddr);

        router.setPositionManager(address(pm));
        market.setPositionManager(address(pm));
        pm.setKeeper(keeper, true);

        // 2. Fund Accounts
        usdc.mint(lp, 1_000_000 * 1e6);
        usdc.mint(trader, 10_000 * 1e6);
        usdc.mint(hacker, 1_000 * 1e6); // Hacker has some gas money

        // 3. LP Provides Liquidity
        vm.startPrank(lp);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000 * 1e6, lp);
        vm.stopPrank();

        // 4. Trader Approves Router
        vm.startPrank(trader);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function test_Security_HackerExecuteLong_UserGetsProfit() public {
        // --- 1. Trader Opens Long Position ---
        uint256 sizeUsd = 1_000 * WAD; // $1000 size
        uint256 collateral = 200 * 1e6; // $200 collateral
        uint256 fee = 1 * 1e6; // $1 exec fee

        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market),
            0,
            sizeUsd,
            collateral,
            true, // Long
            2_100 * 1e18, 
            fee
        );

        // Execution is now keeper-gated: an arbitrary address cannot execute at all.
        _advanceBlock();
        vm.prank(hacker);
        vm.expectRevert(PositionManager.NotKeeper.selector);
        pm.executeIncrease(reqId);

        // Valid keeper executes open (this part is normal)
        vm.prank(keeper);
        pm.executeIncrease(reqId);

        // --- 2. Price Moves Up (Profit) ---
        oracle.setAnswer(2_200 * 1e8); // $2000 -> $2200 (+10% profit)
        // Profit roughly: 1000 * 10% = $100
        
        uint256 traderBalanceBefore = usdc.balanceOf(trader);
        uint256 hackerBalanceBefore = usdc.balanceOf(hacker);

        // --- 3. Trader Requests Close ---
        vm.prank(trader);
        uint256 closeReqId = router.createDecreaseRequest(
            address(market),
            1, // positionId
            sizeUsd,
            true, // Long
            2_100 * 1e18,
            fee
        );

        // --- 4. HACKER tries to execute, then the keeper does ---
        _advanceBlock();
        vm.prank(hacker);
        vm.expectRevert(PositionManager.NotKeeper.selector);
        pm.executeDecrease(closeReqId);

        vm.prank(keeper);
        pm.executeDecrease(closeReqId);

        // --- 5. Verify Balances ---
        uint256 traderBalanceAfter = usdc.balanceOf(trader);
        uint256 hackerBalanceAfter = usdc.balanceOf(hacker);

        uint256 profit = traderBalanceAfter - traderBalanceBefore;

        // Trader should have: Collateral ($200) + Profit (~$100) - Fees
        // Should be > $200
        assertGt(profit, 200 * 1e6, "Trader received collateral + profit");

        // The hacker is not a keeper, so both of their attempts reverted: they earn
        // nothing at all - not the trade profit, and not even the execution fee, which
        // now goes to the registered keeper that actually did the work.
        uint256 hackerGain = hackerBalanceAfter - hackerBalanceBefore;
        assertEq(hackerGain, 0, "Non-keeper gained nothing");
        assertEq(usdc.balanceOf(keeper), fee * 2, "Keeper earned both execution fees");
    }

    // Execution is gated behind minExecutionDelayBlocks, so a request can never be
    // executed in the block it was created in. Uses a monotonic counter rather than
    // block.number + 1, which does not reliably advance across a single test body.
    uint256 private _blk;

    function _advanceBlock() internal {
        if (_blk == 0) _blk = block.number;
        _blk += 1;
        vm.roll(_blk);
    }

}
