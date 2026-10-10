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

/// @notice Tests for the C3 (initial-margin / max-leverage) and H5 (funding settlement +
/// accurate weighted-entry) fixes in the new_perp Market.
contract SecurityFixesTest is Test {
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
    address keeper = address(0x3);

    uint256 constant WAD = 1e18;

    function setUp() public {
        usdc = new MockUSDC();
        usdc.mint(lp, 1_000_000 * 1e6);
        usdc.mint(trader, 100_000 * 1e6);
        oracle = new MockOracle(2_000 * 1e8); // $2000
        oracleModule = new OracleModule();
        router = new Router(address(usdc));
        pm = new PositionManager(address(router));
        // Market/Vault are beacon proxies now; this test contract owns the beacons.
        factory = UpgradeableDeploy.deployPerp(address(this)).factory;

        (address marketAddr, address vaultAddr) = factory.createMarket(
            "ETH", address(usdc), address(oracleModule), address(oracle), address(pm)
        );
        market = Market(marketAddr);
        vault = Vault(vaultAddr);

        router.setPositionManager(address(pm));
        market.setPositionManager(address(pm));
        pm.setKeeper(address(this), true);
        pm.setKeeper(keeper, true);

        vm.prank(lp);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(trader);
        usdc.approve(address(router), type(uint256).max);

        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);
    }

    function _priceUp(uint256 newPrice) internal {
        oracle.setAnswer(int256(newPrice));
    }

    function _openLong(uint256 sizeUsd, uint256 collateral, uint256 acceptable) internal returns (uint256) {
        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market), 0, sizeUsd, collateral, true, acceptable, 1 * 1e6
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(reqId);
        uint256[] memory ids = market.getUserPositionIds(trader);
        return ids[ids.length - 1];
    }

    function _openShort(uint256 sizeUsd, uint256 collateral, uint256 acceptable) internal returns (uint256) {
        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market), 0, sizeUsd, collateral, false, acceptable, 1 * 1e6
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(reqId);
        uint256[] memory ids = market.getUserPositionIds(trader);
        return ids[ids.length - 1];
    }

    // ---------- C3: initial-margin / max-leverage ----------

    function testC3_RejectsExcessiveLeverage() public {
        // size $5000 with $100 collateral = 50x, far above the 10x cap.
        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market), 0, 5_000 * WAD, 100 * 1e6, true, 2_100 * 1e18, 1 * 1e6
        );
        _advanceBlock();
        vm.prank(keeper);
        vm.expectRevert(bytes("exceeds max leverage"));
        pm.executeIncrease(reqId);
    }

    function testC3_AllowsWithinLeverage() public {
        // size $5000 with $600 collateral ~= 8.4x, within the 10x cap.
        uint256 posId = _openLong(5_000 * WAD, 600 * 1e6, 2_100 * 1e18);
        Market.Position memory p = market.getPosition(posId);
        assertEq(p.size, 5_000 * WAD, "position opened");
    }

    function testC3_RejectsAddThatBreachesLeverage() public {
        // Open healthy, then try to add a large size with no extra collateral -> breach.
        uint256 posId = _openLong(2_000 * WAD, 600 * 1e6, 2_100 * 1e18);
        // collateralDelta 20 USDC clears the fee (10 USDC for +$10k size) but still leaves the
        // combined $12k position far above 10x, so the leverage check is what reverts.
        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market), posId, 10_000 * WAD, 20 * 1e6, true, 2_100 * 1e18, 1 * 1e6
        );
        _advanceBlock();
        vm.prank(keeper);
        vm.expectRevert(bytes("exceeds max leverage"));
        pm.executeIncrease(reqId);
    }

    function testC3_SetMaxLeverageBound() public {
        // 20x would make initial margin == maintenance margin (5%) -> rejected.
        vm.expectRevert(bytes("bad leverage"));
        market.setMaxLeverage(20);
        // A safe value is accepted.
        market.setMaxLeverage(5);
        assertEq(market.maxLeverage(), 5, "max leverage updated");
    }

    // ---------- H5: accurate weighted-entry on close ----------

    function testH5_AvgEntryAccurateAfterClose() public {
        // Open long #1: $1000 @ $2000
        uint256 pos1 = _openLong(1_000 * WAD, 500 * 1e6, 2_100 * 1e18);
        // Move price to $3000 and open long #2: $1000 @ $3000
        _priceUp(3_000 * 1e8);
        uint256 pos2 = _openLong(1_000 * WAD, 500 * 1e6, 3_100 * 1e18);

        // Aggregate avg entry must be (1000*2000 + 1000*3000)/2000 = 2500.
        assertEq(market.avgEntryLongPrice(), 2_500 * WAD, "avg entry after both opens");

        // Fully close #1 (entry $2000). Only #2 (entry $3000) remains.
        vm.prank(trader);
        uint256 reqId = router.createDecreaseRequest(
            address(market), pos1, 1_000 * WAD, true, 2_900 * 1e18, 1 * 1e6
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeDecrease(reqId);

        // BEFORE the fix avg entry stayed at the drifted 2500; AFTER it must reflect only #2.
        assertEq(market.avgEntryLongPrice(), 3_000 * WAD, "avg entry recomputed after close");
        assertEq(market.getPosition(pos2).size, 1_000 * WAD, "pos2 intact");
    }

    // ---------- H5: funding settled on increase (not wiped) ----------

    function testH5_FundingSettledOnIncrease() public {
        // Longs only -> funding accrues to longs over time.
        uint256 posId = _openLong(1_000 * WAD, 500 * 1e6, 2_100 * 1e18);
        uint256 collBefore = market.getPosition(posId).collateral;

        // Let a week pass so funding accrues on the existing size.
        vm.warp(block.timestamp + 7 days);
        // Refresh the oracle timestamp (same price) so it is not flagged stale after the warp.
        _priceUp(2_000 * 1e8);

        // Add a dust size with near-zero extra collateral (just above the fee).
        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market), posId, 1 * WAD, 2_000, true, 2_100 * 1e18, 1 * 1e6
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(reqId);

        // Funding accrued on the old size must have been settled into collateral, so the
        // collateral grew by far more than the negligible dust contribution.
        uint256 collAfter = market.getPosition(posId).collateral;
        assertGt(collAfter, collBefore + 1 * 1e6, "accrued funding settled into collateral");
    }

    // ---------- C3 edge cases ----------

    function testC3_RejectsExcessiveLeverageShort() public {
        // Same 50x breach but on the short side.
        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market), 0, 5_000 * WAD, 100 * 1e6, false, 1_900 * 1e18, 1 * 1e6
        );
        _advanceBlock();
        vm.prank(keeper);
        vm.expectRevert(bytes("exceeds max leverage"));
        pm.executeIncrease(reqId);
    }

    function testC3_BoundaryExactlyMaxLeverage() public {
        // size $5000, fee $5, collateralNet must be exactly $500 for 10x -> collateralDelta $505.
        // The check uses >=, so exactly 10x must be ACCEPTED.
        uint256 posId = _openLong(5_000 * WAD, 505 * 1e6, 2_100 * 1e18);
        assertEq(market.getPosition(posId).size, 5_000 * WAD, "exactly-10x position opened");
    }

    function testC3_LiquidationStillWorks() public {
        // A healthy (within-cap) position must still be liquidatable when it goes underwater.
        uint256 posId = _openLong(5_000 * WAD, 600 * 1e6, 2_100 * 1e18);
        _priceUp(1_800 * 1e8); // long loses ~$500 on $5000 size -> below 5% maintenance
        vm.prank(keeper);
        pm.liquidate(address(market), posId);
        uint256[] memory ids = market.getUserPositionIds(trader);
        assertEq(ids.length, 0, "position liquidated and removed");
        assertEq(market.oiLong(), 0, "oi cleared");
        assertEq(market.avgEntryLongPrice(), 0, "avg entry reset to 0 with no OI");
    }

    // ---------- H5: negative funding must be settled without underflow ----------

    function testH5_NegativeFundingSettledNoUnderflow() public {
        // Open a small long, then a large short so shorts dominate -> longs' cumulative funding
        // goes negative, i.e. the long position will OWE funding on its next interaction.
        uint256 longPos = _openLong(1_000 * WAD, 500 * 1e6, 2_100 * 1e18);
        _openShort(8_000 * WAD, 4_000 * 1e6, 1_900 * 1e18);

        uint256 collBefore = market.getPosition(longPos).collateral;

        vm.warp(block.timestamp + 7 days);
        _priceUp(2_000 * 1e8); // refresh oracle timestamp

        // Touch the long with a tiny add; this must settle the (negative) accrued funding.
        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market), longPos, 1 * WAD, 2 * 1e6, true, 2_100 * 1e18, 1 * 1e6
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(reqId); // must NOT revert/underflow

        uint256 collAfter = market.getPosition(longPos).collateral;
        assertLt(collAfter, collBefore, "negative funding reduced collateral");
        assertGt(collAfter, 0, "no underflow / over-deduction");
    }

    // ---------- H5: avg entry accurate after a liquidation removes a position ----------

    function testH5_AvgEntryAccurateAfterLiquidation() public {
        // pos1: low leverage, entry $2000. pos2: higher leverage, entry $3000.
        uint256 pos1 = _openLong(2_000 * WAD, 1_000 * 1e6, 2_100 * 1e18); // 2x
        _priceUp(3_000 * 1e8);
        uint256 pos2 = _openLong(2_000 * WAD, 250 * 1e6, 3_100 * 1e18); // 8x @ $3000

        // avg = (2000*2000 + 2000*3000)/4000 = 2500
        assertEq(market.avgEntryLongPrice(), 2_500 * WAD, "avg entry across both");

        // Drop to $2400: pos2 (entry 3000, 8x) is underwater & liquidatable; pos1 (2x) survives.
        _priceUp(2_400 * 1e8);
        vm.prank(keeper);
        pm.liquidate(address(market), pos2);

        // Only pos1 (entry 2000) remains -> aggregate avg entry must be exactly 2000.
        assertEq(market.avgEntryLongPrice(), 2_000 * WAD, "avg entry recomputed after liquidation");
        assertEq(market.getPosition(pos1).size, 2_000 * WAD, "pos1 intact");
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
