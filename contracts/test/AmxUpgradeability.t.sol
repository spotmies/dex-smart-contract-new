// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {AmxVault} from "../src/AmxVault.sol";
import {AmxSale} from "../src/AmxSale.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {AmxUpgradeableDeploy} from "../script/lib/AmxUpgradeableDeploy.sol";
import {AmxVaultV1} from "./legacy/AmxVaultV1.sol";
import {MockAggregatorV3} from "./AmxSale.t.sol";

/// @dev Stand-in "next version" of each contract: same storage, one extra function.
contract AmxVaultV2Mock is AmxVault {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract AmxSaleV2Mock is AmxSale {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice Proves the AMX contracts are safely upgradeable, and that the cutover from the live,
/// non-upgradeable vault (AmxVaultV1, a verbatim copy) cannot pay any purchase twice.
contract AmxUpgradeabilityTest is Test {
    address admin = makeAddr("admin");
    address pauser = makeAddr("pauser");
    address executor = makeAddr("executor");
    address recovery = makeAddr("recovery");
    address buyer = makeAddr("buyer");
    address upgradeAdmin = makeAddr("upgradeAdmin");

    uint256 constant MAX_TX = 100 ether;
    uint256 constant MAX_DAY = 500 ether;

    function _vaultConfig(address legacy) internal view returns (AmxUpgradeableDeploy.VaultConfig memory) {
        return AmxUpgradeableDeploy.VaultConfig(admin, pauser, executor, MAX_TX, MAX_DAY, recovery, legacy);
    }

    function _deployVault(address legacy) internal returns (AmxVault vault) {
        (vault,) = AmxUpgradeableDeploy.deployVault(_vaultConfig(legacy), upgradeAdmin);
    }

    function _proxyAdmin(address proxy) internal view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(proxy, AmxUpgradeableDeploy.ADMIN_SLOT)))));
    }

    function _fund(address vault, uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = vault.call{value: amount}("");
        require(ok, "fund failed");
    }

    // ==========================================
    //          INITIALISATION GUARDS
    // ==========================================

    function test_VaultImplementationCannotBeInitialised() public {
        (, address impl) = AmxUpgradeableDeploy.deployVault(_vaultConfig(address(0)), upgradeAdmin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        AmxVault(payable(impl)).initialize(admin, pauser, executor, MAX_TX, MAX_DAY, recovery, address(0));
    }

    function test_VaultProxyCannotBeReinitialised() public {
        AmxVault vault = _deployVault(address(0));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(buyer, buyer, buyer, MAX_TX, MAX_DAY, buyer, address(0));
    }

    function test_SaleImplementationAndProxyCannotBeInitialisedAgain() public {
        (AmxSale sale, address impl) = _deploySale();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        AmxSale(impl).initialize(buyer, buyer, buyer, buyer, buyer, buyer, buyer, buyer, 1, 1, 1);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        sale.initialize(buyer, buyer, buyer, buyer, buyer, buyer, buyer, buyer, 1, 1, 1);
    }

    // ==========================================
    //           LEGACY VAULT HONOURED
    // ==========================================

    function test_LegacyPayoutsCountAsReleasedAndCannotBePaidAgain() public {
        AmxVaultV1 legacy = new AmxVaultV1(admin, pauser, executor, MAX_TX, MAX_DAY, recovery);
        _fund(address(legacy), 10 ether);
        vm.prank(executor);
        legacy.release(bytes32("paid-by-v1"), buyer, 1 ether);

        AmxVault vault = _deployVault(address(legacy));
        _fund(address(vault), 10 ether);

        assertEq(vault.legacyVault(), address(legacy));
        assertTrue(vault.released(bytes32("paid-by-v1")), "legacy payout must read as released");
        assertFalse(vault.released(bytes32("new")));

        vm.prank(executor);
        vm.expectRevert("already released");
        vault.release(bytes32("paid-by-v1"), buyer, 1 ether);

        vm.prank(executor);
        vault.release(bytes32("new"), buyer, 1 ether);
        assertTrue(vault.released(bytes32("new")));
        assertEq(buyer.balance, 2 ether);
    }

    function test_LegacyPaidAfterCutoverIsStillRefused() public {
        // The live check (not a snapshot) is what covers a payout that lands on the old vault
        // after the new one was deployed.
        AmxVaultV1 legacy = new AmxVaultV1(admin, pauser, executor, MAX_TX, MAX_DAY, recovery);
        _fund(address(legacy), 10 ether);
        AmxVault vault = _deployVault(address(legacy));
        _fund(address(vault), 10 ether);

        vm.prank(executor);
        legacy.release(bytes32("late"), buyer, 1 ether);

        vm.prank(executor);
        vm.expectRevert("already released");
        vault.release(bytes32("late"), buyer, 1 ether);
    }

    function test_RevertWhen_LegacyVaultIsNotAContract() public {
        AmxVault impl = new AmxVault();
        bytes memory init =
            abi.encodeCall(AmxVault.initialize, (admin, pauser, executor, MAX_TX, MAX_DAY, recovery, buyer));
        vm.expectRevert("invalid legacy vault");
        new TransparentUpgradeableProxy(address(impl), upgradeAdmin, init);
    }

    function test_RevertWhen_LegacyVaultIsNotAVault() public {
        address notAVault = address(new MockERC20("x", "x"));
        AmxVault impl = new AmxVault();
        bytes memory init =
            abi.encodeCall(AmxVault.initialize, (admin, pauser, executor, MAX_TX, MAX_DAY, recovery, notAVault));
        vm.expectRevert();
        new TransparentUpgradeableProxy(address(impl), upgradeAdmin, init);
    }

    // ==========================================
    //      CUTOVER: OLD VAULT -> NEW VAULT
    // ==========================================

    /// @notice The mainnet runbook, step by step, against a verbatim copy of the live vault.
    function test_CutoverMovesEveryWeiAndBlocksReplays() public {
        AmxVaultV1 oldVault = new AmxVaultV1(admin, pauser, executor, MAX_TX, MAX_DAY, recovery);
        _fund(address(oldVault), 98_489.26177720188 ether);
        bytes32[3] memory paid = [bytes32("p1"), bytes32("p2"), bytes32("p3")];
        vm.startPrank(executor);
        for (uint256 i; i < paid.length; i++) {
            oldVault.release(paid[i], buyer, 1 ether);
        }
        vm.stopPrank();
        uint256 balanceToMove = address(oldVault).balance;

        AmxVault newVault = _deployVault(address(oldVault));

        // Pause old vault, point its recovery at the new vault, sweep.
        vm.prank(pauser);
        oldVault.pause();
        vm.startPrank(admin);
        oldVault.setRecoveryAddress(address(newVault));
        vm.expectEmit(true, false, false, true, address(newVault));
        emit AmxVault.ToppedUp(address(oldVault), balanceToMove);
        oldVault.emergencyRecoverAll();
        vm.stopPrank();

        assertEq(address(oldVault).balance, 0, "old vault must be empty");
        assertEq(address(newVault).balance, balanceToMove, "every wei must arrive");

        // No purchase the old vault paid can be paid again, and the frontend still sees it paid.
        for (uint256 i; i < paid.length; i++) {
            assertTrue(newVault.released(paid[i]));
            vm.prank(executor);
            vm.expectRevert("already released");
            newVault.release(paid[i], buyer, 1 ether);
        }

        // New purchases pay normally from the moved funds.
        vm.prank(executor);
        newVault.release(bytes32("p4"), buyer, 5 ether);
        assertEq(address(newVault).balance, balanceToMove - 5 ether);
    }

    /// @notice A misconfigured relayer pointed at the OLD sale, paying from the NEW vault, must
    /// not be able to double-pay: the old sale's depositIds are exactly what the old vault paid.
    function test_OldSaleDepositIdsCannotBePaidByNewVault() public {
        (AmxSale oldSale,) = _deploySale();
        // Read before any vm.prank: computeDepositId is itself an external call.
        bytes32 oldId = oldSale.computeDepositId(1);
        AmxVaultV1 oldVault = new AmxVaultV1(admin, pauser, executor, MAX_TX, MAX_DAY, recovery);
        _fund(address(oldVault), 10 ether);
        vm.prank(executor);
        oldVault.release(oldId, buyer, 1 ether);

        AmxVault newVault = _deployVault(address(oldVault));
        _fund(address(newVault), 10 ether);
        (AmxSale newSale,) = _deploySale();
        bytes32 newId = newSale.computeDepositId(1);

        vm.prank(executor);
        vm.expectRevert("already released");
        newVault.release(oldId, buyer, 1 ether);

        // The new sale's purchase #1 is a different depositId and pays normally.
        assertTrue(newId != oldId);
        vm.prank(executor);
        newVault.release(newId, buyer, 1 ether);
        assertTrue(newVault.released(newId));
    }

    // ==========================================
    //                 UPGRADES
    // ==========================================

    function test_VaultUpgradePreservesStateAndLegacyLink() public {
        AmxVaultV1 legacy = new AmxVaultV1(admin, pauser, executor, MAX_TX, MAX_DAY, recovery);
        _fund(address(legacy), 1 ether);
        vm.prank(executor);
        legacy.release(bytes32("old"), buyer, 1 ether);

        AmxVault vault = _deployVault(address(legacy));
        _fund(address(vault), 100 ether);
        vm.prank(executor);
        vault.release(bytes32("before"), buyer, 7 ether);
        vm.prank(admin);
        vault.setCaps(50 ether, 400 ether);

        address v2 = address(new AmxVaultV2Mock());
        vm.prank(upgradeAdmin);
        _proxyAdmin(address(vault)).upgradeAndCall(ITransparentUpgradeableProxy(address(vault)), v2, "");

        assertEq(AmxVaultV2Mock(payable(address(vault))).version(), 2);
        assertTrue(vault.released(bytes32("before")));
        assertTrue(vault.released(bytes32("old")), "legacy link must survive the upgrade");
        assertEq(vault.releasedInDay(block.timestamp / 1 days), 7 ether);
        assertEq(vault.maxReleasePerTx(), 50 ether);
        assertEq(vault.maxReleasePerDay(), 400 ether);
        assertEq(address(vault).balance, 93 ether);
        assertTrue(vault.hasRole(vault.EXECUTOR_ROLE(), executor));

        vm.prank(executor);
        vm.expectRevert("already released");
        vault.release(bytes32("before"), buyer, 1 ether);
    }

    function test_OnlyProxyAdminOwnerCanUpgradeVault() public {
        AmxVault vault = _deployVault(address(0));
        ProxyAdmin pa = _proxyAdmin(address(vault));
        assertEq(pa.owner(), upgradeAdmin);
        address v2 = address(new AmxVaultV2Mock());

        // The vault's own admin role is NOT upgrade authority.
        vm.prank(admin);
        vm.expectRevert();
        pa.upgradeAndCall(ITransparentUpgradeableProxy(address(vault)), v2, "");

        vm.prank(executor);
        vm.expectRevert();
        pa.upgradeAndCall(ITransparentUpgradeableProxy(address(vault)), v2, "");
    }

    function test_SaleUpgradeKeepsDepositIdsAndCounter() public {
        (AmxSale sale,) = _deploySale();
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        sale.buyWithBNB{value: 1 ether}();
        bytes32 idBefore = sale.computeDepositId(1);

        address v2 = address(new AmxSaleV2Mock());
        vm.prank(upgradeAdmin);
        _proxyAdmin(address(sale)).upgradeAndCall(ITransparentUpgradeableProxy(address(sale)), v2, "");

        assertEq(AmxSaleV2Mock(address(sale)).version(), 2);
        assertEq(sale.computeDepositId(1), idBefore, "depositIds are bound to the proxy, not the logic");
        assertEq(sale.computeDepositId(1), keccak256(abi.encodePacked(address(sale), uint256(1))));
        assertEq(sale.feedMaxStale(), 1 hours);
        assertEq(address(sale).balance, 1 ether);

        vm.prank(buyer);
        sale.buyWithBNB{value: 1 ether}();
        assertEq(sale.purchaseCount(), 2, "counter continues across the upgrade");
    }

    function test_UpgradeThroughTimelockNeedsTheDelay() public {
        address proposer = makeAddr("amxUpgrader");
        address[] memory roles = new address[](1);
        roles[0] = proposer;
        TimelockController timelock = new TimelockController(48 hours, roles, roles, address(0));

        (AmxVault vault,) = AmxUpgradeableDeploy.deployVault(_vaultConfig(address(0)), address(timelock));
        ProxyAdmin pa = _proxyAdmin(address(vault));
        assertEq(pa.owner(), address(timelock));

        address v2 = address(new AmxVaultV2Mock());
        bytes memory data =
            abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(address(vault)), v2, ""));

        vm.prank(proposer);
        timelock.schedule(address(pa), 0, data, bytes32(0), bytes32(0), 48 hours);

        vm.prank(proposer);
        vm.expectRevert();
        timelock.execute(address(pa), 0, data, bytes32(0), bytes32(0));

        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(proposer);
        timelock.execute(address(pa), 0, data, bytes32(0), bytes32(0));
        assertEq(AmxVaultV2Mock(payable(address(vault))).version(), 2);
    }

    // ==========================================
    //                 HELPERS
    // ==========================================

    function _deploySale() internal returns (AmxSale sale, address impl) {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC");
        MockERC20 usdt = new MockERC20("Tether", "USDT");
        MockAggregatorV3 feed = new MockAggregatorV3();
        (sale, impl) = AmxUpgradeableDeploy.deploySale(
            AmxUpgradeableDeploy.SaleConfig(
                admin,
                pauser,
                address(usdc),
                address(usdt),
                address(feed),
                makeAddr("bnbTreasury"),
                makeAddr("usdcTreasury"),
                makeAddr("usdtTreasury"),
                0.5e18,
                1e18,
                10_000e18
            ),
            upgradeAdmin
        );
    }
}
