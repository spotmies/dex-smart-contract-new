// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {AmxVaultTestERC20} from "../src/AmxVaultTestERC20.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {AmxUpgradeableDeploy} from "../script/lib/AmxUpgradeableDeploy.sol";

/// @dev Smoke-tests the ERC20-specific wiring (topUp, balance tracking, ERC20 payout) plus a
/// couple of the shared guards, to confirm the AmxVaultBase logic is correctly inherited through
/// this subclass. Full coverage of the shared release()/caps/pause/recovery logic itself lives
/// in AmxVault.t.sol — both contracts share the exact same base implementation.
contract AmxVaultTestERC20Test is Test {
    AmxVaultTestERC20 public vault;
    MockERC20 public token;

    address public admin = makeAddr("admin");
    address public pauser = makeAddr("pauser");
    address public executor = makeAddr("executor");
    address public recovery = makeAddr("recovery");
    address public buyer = makeAddr("buyer");
    address public funder = makeAddr("funder");

    uint256 public constant MAX_TX = 100 ether;
    uint256 public constant MAX_DAY = 500 ether;
    uint256 public constant FUND_AMOUNT = 1_000 ether;

    function setUp() public {
        token = new MockERC20("Test AMX", "tAMX");
        (vault,) = AmxUpgradeableDeploy.deployTestVault(
            AmxUpgradeableDeploy.VaultConfig(admin, pauser, executor, MAX_TX, MAX_DAY, recovery, address(0)),
            address(token),
            makeAddr("upgradeAdmin")
        );

        token.mint(funder, FUND_AMOUNT);
        vm.prank(funder);
        token.approve(address(vault), FUND_AMOUNT);
        vm.prank(funder);
        vault.topUp(FUND_AMOUNT);
    }

    function test_TopUpIncreasesVaultBalance() public view {
        assertEq(token.balanceOf(address(vault)), FUND_AMOUNT);
    }

    function test_ReleasePaysOutInTestToken() public {
        vm.prank(executor);
        vault.release(bytes32("d1"), buyer, 10 ether);
        assertEq(token.balanceOf(buyer), 10 ether);
        assertEq(token.balanceOf(address(vault)), FUND_AMOUNT - 10 ether);
    }

    function test_RevertWhen_DepositIdReleasedTwice() public {
        vm.startPrank(executor);
        vault.release(bytes32("d1"), buyer, 10 ether);
        vm.expectRevert("already released");
        vault.release(bytes32("d1"), buyer, 10 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_NonExecutorReleases() public {
        vm.expectRevert();
        vault.release(bytes32("d1"), buyer, 10 ether);
    }

    function test_EmergencyRecoverAllSweepsTestTokenToRecoveryAddress() public {
        vm.prank(admin);
        vault.emergencyRecoverAll();
        assertEq(token.balanceOf(recovery), FUND_AMOUNT);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_PauseBlocksRelease() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(executor);
        vm.expectRevert();
        vault.release(bytes32("d1"), buyer, 10 ether);
    }
}
