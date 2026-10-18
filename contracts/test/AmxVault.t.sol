// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {AmxVault} from "../src/AmxVault.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AmxUpgradeableDeploy} from "../script/lib/AmxUpgradeableDeploy.sol";

/// @dev Attempts to re-enter release() from within its own receive(), and separately supports
/// simply refusing to accept AMX, to exercise both the reentrancy guard and the "payout revert
/// rolls back everything atomically" behavior.
contract MaliciousReceiver {
    AmxVault public vault;
    bytes32 public reentryDepositId;
    address public reentryTo;
    uint256 public reentryAmount;
    bool public shouldReenter;
    bool public shouldReject;

    function configure(AmxVault _vault, bytes32 _depositId, address _to, uint256 _amount, bool _reenter) external {
        vault = _vault;
        reentryDepositId = _depositId;
        reentryTo = _to;
        reentryAmount = _amount;
        shouldReenter = _reenter;
    }

    function setShouldReject(bool _reject) external {
        shouldReject = _reject;
    }

    receive() external payable {
        if (shouldReject) {
            revert("MaliciousReceiver: rejecting AMX");
        }
        if (shouldReenter) {
            shouldReenter = false; // avoid infinite recursion in the test itself
            vault.release(reentryDepositId, reentryTo, reentryAmount);
        }
    }
}

contract AmxVaultTest is Test {
    AmxVault public vault;

    address public admin = makeAddr("admin");
    address public pauser = makeAddr("pauser");
    address public executor = makeAddr("executor");
    address public recovery = makeAddr("recovery");
    address public buyer = makeAddr("buyer");
    address public stranger = makeAddr("stranger");
    address public upgradeAdmin = makeAddr("upgradeAdmin");

    /// @dev Shared implementation for the initialize-revert tests, so the only call they make is
    /// the proxy creation that is expected to revert.
    AmxVault public impl;

    uint256 public constant MAX_TX = 100 ether;
    uint256 public constant MAX_DAY = 500 ether;
    uint256 public constant FUND_AMOUNT = 1_000 ether;

    event Released(bytes32 indexed depositId, address indexed to, uint256 amount);
    event ToppedUp(address indexed from, uint256 amount);
    event CapsUpdated(uint256 maxReleasePerTx, uint256 maxReleasePerDay);
    event EmergencyRecovered(address indexed to, uint256 amount);

    function setUp() public {
        (vault,) = AmxUpgradeableDeploy.deployVault(
            AmxUpgradeableDeploy.VaultConfig(admin, pauser, executor, MAX_TX, MAX_DAY, recovery, address(0)), upgradeAdmin
        );
        impl = new AmxVault();
        vm.deal(address(this), FUND_AMOUNT);
        (bool ok,) = address(vault).call{value: FUND_AMOUNT}("");
        require(ok, "funding failed");
    }

    /// @dev Deploys a vault proxy initialised with the given config, in a single external call.
    function _deploy(address a, address p, address e, uint256 maxTx, uint256 maxDay, address r)
        internal
        returns (AmxVault)
    {
        bytes memory init = abi.encodeCall(AmxVault.initialize, (a, p, e, maxTx, maxDay, r, address(0)));
        return AmxVault(payable(address(new TransparentUpgradeableProxy(address(impl), upgradeAdmin, init))));
    }

    // ==========================================
    //              INITIALIZE
    // ==========================================

    function test_InitializeSetsRolesAndConfig() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), pauser));
        assertTrue(vault.hasRole(vault.EXECUTOR_ROLE(), executor));
        assertEq(vault.maxReleasePerTx(), MAX_TX);
        assertEq(vault.maxReleasePerDay(), MAX_DAY);
        assertEq(vault.treasuryRecoveryAddress(), recovery);
        assertEq(vault.legacyVault(), address(0));
    }

    function test_InitializeRevertsOnZeroAdmin() public {
        vm.expectRevert("invalid admin");
        _deploy(address(0), pauser, executor, MAX_TX, MAX_DAY, recovery);
    }

    function test_InitializeRevertsOnZeroPauser() public {
        vm.expectRevert("invalid pauser");
        _deploy(admin, address(0), executor, MAX_TX, MAX_DAY, recovery);
    }

    function test_InitializeRevertsOnZeroExecutor() public {
        vm.expectRevert("invalid executor");
        _deploy(admin, pauser, address(0), MAX_TX, MAX_DAY, recovery);
    }

    function test_InitializeRevertsOnZeroRecovery() public {
        vm.expectRevert("invalid recovery address");
        _deploy(admin, pauser, executor, MAX_TX, MAX_DAY, address(0));
    }

    function test_InitializeRevertsOnInvalidCaps() public {
        vm.expectRevert("invalid caps");
        _deploy(admin, pauser, executor, 0, MAX_DAY, recovery);

        vm.expectRevert("invalid caps");
        _deploy(admin, pauser, executor, MAX_DAY + 1, MAX_DAY, recovery);
    }

    // ==========================================
    //           RECEIVE / TOP-UP
    // ==========================================

    function test_ReceiveEmitsToppedUp() public {
        vm.deal(stranger, 1 ether);
        vm.expectEmit(true, false, false, true);
        emit ToppedUp(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        require(ok);
    }

    // ==========================================
    //         AUTHORIZATION BOUNDARIES
    // ==========================================

    function test_RevertWhen_NonExecutorReleases() public {
        vm.prank(stranger);
        vm.expectRevert();
        vault.release(bytes32("d1"), buyer, 1 ether);
    }

    function test_RevertWhen_NonPauserPauses() public {
        vm.prank(stranger);
        vm.expectRevert();
        vault.pause();
    }

    function test_RevertWhen_NonAdminUnpauses() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(stranger);
        vm.expectRevert();
        vault.unpause();
    }

    function test_RevertWhen_NonAdminSetsCaps() public {
        vm.prank(stranger);
        vm.expectRevert();
        vault.setCaps(1 ether, 10 ether);
    }

    function test_RevertWhen_NonAdminSetsRecoveryAddress() public {
        vm.prank(stranger);
        vm.expectRevert();
        vault.setRecoveryAddress(stranger);
    }

    function test_RevertWhen_NonAdminEmergencyRecovers() public {
        vm.prank(stranger);
        vm.expectRevert();
        vault.emergencyRecoverAll();
    }

    function test_RevertWhen_NonAdminGrantsRole() public {
        bytes32 role = vault.EXECUTOR_ROLE(); // read before pranking: this is itself an external call
        vm.prank(stranger);
        vm.expectRevert();
        vault.grantRole(role, stranger);
    }

    function test_AdminCanRotateExecutor() public {
        address newExecutor = makeAddr("newExecutor");
        vm.startPrank(admin);
        vault.grantRole(vault.EXECUTOR_ROLE(), newExecutor);
        vault.revokeRole(vault.EXECUTOR_ROLE(), executor);
        vm.stopPrank();

        assertFalse(vault.hasRole(vault.EXECUTOR_ROLE(), executor));
        assertTrue(vault.hasRole(vault.EXECUTOR_ROLE(), newExecutor));

        vm.prank(newExecutor);
        vault.release(bytes32("rot1"), buyer, 1 ether);
        assertEq(buyer.balance, 1 ether);
    }

    function test_AdminRoleCanBeTransferred() public {
        address newAdmin = makeAddr("newAdmin");
        vm.startPrank(admin);
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), newAdmin);
        vault.revokeRole(vault.DEFAULT_ADMIN_ROLE(), admin);
        vm.stopPrank();

        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), newAdmin));

        vm.prank(admin);
        vm.expectRevert();
        vault.setCaps(1 ether, 10 ether);

        vm.prank(newAdmin);
        vault.setCaps(1 ether, 10 ether);
        assertEq(vault.maxReleasePerTx(), 1 ether);
    }

    // ==========================================
    //              RELEASE / NULLIFIER
    // ==========================================

    function test_ReleaseTransfersFundsAndEmits() public {
        bytes32 depositId = bytes32("d1");
        vm.expectEmit(true, true, false, true);
        emit Released(depositId, buyer, 1 ether);

        vm.prank(executor);
        vault.release(depositId, buyer, 1 ether);

        assertEq(buyer.balance, 1 ether);
        assertTrue(vault.released(depositId));
    }

    function test_RevertWhen_DepositIdReleasedTwice() public {
        bytes32 depositId = bytes32("d1");
        vm.startPrank(executor);
        vault.release(depositId, buyer, 1 ether);

        vm.expectRevert("already released");
        vault.release(depositId, buyer, 1 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_ReleaseToZeroAddress() public {
        vm.prank(executor);
        vm.expectRevert("invalid recipient");
        vault.release(bytes32("d1"), address(0), 1 ether);
    }

    function test_RevertWhen_ReleaseZeroAmount() public {
        vm.prank(executor);
        vm.expectRevert("exceeds per-tx cap");
        vault.release(bytes32("d1"), buyer, 0);
    }

    function test_RevertWhen_InsufficientVaultBalance() public {
        vm.startPrank(admin);
        vault.setCaps(FUND_AMOUNT + 10 ether, FUND_AMOUNT + 10 ether);
        vm.stopPrank();

        vm.prank(executor);
        vm.expectRevert("insufficient balance");
        vault.release(bytes32("d1"), buyer, FUND_AMOUNT + 1 ether);
    }

    // ==========================================
    //                  CAPS
    // ==========================================

    function test_ReleaseAtExactPerTxCapSucceeds() public {
        vm.prank(executor);
        vault.release(bytes32("d1"), buyer, MAX_TX);
        assertEq(buyer.balance, MAX_TX);
    }

    function test_RevertWhen_ReleaseExceedsPerTxCap() public {
        vm.prank(executor);
        vm.expectRevert("exceeds per-tx cap");
        vault.release(bytes32("d1"), buyer, MAX_TX + 1);
    }

    function test_DailyCapAccumulatesAcrossReleases() public {
        vm.startPrank(executor);
        vault.release(bytes32("d1"), buyer, MAX_TX);
        vault.release(bytes32("d2"), buyer, MAX_TX);
        vault.release(bytes32("d3"), buyer, MAX_TX);
        vault.release(bytes32("d4"), buyer, MAX_TX);
        vault.release(bytes32("d5"), buyer, MAX_TX); // exactly MAX_DAY (5 * 100 = 500)
        vm.stopPrank();
        assertEq(buyer.balance, MAX_DAY);
    }

    function test_RevertWhen_DailyCapExceeded() public {
        vm.startPrank(executor);
        for (uint256 i = 0; i < 5; i++) {
            vault.release(keccak256(abi.encodePacked("d", i)), buyer, MAX_TX);
        }
        vm.expectRevert("exceeds daily cap");
        vault.release(bytes32("d6"), buyer, 1 ether);
        vm.stopPrank();
    }

    function test_DailyCapResetsOnNewDay() public {
        vm.startPrank(executor);
        for (uint256 i = 0; i < 5; i++) {
            vault.release(keccak256(abi.encodePacked("d", i)), buyer, MAX_TX);
        }
        vm.expectRevert("exceeds daily cap");
        vault.release(bytes32("blocked"), buyer, 1 ether);

        vm.warp(block.timestamp + 1 days);
        vault.release(bytes32("nextday"), buyer, MAX_TX); // succeeds again, fresh bucket
        vm.stopPrank();

        assertEq(buyer.balance, MAX_DAY + MAX_TX);
    }

    // NOTE: known/accepted tradeoff — releasedInDay uses a fixed UTC calendar-day bucket, not a
    // true sliding window. A release right before a day boundary and another right after can
    // together exceed maxReleasePerDay within a short real-world window. Documented here rather
    // than hidden; the cap's job is to bound catastrophic loss, not act as a precise rate limiter.
    function test_CalendarDayBoundaryCanDoubleUpNearMidnight() public {
        uint256 currentDay = block.timestamp / 1 days;
        uint256 nextDayBoundary = (currentDay + 1) * 1 days;
        uint256 releasesPerDay = MAX_DAY / MAX_TX;

        vm.warp(nextDayBoundary - 1); // last second of "today"
        vm.startPrank(executor);
        for (uint256 i = 0; i < releasesPerDay; i++) {
            vault.release(keccak256(abi.encodePacked("boundary1-", i)), buyer, MAX_TX);
        }
        vm.stopPrank();

        vm.warp(nextDayBoundary); // first second of "tomorrow", 1 second later
        vm.startPrank(executor);
        for (uint256 i = 0; i < releasesPerDay; i++) {
            vault.release(keccak256(abi.encodePacked("boundary2-", i)), buyer, MAX_TX); // fresh bucket, succeeds again
        }
        vm.stopPrank();

        // ~2x the daily cap released within a 1-second real-world window: accepted tradeoff.
        assertEq(buyer.balance, MAX_DAY * 2);
    }

    // ==========================================
    //                 PAUSE
    // ==========================================

    function test_PauseBlocksRelease() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(executor);
        vm.expectRevert();
        vault.release(bytes32("d1"), buyer, 1 ether);
    }

    function test_PauserCannotUnpause() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(pauser);
        vm.expectRevert();
        vault.unpause();
    }

    function test_AdminUnpauseRestoresRelease() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(admin);
        vault.unpause();

        vm.prank(executor);
        vault.release(bytes32("d1"), buyer, 1 ether);
        assertEq(buyer.balance, 1 ether);
    }

    // ==========================================
    //               REENTRANCY
    // ==========================================

    function test_RevertWhen_MaliciousReceiverReenters() public {
        MaliciousReceiver evil = new MaliciousReceiver();
        evil.configure(vault, bytes32("evil-reentry"), address(evil), 1 ether, true);

        vm.prank(executor);
        vm.expectRevert();
        vault.release(bytes32("evil-initial"), address(evil), 1 ether);

        // Nothing should have moved: the whole tx reverts atomically.
        assertFalse(vault.released(bytes32("evil-initial")));
        assertFalse(vault.released(bytes32("evil-reentry")));
        assertEq(address(evil).balance, 0);
    }

    function test_RevertWhen_RecipientRejectsPayment() public {
        MaliciousReceiver rejecter = new MaliciousReceiver();
        rejecter.setShouldReject(true);

        vm.prank(executor);
        vm.expectRevert("transfer failed");
        vault.release(bytes32("d1"), address(rejecter), 1 ether);

        // Reverted atomically: nullifier was NOT left set despite being flipped before the call.
        assertFalse(vault.released(bytes32("d1")));
    }

    // ==========================================
    //          EMERGENCY RECOVERY
    // ==========================================

    function test_EmergencyRecoverAllSweepsToRecoveryAddress() public {
        uint256 vaultBalanceBefore = address(vault).balance;
        vm.expectEmit(true, false, false, true);
        emit EmergencyRecovered(recovery, vaultBalanceBefore);

        vm.prank(admin);
        vault.emergencyRecoverAll();

        assertEq(recovery.balance, vaultBalanceBefore);
        assertEq(address(vault).balance, 0);
    }

    function test_RevertWhen_EmergencyRecoverWithZeroBalance() public {
        vm.prank(admin);
        vault.emergencyRecoverAll(); // drains it once

        vm.prank(admin);
        vm.expectRevert("nothing to recover");
        vault.emergencyRecoverAll();
    }

    function test_EmergencyRecoverWorksWhilePaused() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(admin);
        vault.emergencyRecoverAll();
        assertEq(address(vault).balance, 0);
    }

    function test_SetRecoveryAddressChangesDestination() public {
        address newRecovery = makeAddr("newRecovery");
        vm.prank(admin);
        vault.setRecoveryAddress(newRecovery);

        vm.prank(admin);
        vault.emergencyRecoverAll();

        assertEq(newRecovery.balance, FUND_AMOUNT);
        assertEq(recovery.balance, 0);
    }
}
