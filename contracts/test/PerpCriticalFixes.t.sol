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

/// @notice Regression tests for the two critical findings in the new_perp stack.
///
/// C1 - the Vault priced LP shares against its raw USDC balance, which also holds
///      trader collateral. LPs could redeem money they did not own and leave traders
///      unable to close.
/// C2 - the request/execute split enforced no delay and execution was permissionless,
///      so a trader could request and execute in one transaction at a price they
///      could already see (oracle latency arbitrage against the LP vault).
///
/// Every test here fails against the pre-fix contracts.
contract PerpCriticalFixesTest is Test {
    MockUSDC usdc;
    MockOracle oracle;
    OracleModule oracleModule;
    MarketFactory factory;
    Router router;
    PositionManager pm;
    Market market;
    Vault vault;

    address lpA = address(0xA);
    address lpB = address(0xB);
    address trader = address(0x2);
    address keeper = address(0x3);
    address outsider = address(0x666);

    uint256 constant WAD = 1e18;
    uint256 private _blk;

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockOracle(2_000 * 1e8);
        oracleModule = new OracleModule();
        router = new Router(address(usdc));
        pm = new PositionManager(address(router));
        // Market/Vault are beacon proxies now; this test contract owns the beacons.
        factory = UpgradeableDeploy.deployPerp(address(this)).factory;

        (address m, address v) = factory.createMarket(
            "ETH", address(usdc), address(oracleModule), address(oracle), address(pm)
        );
        market = Market(m);
        vault = Vault(v);

        router.setPositionManager(address(pm));
        market.setPositionManager(address(pm));
        pm.setKeeper(keeper, true);

        address[4] memory actors = [lpA, lpB, trader, outsider];
        for (uint256 i = 0; i < actors.length; i++) {
            usdc.mint(actors[i], 500_000 * 1e6);
            vm.prank(actors[i]);
            usdc.approve(address(vault), type(uint256).max);
            vm.prank(actors[i]);
            usdc.approve(address(router), type(uint256).max);
        }
    }

    function _advanceBlock() internal {
        if (_blk == 0) _blk = block.number;
        _blk += 1;
        vm.roll(_blk);
    }

    function _open(uint256 size, uint256 collat, bool isLong) internal returns (uint256) {
        vm.prank(trader);
        uint256 id = router.createIncreaseRequest(
            address(market), 0, size, collat, isLong, isLong ? type(uint256).max : 0, 0
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(id);
        uint256[] memory ids = market.getUserPositionIds(trader);
        return ids[ids.length - 1];
    }

    // =========================================================================
    // C1 - trader collateral is not LP equity
    // =========================================================================

    /// Trader collateral must be reported as reserved, never as LP assets.
    function testC1_TraderCollateralIsNotCountedAsLpEquity() public {
        vm.prank(lpA);
        vault.deposit(100_000 * 1e6, lpA);
        uint256 lpEquityBefore = vault.totalAssets();

        _open(20_000 * WAD, 10_000 * 1e6, true);

        uint256 openFee = (20_000 * WAD * market.FEE_BPS()) / market.BPS_DIV() / 1e12;
        assertEq(vault.reservedAssets(), 10_000 * 1e6 - openFee, "collateral reserved");
        assertEq(vault.totalAssets(), lpEquityBefore + openFee, "LP equity only gains the fee");
        assertEq(
            usdc.balanceOf(address(vault)),
            100_000 * 1e6 + 10_000 * 1e6,
            "raw balance holds both"
        );
    }

    /// An LP redeeming everything must get back only its own money - never the
    /// trader's collateral. Pre-fix this paid out roughly double.
    function testC1_LpCannotRedeemTraderCollateral() public {
        vm.prank(lpA);
        vault.deposit(50_000 * 1e6, lpA);

        _open(100_000 * WAD, 50_000 * 1e6, true);

        uint256 shares = vault.balanceOf(lpA);
        uint256 before = usdc.balanceOf(lpA);
        vm.prank(lpA);
        vault.withdraw(shares, lpA);
        uint256 got = usdc.balanceOf(lpA) - before;

        uint256 openFee = (100_000 * WAD * market.FEE_BPS()) / market.BPS_DIV() / 1e12;
        // LP is entitled to its principal plus the fee it earned, and nothing more.
        assertLe(got, 50_000 * 1e6 + openFee, "LP took no trader collateral");
    }

    /// Partial redemption by one of several LPs, with traders in profit so the
    /// solvency guard is live, must still pay only fair value.
    function testC1_PartialWithdrawWithProfitableTradersIsFair() public {
        vm.prank(lpA);
        vault.deposit(100_000 * 1e6, lpA);
        vm.prank(lpB);
        vault.deposit(100_000 * 1e6, lpB);

        _open(100_000 * WAD, 25_000 * 1e6, true);
        oracle.setAnswer(int256(2_100 * 1e8)); // longs in profit
        assertGt(market.unrealizedProfits(), 0, "guard is live");

        uint256 shares = vault.balanceOf(lpA) / 3;
        uint256 before = usdc.balanceOf(lpA);
        vm.prank(lpA);
        vault.withdraw(shares, lpA);
        uint256 got = usdc.balanceOf(lpA) - before;

        // A third of a 100k stake, plus a share of the small open fee. Pre-fix this
        // returned ~38.8k because trader collateral inflated the share price.
        assertLt(got, 34_000 * 1e6, "payout is fair value, not inflated by collateral");
    }

    /// The trader must always be able to close after LPs have exited.
    function testC1_TraderCanStillCloseAfterLpsExit() public {
        vm.prank(lpA);
        vault.deposit(50_000 * 1e6, lpA);
        uint256 pos = _open(100_000 * WAD, 50_000 * 1e6, true);

        uint256 shares = vault.balanceOf(lpA);
        vm.prank(lpA);
        vault.withdraw(shares, lpA);

        vm.prank(trader);
        uint256 id = router.createDecreaseRequest(address(market), pos, 100_000 * WAD, true, 0, 0);
        _advanceBlock();
        vm.prank(keeper);
        pm.executeDecrease(id); // pre-fix: reverted, collateral was gone

        assertEq(market.getPosition(pos).size, 0, "position closed");
        assertEq(market.totalCollateral(), 0, "reservation released");
    }

    /// LP equity now excludes reserved collateral, but traders' unrealized profits are
    /// still owed on top of it. Draining the last of the LP equity while a profitable
    /// position is open must hit the solvency guard rather than stranding the trader.
    function testC1_OverdrawRevertsOnSolvencyGuard() public {
        vm.prank(lpA);
        vault.deposit(50_000 * 1e6, lpA);
        _open(100_000 * WAD, 12_000 * 1e6, true);

        oracle.setAnswer(int256(2_100 * 1e8)); // trader up ~5,000
        assertGt(market.unrealizedProfits(), 0, "position is profitable");

        uint256 shares = vault.balanceOf(lpA);
        vm.prank(lpA);
        vm.expectRevert(Vault.InsufficientLiquidity.selector);
        vault.withdraw(shares, lpA);

        // A smaller redemption that leaves the profits covered still works.
        vm.prank(lpA);
        vault.withdraw(shares / 4, lpA);
    }

    /// Zero-size increases used to mint a position that could never be closed,
    /// stranding its collateral inside the reservation forever.
    function testC1_ZeroSizeIncreaseRejected() public {
        vm.prank(lpA);
        vault.deposit(100_000 * 1e6, lpA);

        vm.prank(trader);
        uint256 id = router.createIncreaseRequest(
            address(market), 0, 0, 500 * 1e6, true, type(uint256).max, 0
        );
        _advanceBlock();
        vm.prank(keeper);
        vm.expectRevert(bytes("size=0"));
        pm.executeIncrease(id);
    }

    // =========================================================================
    // C2 - requests cannot be executed at a price the caller already knows
    // =========================================================================

    /// The core fix: no execution in the request's own block.
    function testC2_CannotExecuteInSameBlock() public {
        vm.prank(lpA);
        vault.deposit(100_000 * 1e6, lpA);

        vm.prank(trader);
        uint256 id = router.createIncreaseRequest(
            address(market), 0, 20_000 * WAD, 10_000 * 1e6, true, type(uint256).max, 0
        );

        vm.prank(keeper);
        vm.expectRevert(PositionManager.TooSoon.selector);
        pm.executeIncrease(id); // pre-fix: succeeded

        // One block later the same request executes normally.
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(id);
        assertEq(market.getUserPositionCount(trader), 1, "executes after the delay");
    }

    function testC2_DecreaseAlsoDelayed() public {
        vm.prank(lpA);
        vault.deposit(100_000 * 1e6, lpA);
        uint256 pos = _open(20_000 * WAD, 10_000 * 1e6, true);

        vm.prank(trader);
        uint256 id = router.createDecreaseRequest(address(market), pos, 20_000 * WAD, true, 0, 0);

        vm.prank(keeper);
        vm.expectRevert(PositionManager.TooSoon.selector);
        pm.executeDecrease(id);
    }

    /// Without a keeper allowlist a trader self-executes and picks their own block,
    /// which defeats the delay above.
    function testC2_NonKeeperCannotExecute() public {
        vm.prank(lpA);
        vault.deposit(100_000 * 1e6, lpA);

        vm.prank(trader);
        uint256 id = router.createIncreaseRequest(
            address(market), 0, 20_000 * WAD, 10_000 * 1e6, true, type(uint256).max, 0
        );
        _advanceBlock();

        vm.prank(trader); // the trader is the party that benefits from self-execution
        vm.expectRevert(PositionManager.NotKeeper.selector);
        pm.executeIncrease(id);

        vm.prank(outsider);
        vm.expectRevert(PositionManager.NotKeeper.selector);
        pm.executeIncrease(id);
    }

    function testC2_NonKeeperCannotLiquidate() public {
        vm.prank(lpA);
        vault.deposit(500_000 * 1e6, lpA);
        uint256 pos = _open(100_000 * WAD, 12_000 * 1e6, true);

        oracle.setAnswer(int256(1_000 * 1e8)); // deeply underwater

        vm.prank(outsider);
        vm.expectRevert(PositionManager.NotKeeper.selector);
        pm.liquidate(address(market), pos);

        vm.prank(keeper);
        pm.liquidate(address(market), pos);
        assertEq(market.getPosition(pos).size, 0, "keeper can still liquidate");
    }

    /// The delay must not be configurable away, and only the owner may touch it.
    function testC2_DelayCannotBeDisabled() public {
        vm.expectRevert(bytes("delay too low"));
        pm.setMinExecutionDelayBlocks(0);

        pm.setMinExecutionDelayBlocks(3);
        assertEq(pm.minExecutionDelayBlocks(), 3, "owner can raise the delay");

        vm.prank(outsider);
        vm.expectRevert();
        pm.setMinExecutionDelayBlocks(1);

        vm.prank(outsider);
        vm.expectRevert();
        pm.setKeeper(outsider, true);
    }

    /// End-to-end: the latency-arbitrage sequence that extracted ~17% pre-fix is
    /// no longer expressible - the open cannot land in the block it was requested in.
    function testC2_LatencyArbitrageBlocked() public {
        vm.prank(lpA);
        vault.deposit(500_000 * 1e6, lpA);

        // Attacker spots a pending oracle update and tries to open ahead of it.
        vm.prank(trader);
        uint256 id = router.createIncreaseRequest(
            address(market), 0, 150_000 * WAD, 20_000 * 1e6, true, type(uint256).max, 0
        );

        vm.prank(keeper);
        vm.expectRevert(PositionManager.TooSoon.selector);
        pm.executeIncrease(id);

        // By the time execution is legal the update has landed, so the entry price is
        // the post-update one: the free profit is gone.
        oracle.setAnswer(int256(2_050 * 1e8));
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(id);

        uint256[] memory ids = market.getUserPositionIds(trader);
        assertEq(market.getPosition(ids[0]).entryPrice, 2_050 * WAD, "entered at the new price");
    }
}
