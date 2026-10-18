// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/mocks/MockUSDC.sol";
import "../src/mocks/MockOracle.sol";
import "../src/oracle/OracleModule.sol";
import "../src/core/MarketFactory.sol";
import "../src/core/Market.sol";
import "../src/core/Vault.sol";
import "../src/router/Router.sol";
import "../src/router/PositionManager.sol";
import {UpgradeableDeploy} from "../../../script/lib/UpgradeableDeploy.sol";

contract MarketTest is Test {
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
        usdc.mint(trader, 10_000 * 1e6);
        oracle = new MockOracle(2_000 * 1e8); // $2000
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
        pm.setKeeper(address(this), true);
        pm.setKeeper(keeper, true);

        vm.prank(lp);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(trader);
        usdc.approve(address(router), type(uint256).max);
    }

    function _priceUp(uint256 newPrice) internal {
        oracle.setAnswer(int256(newPrice)); // 8 decimals
    }


    // Helper to get positionId from event
    function _getPositionIdFromEvent(address user) internal returns (uint256) {
        uint256[] memory ids = market.getUserPositionIds(user);
        require(ids.length > 0, "no positions");
        return ids[ids.length - 1]; // Return latest position ID
    }

    // ========== BASIC LIFECYCLE TEST ==========
    function testLifecycle() public {
        // LP deposit
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        // Trader opens 1000 USD long with 200 USDC collateral, fee inside collateral
        uint256 sizeUsd = 1_000 * WAD;
        uint256 collateral = 200 * 1e6;
        uint256 executionFee = 1 * 1e6;

        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market),
            0, // positionId = 0 for new position
            sizeUsd,
            collateral,
            true,
            2_050 * 1e18, // acceptable
            executionFee
        );

        // Keeper executes at 2000
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(reqId);

        // Get positionId from user's positions
        uint256 positionId = _getPositionIdFromEvent(trader);

        // Price goes to 2200
        _priceUp(2_200 * 1e8);

        vm.prank(trader);
        uint256 decReq = router.createDecreaseRequest(
            address(market),
            positionId, // positionId required
            sizeUsd,
            true,
            2_150 * 1e18,
            executionFee
        );

        _advanceBlock();
        vm.prank(keeper);
        pm.executeDecrease(decReq);

        // Trader should have more than initial (200 collateral - fees + profit)
        uint256 bal = usdc.balanceOf(trader);
        assertGt(bal, 10_000 * 1e6, "profit expected");
    }

    function testLiquidation() public {
        vm.prank(lp);
        vault.deposit(500_000 * 1e6, lp);

        uint256 sizeUsd = 5_000 * WAD;
        uint256 collateral = 600 * 1e6; // C3: must respect 10x initial-margin cap
        uint256 executionFee = 1 * 1e6;

        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market),
            0, // new position
            sizeUsd,
            collateral,
            true,
            2_100 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(reqId);

        uint256 positionId = _getPositionIdFromEvent(trader);

        // Crash price to 1000
        _priceUp(1_000 * 1e8);

        vm.prank(keeper);
        pm.liquidate(address(market), positionId);

        Market.Position memory p = market.getPosition(positionId);
        assertEq(p.size, 0, "position cleared");
    }

    // ========== SHORT LIFECYCLE TEST ==========
    function testShortLifecycle() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 sizeUsd = 1_000 * WAD;
        uint256 collateral = 200 * 1e6;
        uint256 executionFee = 1 * 1e6;
        uint256 initialTraderBal = usdc.balanceOf(trader);

        // Open short at $2000
        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market),
            0, // new position
            sizeUsd,
            collateral,
            false, // short
            1_950 * 1e18, // acceptable price (below current)
            executionFee
        );

        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(reqId);

        uint256 positionId = _getPositionIdFromEvent(trader);
        Market.Position memory p = market.getPosition(positionId);
        assertEq(p.size, sizeUsd, "short size");
        assertEq(p.isLong, false, "is short");
        assertEq(p.entryPrice, 2_000 * 1e18, "entry price");

        // Price drops to $1800 (short profits)
        _priceUp(1_800 * 1e8);

        // Close short
        vm.prank(trader);
        uint256 decReq = router.createDecreaseRequest(
            address(market),
            positionId,
            sizeUsd,
            false, // short
            1_850 * 1e18, // acceptable (above current)
            executionFee
        );

        _advanceBlock();
        vm.prank(keeper);
        pm.executeDecrease(decReq);

        // Trader should have profit
        uint256 finalBal = usdc.balanceOf(trader);
        assertGt(finalBal, initialTraderBal, "short profit expected");
        
        p = market.getPosition(positionId);
        assertEq(p.size, 0, "position closed");
    }

    // ========== INCREASE EXISTING POSITION TEST ==========
    function testIncreaseExistingPosition() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 size1 = 1_000 * WAD;
        uint256 collateral1 = 200 * 1e6;
        uint256 executionFee = 1 * 1e6;

        // Open long at $2000
        vm.prank(trader);
        uint256 req1 = router.createIncreaseRequest(
            address(market),
            0, // new position
            size1,
            collateral1,
            true,
            2_050 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(req1);

        uint256 positionId = _getPositionIdFromEvent(trader);
        Market.Position memory p = market.getPosition(positionId);
        assertEq(p.size, size1, "initial size");
        assertEq(p.entryPrice, 2_000 * 1e18, "initial entry");

        // Increase long at $2100 (weighted avg should be between 2000 and 2100)
        uint256 size2 = 1_000 * WAD;
        uint256 collateral2 = 200 * 1e6;
        _priceUp(2_100 * 1e8);

        vm.prank(trader);
        uint256 req2 = router.createIncreaseRequest(
            address(market),
            positionId, // existing position
            size2,
            collateral2,
            true,
            2_150 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(req2);

        p = market.getPosition(positionId);
        assertEq(p.size, size1 + size2, "total size");
        // Weighted avg: (2000 * 1000 + 2100 * 1000) / 2000 = 2050
        assertEq(p.entryPrice, 2_050 * 1e18, "weighted avg entry");

        // Price moves to 2200, verify PnL is based on weighted avg
        _priceUp(2_200 * 1e8);
        vm.prank(trader);
        uint256 decReq = router.createDecreaseRequest(
            address(market),
            positionId,
            p.size,
            true,
            2_150 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeDecrease(decReq);

        uint256 bal = usdc.balanceOf(trader);
        assertGt(bal, 10_000 * 1e6, "profit from weighted entry");
    }

    // ========== MULTIPLE POSITIONS: LONG AND SHORT SIMULTANEOUSLY ==========
    function testMultiplePositionsLongAndShort() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 executionFee = 1 * 1e6;

        // Open first long position
        vm.prank(trader);
        uint256 req1 = router.createIncreaseRequest(
            address(market),
            0, // new position
            1_000 * WAD,
            200 * 1e6,
            true, // long
            2_050 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(req1);
        uint256 longPosId = _getPositionIdFromEvent(trader);

        // Open second long position
        vm.prank(trader);
        uint256 req2 = router.createIncreaseRequest(
            address(market),
            0, // new position
            500 * WAD,
            100 * 1e6,
            true, // long
            2_050 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(req2);
        uint256 longPosId2 = _getPositionIdFromEvent(trader);

        // Open short position (should work now!)
        vm.prank(trader);
        uint256 req3 = router.createIncreaseRequest(
            address(market),
            0, // new position
            800 * WAD,
            150 * 1e6,
            false, // short
            1_950 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(req3);
        uint256 shortPosId = _getPositionIdFromEvent(trader);

        // Verify all positions exist
        uint256[] memory positionIds = market.getUserPositionIds(trader);
        assertEq(positionIds.length, 3, "should have 3 positions");

        Market.Position memory long1 = market.getPosition(longPosId);
        Market.Position memory long2 = market.getPosition(longPosId2);
        Market.Position memory short1 = market.getPosition(shortPosId);

        assertEq(long1.size, 1_000 * WAD, "long1 size");
        assertEq(long1.isLong, true, "long1 is long");
        assertEq(long2.size, 500 * WAD, "long2 size");
        assertEq(long2.isLong, true, "long2 is long");
        assertEq(short1.size, 800 * WAD, "short size");
        assertEq(short1.isLong, false, "short is short");

        // Price moves up - longs profit, short loses
        _priceUp(2_200 * 1e8);

        // Close first long (profit)
        vm.prank(trader);
        uint256 decReq1 = router.createDecreaseRequest(
            address(market),
            longPosId,
            long1.size,
            true,
            2_150 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeDecrease(decReq1);

        // Close short (loss)
        // For short decrease: price must be <= acceptablePrice (we want to ensure we don't get worse exit)
        // Current price is 2200, so acceptable should be >= 2200
        vm.prank(trader);
        uint256 decReq2 = router.createDecreaseRequest(
            address(market),
            shortPosId,
            short1.size,
            false,
            2_250 * 1e18, // acceptable max (>= current price 2200)
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeDecrease(decReq2);

        // Verify positions updated
        assertEq(market.getPosition(longPosId).size, 0, "long1 closed");
        assertEq(market.getPosition(shortPosId).size, 0, "short closed");
        assertGt(market.getPosition(longPosId2).size, 0, "long2 still open");

        // Verify position count
        assertEq(market.getUserPositionCount(trader), 1, "should have 1 position left");
    }

    // ========== MULTIPLE LONG POSITIONS TEST ==========
    function testMultipleLongPositions() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 executionFee = 1 * 1e6;
        uint256[] memory positionIds = new uint256[](3);

        // Open 3 separate long positions at different prices
        for (uint256 i = 0; i < 3; i++) {
            _priceUp((2_000 + i * 100) * 1e8); // 2000, 2100, 2200

            vm.prank(trader);
            uint256 reqId = router.createIncreaseRequest(
                address(market),
                0, // new position each time
                1_000 * WAD,
                200 * 1e6,
                true,
                (2_050 + i * 100) * 1e18,
                executionFee
            );
            _advanceBlock();
            vm.prank(keeper);
            pm.executeIncrease(reqId);

            positionIds[i] = _getPositionIdFromEvent(trader);
        }

        // Verify all positions exist
        assertEq(market.getUserPositionCount(trader), 3, "should have 3 positions");

        // Verify each position has different entry price
        assertEq(market.getPosition(positionIds[0]).entryPrice, 2_000 * 1e18, "pos1 entry");
        assertEq(market.getPosition(positionIds[1]).entryPrice, 2_100 * 1e18, "pos2 entry");
        assertEq(market.getPosition(positionIds[2]).entryPrice, 2_200 * 1e18, "pos3 entry");

        // Price moves to 2500 - all longs profit
        _priceUp(2_500 * 1e8);

        // Close positions one by one
        for (uint256 i = 0; i < 3; i++) {
            Market.Position memory p = market.getPosition(positionIds[i]);
            vm.prank(trader);
            uint256 decReq = router.createDecreaseRequest(
                address(market),
                positionIds[i],
                p.size,
                true,
                2_400 * 1e18,
                executionFee
            );
            _advanceBlock();
            vm.prank(keeper);
            pm.executeDecrease(decReq);
        }

        // All positions should be closed
        assertEq(market.getUserPositionCount(trader), 0, "all positions closed");
    }

    // ========== MULTIPLE SHORT POSITIONS TEST ==========
    function testMultipleShortPositions() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 executionFee = 1 * 1e6;
        uint256[] memory positionIds = new uint256[](2);

        // Open 2 short positions
        for (uint256 i = 0; i < 2; i++) {
            _priceUp((2_200 - i * 100) * 1e8); // 2200, 2100

            vm.prank(trader);
            uint256 reqId = router.createIncreaseRequest(
                address(market),
                0, // new position
                1_000 * WAD,
                200 * 1e6,
                false, // short
                (2_150 - i * 100) * 1e18,
                executionFee
            );
            _advanceBlock();
            vm.prank(keeper);
            pm.executeIncrease(reqId);

            positionIds[i] = _getPositionIdFromEvent(trader);
        }

        assertEq(market.getUserPositionCount(trader), 2, "should have 2 positions");

        // Price drops - shorts profit
        _priceUp(1_800 * 1e8);

        // Close both shorts
        for (uint256 i = 0; i < 2; i++) {
            Market.Position memory p = market.getPosition(positionIds[i]);
            vm.prank(trader);
            uint256 decReq = router.createDecreaseRequest(
                address(market),
                positionIds[i],
                p.size,
                false,
                1_850 * 1e18,
                executionFee
            );
            _advanceBlock();
            vm.prank(keeper);
            pm.executeDecrease(decReq);
        }

        assertEq(market.getUserPositionCount(trader), 0, "all positions closed");
    }

    // ========== REAL-LIFE SCENARIO: TRADER WITH MULTIPLE STRATEGIES ==========
    function testRealLifeMultipleStrategies() public {
        // Need more LP liquidity to cover profits and positions
        usdc.mint(lp, 5_000_000 * 1e6); // More LP funds
        vm.prank(lp);
        vault.deposit(5_000_000 * 1e6, lp);

        usdc.mint(trader, 5_000 * 1e6); // More capital
        uint256 executionFee = 1 * 1e6;

        // Scenario: Trader has multiple strategies
        // 1. Long-term bullish position (large size)
        // 2. Short-term scalping long (small size)
        // 3. Hedge short position (medium size)

        // Strategy 1: Long-term bullish at $2000
        vm.prank(trader);
        uint256 req1 = router.createIncreaseRequest(
            address(market),
            0,
            5_000 * WAD, // Large position
            1_000 * 1e6, // High collateral
            true,
            2_050 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(req1);
        uint256 longTermPosId = _getPositionIdFromEvent(trader);

        // Strategy 2: Short-term scalping long at $2100
        _priceUp(2_100 * 1e8);
        vm.prank(trader);
        uint256 req2 = router.createIncreaseRequest(
            address(market),
            0,
            500 * WAD, // Small position
            100 * 1e6,
            true,
            2_150 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(req2);
        uint256 scalpPosId = _getPositionIdFromEvent(trader);

        // Strategy 3: Hedge short at $2200
        _priceUp(2_200 * 1e8);
        vm.prank(trader);
        uint256 req3 = router.createIncreaseRequest(
            address(market),
            0,
            2_000 * WAD, // Medium hedge
            400 * 1e6,
            false,
            2_150 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(req3);
        uint256 hedgePosId = _getPositionIdFromEvent(trader);

        // Verify all positions
        assertEq(market.getUserPositionCount(trader), 3, "3 strategies active");

        // Price moves to $2300
        _priceUp(2_300 * 1e8);

        // Close scalping position (quick profit)
        Market.Position memory scalp = market.getPosition(scalpPosId);
        vm.prank(trader);
        uint256 decReq1 = router.createDecreaseRequest(
            address(market),
            scalpPosId,
            scalp.size,
            true,
            2_250 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeDecrease(decReq1);

        // Increase long-term position (add to winner)
        vm.prank(trader);
        uint256 req4 = router.createIncreaseRequest(
            address(market),
            longTermPosId, // add to existing
            1_000 * WAD,
            200 * 1e6,
            true,
            2_350 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(req4);

        // Close hedge (it's losing money)
        // For short decrease: price must be <= acceptablePrice
        // Current price is 2300, so acceptable must be >= 2300
        Market.Position memory hedge = market.getPosition(hedgePosId);
        vm.prank(trader);
        uint256 decReq2 = router.createDecreaseRequest(
            address(market),
            hedgePosId,
            hedge.size,
            false,
            2_350 * 1e18, // acceptable max (>= current price 2300)
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeDecrease(decReq2);

        // Verify final state
        assertEq(market.getUserPositionCount(trader), 1, "only long-term position left");
        Market.Position memory longTerm = market.getPosition(longTermPosId);
        assertEq(longTerm.size, 6_000 * WAD, "long-term position increased");
        assertGt(longTerm.collateral, 1_000 * 1e6, "collateral increased");
    }

    // ========== POSITION ID SYSTEM TEST ==========
    function testPositionIdSystem() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 executionFee = 1 * 1e6;

        // Create multiple positions
        uint256[] memory createdIds = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(trader);
            uint256 reqId = router.createIncreaseRequest(
                address(market),
                0, // new position
                1_000 * WAD,
                200 * 1e6,
                i % 2 == 0, // alternate long/short
                i % 2 == 0 ? 2_050 * 1e18 : 1_950 * 1e18,
                executionFee
            );
            _advanceBlock();
            vm.prank(keeper);
            pm.executeIncrease(reqId);
            createdIds[i] = _getPositionIdFromEvent(trader);
        }

        // Verify IDs are unique and sequential
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                assertTrue(createdIds[i] != createdIds[j], "IDs must be unique");
            }
        }

        // Verify getUserPositionIds returns all
        uint256[] memory allIds = market.getUserPositionIds(trader);
        assertEq(allIds.length, 3, "should return 3 IDs");

        // Verify getUserPositions
        (uint256[] memory ids, Market.Position[] memory positions) = market.getUserPositions(trader);
        assertEq(ids.length, 3, "should return 3 positions");
        assertEq(positions.length, 3, "should return 3 position structs");

        // Verify ownership
        for (uint256 i = 0; i < 3; i++) {
            assertEq(market.positionOwner(createdIds[i]), trader, "correct owner");
        }
    }

    // ========== SLIPPAGE REVERT TESTS ==========
    function testSlippageRevertLongIncrease() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 sizeUsd = 1_000 * WAD;
        uint256 collateral = 200 * 1e6;
        uint256 executionFee = 1 * 1e6;

        // Trader sets acceptable price at 2050, but oracle is at 2000
        // Price moves to 2100 before execution (slippage)
        _priceUp(2_100 * 1e8);

        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market),
            0, // new position
            sizeUsd,
            collateral,
            true,
            2_050 * 1e18, // acceptable max (but price is 2100)
            executionFee
        );

        _advanceBlock();
        vm.prank(keeper);
        vm.expectRevert("slip long");
        pm.executeIncrease(reqId);
    }

    function testSlippageRevertShortIncrease() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 sizeUsd = 1_000 * WAD;
        uint256 collateral = 200 * 1e6;
        uint256 executionFee = 1 * 1e6;

        // Price drops to 1900 before execution
        _priceUp(1_900 * 1e8);

        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market),
            0, // new position
            sizeUsd,
            collateral,
            false, // short
            1_950 * 1e18, // acceptable min (but price is 1900)
            executionFee
        );

        _advanceBlock();
        vm.prank(keeper);
        vm.expectRevert("slip short");
        pm.executeIncrease(reqId);
    }

    function testSlippageRevertLongDecrease() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 sizeUsd = 1_000 * WAD;
        uint256 collateral = 200 * 1e6;
        uint256 executionFee = 1 * 1e6;

        // Open long
        vm.prank(trader);
        uint256 req1 = router.createIncreaseRequest(
            address(market),
            0, // new position
            sizeUsd,
            collateral,
            true,
            2_050 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(req1);

        uint256 positionId = _getPositionIdFromEvent(trader);

        // Price drops to 1900 (below acceptable for decrease)
        _priceUp(1_900 * 1e8);

        vm.prank(trader);
        uint256 decReq = router.createDecreaseRequest(
            address(market),
            positionId,
            sizeUsd,
            true,
            1_950 * 1e18, // acceptable min (but price is 1900)
            executionFee
        );

        _advanceBlock();
        vm.prank(keeper);
        vm.expectRevert("slip long dec");
        pm.executeDecrease(decReq);
    }

    function testSlippageRevertShortDecrease() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 sizeUsd = 1_000 * WAD;
        uint256 collateral = 200 * 1e6;
        uint256 executionFee = 1 * 1e6;

        // Open short
        vm.prank(trader);
        uint256 req1 = router.createIncreaseRequest(
            address(market),
            0, // new position
            sizeUsd,
            collateral,
            false,
            1_950 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(req1);

        uint256 positionId = _getPositionIdFromEvent(trader);

        // Price rises to 2100 (above acceptable for decrease)
        _priceUp(2_100 * 1e8);

        vm.prank(trader);
        uint256 decReq = router.createDecreaseRequest(
            address(market),
            positionId,
            sizeUsd,
            false,
            2_050 * 1e18, // acceptable max (but price is 2100)
            executionFee
        );

        _advanceBlock();
        vm.prank(keeper);
        vm.expectRevert("slip short dec");
        pm.executeDecrease(decReq);
    }

    // ========== OI CAP EXCEED TEST ==========
    function testOICapExceed() public {
        // Mint more USDC for LP
        usdc.mint(lp, 10_000_000 * 1e6);
        vm.prank(lp);
        vault.deposit(10_000_000 * 1e6, lp);

        // Set small OI cap (test contract is owner via factory)
        market.setMaxOI(5_000 * WAD, 5_000 * WAD);

        uint256 sizeUsd = 6_000 * WAD; // exceeds cap
        uint256 collateral = 1_000 * 1e6;
        uint256 executionFee = 1 * 1e6;

        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market),
            0, // new position
            sizeUsd,
            collateral,
            true,
            2_050 * 1e18,
            executionFee
        );

        _advanceBlock();
        vm.prank(keeper);
        vm.expectRevert("oi long cap");
        pm.executeIncrease(reqId);
    }

    // ========== FEE ASSERTION TESTS ==========
    function testFeesCreditedToVault() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 sizeUsd = 1_000 * WAD;
        uint256 collateral = 200 * 1e6;
        uint256 executionFee = 1 * 1e6;

        uint256 vaultBalBefore = vault.totalAssets();
        uint256 rawBalBefore = usdc.balanceOf(address(vault));

        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market),
            0, // new position
            sizeUsd,
            collateral,
            true,
            2_050 * 1e18,
            executionFee
        );

        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(reqId);

        uint256 positionId = _getPositionIdFromEvent(trader);

        uint256 rawBalAfter = usdc.balanceOf(address(vault));
        // The vault's raw balance grows by the full collateral, but that money is not
        // LP equity: only the 0.1% open fee is. The rest is the trader's, reserved
        // until they close, and must be excluded from totalAssets() - otherwise LPs
        // can redeem against collateral they do not own.
        uint256 openFee = (sizeUsd * market.FEE_BPS()) / market.BPS_DIV() / 1e12;
        assertEq(rawBalAfter, rawBalBefore + collateral, "full collateral sits in the vault");
        assertEq(vault.reservedAssets(), collateral - openFee, "trader collateral is reserved");
        assertEq(vault.totalAssets(), vaultBalBefore + openFee, "LP equity grows only by the fee");

        // Close position and check fee again
        _priceUp(2_200 * 1e8);
        uint256 traderBalBeforeClose = usdc.balanceOf(trader);

        vm.prank(trader);
        uint256 decReq = router.createDecreaseRequest(
            address(market),
            positionId,
            sizeUsd,
            true,
            2_150 * 1e18,
            executionFee
        );

        _advanceBlock();
        vm.prank(keeper);
        pm.executeDecrease(decReq);

        uint256 traderBalAfterClose = usdc.balanceOf(trader);
        assertGt(traderBalAfterClose, traderBalBeforeClose - 202 * 1e6, "user got some return");
    }

    // ========== FUNDING EFFECT TEST ==========
    function testFundingEffect() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        address trader2 = address(0x4);
        usdc.mint(trader2, 10_000 * 1e6);
        vm.prank(trader2);
        usdc.approve(address(router), type(uint256).max);

        uint256 sizeUsd = 2_000 * WAD;
        uint256 collateral = 400 * 1e6;
        uint256 executionFee = 1 * 1e6;

        // Open long (trader)
        vm.prank(trader);
        uint256 req1 = router.createIncreaseRequest(
            address(market),
            0, // new position
            sizeUsd,
            collateral,
            true,
            2_050 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(req1);
        uint256 longPosId = _getPositionIdFromEvent(trader);

        // Open short (trader2) - creates imbalance (long > short)
        vm.prank(trader2);
        uint256 req2 = router.createIncreaseRequest(
            address(market),
            0, // new position
            sizeUsd / 2, // 1000 USD short
            collateral / 2,
            false,
            1_950 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(req2);

        // Advance time to accumulate funding
        vm.warp(block.timestamp + 3600); // 1 hour

        // Get funding snapshot before
        int256 fundingBefore = market.cumulativeFundingLong();

        // Trigger funding update by executing a decrease
        _priceUp(2_100 * 1e8);
        vm.prank(trader);
        uint256 decReq = router.createDecreaseRequest(
            address(market),
            longPosId,
            sizeUsd / 2,
            true,
            2_050 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeDecrease(decReq);

        // Funding should have increased (longs pay shorts)
        int256 fundingAfter = market.cumulativeFundingLong();
        assertGt(fundingAfter, fundingBefore, "funding accumulated");
    }

    // ========== LIQUIDATION HEALTHY VS UNHEALTHY ==========
    function testLiquidationHealthy() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 sizeUsd = 1_000 * WAD;
        uint256 collateral = 500 * 1e6; // Large collateral (healthy)
        uint256 executionFee = 1 * 1e6;

        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market),
            0, // new position
            sizeUsd,
            collateral,
            true,
            2_050 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(reqId);

        uint256 positionId = _getPositionIdFromEvent(trader);

        // Price drops slightly (still healthy)
        _priceUp(1_900 * 1e8);

        vm.prank(keeper);
        vm.expectRevert("healthy");
        pm.liquidate(address(market), positionId);
    }

    function testLiquidationUnhealthy() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 sizeUsd = 5_000 * WAD;
        uint256 collateral = 600 * 1e6; // C3: 10x cap (was 200, still liquidatable on crash)
        uint256 executionFee = 1 * 1e6;

        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market),
            0, // new position
            sizeUsd,
            collateral,
            true,
            2_100 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(reqId);

        uint256 positionId = _getPositionIdFromEvent(trader);

        // Price crashes (unhealthy)
        _priceUp(1_000 * 1e8);

        vm.prank(keeper);
        pm.liquidate(address(market), positionId);

        Market.Position memory p = market.getPosition(positionId);
        assertEq(p.size, 0, "position liquidated");
        assertEq(p.collateral, 0, "collateral seized");
    }

    // ========== LIQUIDATE ONE POSITION, OTHERS REMAIN ==========
    function testLiquidateOnePositionOthersRemain() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 executionFee = 1 * 1e6;

        // Create 2 positions
        vm.prank(trader);
        uint256 req1 = router.createIncreaseRequest(
            address(market),
            0,
            5_000 * WAD, // Large, risky
            600 * 1e6, // C3: 10x cap (still liquidatable on crash)
            true,
            2_100 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(req1);
        uint256 riskyPosId = _getPositionIdFromEvent(trader);

        vm.prank(trader);
        uint256 req2 = router.createIncreaseRequest(
            address(market),
            0,
            1_000 * WAD, // Small, safe
            500 * 1e6, // High collateral
            true,
            2_050 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(req2);
        uint256 safePosId = _getPositionIdFromEvent(trader);

        assertEq(market.getUserPositionCount(trader), 2, "should have 2 positions");

        // Price crashes - only risky position becomes unhealthy
        _priceUp(1_000 * 1e8);

        // Liquidate only risky position
        vm.prank(keeper);
        pm.liquidate(address(market), riskyPosId);

        // Verify risky position is liquidated
        assertEq(market.getPosition(riskyPosId).size, 0, "risky position liquidated");

        // Verify safe position still exists
        Market.Position memory safe = market.getPosition(safePosId);
        assertGt(safe.size, 0, "safe position remains");
        assertEq(market.getUserPositionCount(trader), 1, "should have 1 position left");
    }

    // ========== FULL WIPE-OUT TEST ==========
    function testFullWipeOut() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 sizeUsd = 5_000 * WAD;
        uint256 collateral = 600 * 1e6; // C3: 10x cap (was 100, full wipeout still occurs on 75% crash)
        uint256 executionFee = 1 * 1e6;

        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market),
            0, // new position
            sizeUsd,
            collateral,
            true,
            2_100 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(reqId);

        uint256 positionId = _getPositionIdFromEvent(trader);

        // Price crashes hard (total loss)
        _priceUp(500 * 1e8); // 75% drop

        // Close position
        vm.prank(trader);
        uint256 decReq = router.createDecreaseRequest(
            address(market),
            positionId,
            sizeUsd,
            true,
            500 * 1e18,
            executionFee
        );

        uint256 balBeforeClose = usdc.balanceOf(trader);
        _advanceBlock();
        vm.prank(keeper);
        pm.executeDecrease(decReq);

        uint256 balAfterClose = usdc.balanceOf(trader);
        assertLe(balAfterClose, balBeforeClose, "no return on wipeout");
        assertEq(market.getPosition(positionId).size, 0, "position closed");
    }

    // ========== EXECUTION FEE FLOW TEST ==========
    function testExecutionFeeFlow() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 sizeUsd = 1_000 * WAD;
        uint256 collateral = 200 * 1e6;
        uint256 executionFee = 10 * 1e6; // Larger fee for visibility

        uint256 keeperBalBefore = usdc.balanceOf(keeper);

        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market),
            0, // new position
            sizeUsd,
            collateral,
            true,
            2_050 * 1e18,
            executionFee
        );

        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(reqId);

        uint256 positionId = _getPositionIdFromEvent(trader);

        uint256 keeperBalAfter = usdc.balanceOf(keeper);
        assertEq(keeperBalAfter, keeperBalBefore + executionFee, "keeper got fee");

        // Test decrease fee
        _priceUp(2_200 * 1e8);
        keeperBalBefore = usdc.balanceOf(keeper);

        vm.prank(trader);
        uint256 decReq = router.createDecreaseRequest(
            address(market),
            positionId,
            sizeUsd,
            true,
            2_150 * 1e18,
            executionFee
        );

        _advanceBlock();
        vm.prank(keeper);
        pm.executeDecrease(decReq);

        keeperBalAfter = usdc.balanceOf(keeper);
        assertEq(keeperBalAfter, keeperBalBefore + executionFee, "keeper got close fee");
    }

    // ========== POSITION GETTER VERIFICATION ==========
    function testPositionGetters() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 sizeUsd = 1_000 * WAD;
        uint256 collateral = 200 * 1e6;
        uint256 executionFee = 1 * 1e6;

        // Before position
        assertEq(market.getUserPositionCount(trader), 0, "no positions initially");

        // Open position
        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market),
            0, // new position
            sizeUsd,
            collateral,
            true,
            2_050 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(reqId);

        uint256 positionId = _getPositionIdFromEvent(trader);
        Market.Position memory p = market.getPosition(positionId);
        assertEq(p.size, sizeUsd, "size set");
        assertEq(p.isLong, true, "isLong set");
        assertEq(p.entryPrice, 2_000 * 1e18, "entryPrice set");
        assertGt(p.collateral, 0, "collateral set");

        // Verify getUserPositionIds
        uint256[] memory ids = market.getUserPositionIds(trader);
        assertEq(ids.length, 1, "should have 1 position ID");
        assertEq(ids[0], positionId, "correct position ID");

        // Partial close
        vm.prank(trader);
        uint256 decReq = router.createDecreaseRequest(
            address(market),
            positionId,
            sizeUsd / 2,
            true,
            2_000 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeDecrease(decReq);

        p = market.getPosition(positionId);
        assertEq(p.size, sizeUsd / 2, "size reduced");
        assertGt(p.collateral, 0, "collateral remains");

        // Full close
        vm.prank(trader);
        decReq = router.createDecreaseRequest(
            address(market),
            positionId,
            sizeUsd / 2,
            true,
            2_000 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeDecrease(decReq);

        p = market.getPosition(positionId);
        assertEq(p.size, 0, "position cleared");
        assertEq(p.collateral, 0, "collateral cleared");
        assertEq(market.getUserPositionCount(trader), 0, "no positions after close");
    }

    // ========== VAULT SOLVENCY GUARD TEST ==========
    function testVaultSolvencyGuard() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 sizeUsd = 5_000 * WAD;
        uint256 collateral = 600 * 1e6; // C3: 10x cap
        uint256 executionFee = 1 * 1e6;

        // Open profitable long position
        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(
            address(market),
            0, // new position
            sizeUsd,
            collateral,
            true,
            2_050 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(reqId);

        // Price moves up significantly (trader has large unrealized profit)
        _priceUp(3_000 * 1e8); // 50% profit

        // Calculate unrealized profits
        uint256 unrealized = market.unrealizedProfits();
        uint256 vaultBalance = vault.totalAssets();
        
        // LP tries to withdraw - should check solvency
        uint256 lpShares = vault.balanceOf(lp);
        
        // Try to withdraw amount that would breach solvency
        if (lpShares > 0 && unrealized > 0) {
            // Calculate max safe withdrawal
            uint256 maxSafeWithdrawal = vaultBalance > unrealized ? vaultBalance - unrealized : 0;
            uint256 maxSafeShares = maxSafeWithdrawal > 0 ? (maxSafeWithdrawal * lpShares) / vaultBalance : 0;
            
            // Try withdrawing more than safe amount (should revert)
            if (maxSafeShares < lpShares) {
                uint256 unsafeShares = maxSafeShares + (lpShares - maxSafeShares) / 2;
                vm.prank(lp);
                vm.expectRevert(); // Should revert with InsufficientLiquidity
                vault.withdraw(unsafeShares, lp);
            }
            
            // Small withdrawal should work
            if (maxSafeShares > 0) {
                uint256 safeShares = maxSafeShares / 10; // 10% of safe amount
                if (safeShares > 0) {
                    vm.prank(lp);
                    vault.withdraw(safeShares, lp); // Should succeed
                }
            }
        }
    }

    // ========== ERROR CASES: INVALID POSITION ID ==========
    function testInvalidPositionId() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 executionFee = 1 * 1e6;

        // Try to decrease non-existent position
        vm.prank(trader);
        uint256 decReq = router.createDecreaseRequest(
            address(market),
            999, // invalid positionId
            1_000 * WAD,
            true,
            2_000 * 1e18,
            executionFee
        );

        _advanceBlock();
        vm.prank(keeper);
        vm.expectRevert("not owner");
        pm.executeDecrease(decReq);
    }

    function testWrongPositionOwner() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        address trader2 = address(0x5);
        usdc.mint(trader2, 10_000 * 1e6);
        vm.prank(trader2);
        usdc.approve(address(router), type(uint256).max);

        uint256 executionFee = 1 * 1e6;

        // Trader creates position
        vm.prank(trader);
        uint256 req1 = router.createIncreaseRequest(
            address(market),
            0,
            1_000 * WAD,
            200 * 1e6,
            true,
            2_050 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(req1);
        uint256 traderPosId = _getPositionIdFromEvent(trader);

        // Trader2 tries to decrease trader's position
        vm.prank(trader2);
        uint256 decReq = router.createDecreaseRequest(
            address(market),
            traderPosId, // wrong owner
            500 * WAD,
            true,
            2_000 * 1e18,
            executionFee
        );

        _advanceBlock();
        vm.prank(keeper);
        vm.expectRevert("not owner");
        pm.executeDecrease(decReq);
    }

    function testSideMismatchOnIncrease() public {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        uint256 executionFee = 1 * 1e6;

        // Create long position
        vm.prank(trader);
        uint256 req1 = router.createIncreaseRequest(
            address(market),
            0,
            1_000 * WAD,
            200 * 1e6,
            true, // long
            2_050 * 1e18,
            executionFee
        );
        _advanceBlock();
        vm.prank(keeper);
        pm.executeIncrease(req1);
        uint256 longPosId = _getPositionIdFromEvent(trader);

        // Try to add short to long position
        vm.prank(trader);
        uint256 req2 = router.createIncreaseRequest(
            address(market),
            longPosId, // existing long position
            500 * WAD,
            100 * 1e6,
            false, // short - mismatch!
            1_950 * 1e18,
            executionFee
        );

        _advanceBlock();
        vm.prank(keeper);
        vm.expectRevert("side mismatch");
        pm.executeIncrease(req2);
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
