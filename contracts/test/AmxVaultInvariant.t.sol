// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {AmxVault} from "../src/AmxVault.sol";
import {AmxUpgradeableDeploy} from "../script/lib/AmxUpgradeableDeploy.sol";

/// @dev Fuzzes sequences of fund()/release() calls (including deliberate depositId reuse) and
/// tracks ground truth externally so the invariants below can check the vault against it.
contract AmxVaultHandler is Test {
    AmxVault public vault;
    address public executor;

    uint256 public totalFunded;
    uint256 public totalReleased;
    uint256 public depositCounter;
    mapping(bytes32 => bool) public knownDepositIds;

    constructor(AmxVault _vault, address _executor) {
        vault = _vault;
        executor = _executor;
    }

    function fund(uint256 amountSeed) public {
        uint256 amount = bound(amountSeed, 0, 1_000 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        require(ok, "fund failed");
        totalFunded += amount;
    }

    function release(uint256 amountSeed, uint256 toSeed, uint256 depositSeed, bool reuseExisting) public {
        uint256 amount = bound(amountSeed, 1, vault.maxReleasePerTx());
        address to = address(uint160(bound(toSeed, 1, type(uint160).max)));

        bytes32 depositId;
        if (reuseExisting && depositCounter > 0) {
            depositId = bytes32(bound(depositSeed, 0, depositCounter - 1));
        } else {
            depositId = bytes32(depositCounter);
            depositCounter += 1;
        }

        bool wasAlreadyUsed = knownDepositIds[depositId];

        vm.prank(executor);
        try vault.release(depositId, to, amount) {
            // A successful release must never happen twice for the same depositId — if it did,
            // the on-chain nullifier is broken and this assertion catches it immediately.
            assertFalse(wasAlreadyUsed, "nullifier bypass: depositId released twice");
            knownDepositIds[depositId] = true;
            totalReleased += amount;
        } catch {
            // Expected: cap exceeded, insufficient balance, paused, or already-released.
        }
    }
}

contract AmxVaultInvariantTest is Test {
    AmxVault public vault;
    AmxVaultHandler public handler;

    address public admin = makeAddr("admin");
    address public pauser = makeAddr("pauser");
    address public executor = makeAddr("executor");
    address public recovery = makeAddr("recovery");

    function setUp() public {
        (vault,) = AmxUpgradeableDeploy.deployVault(
            AmxUpgradeableDeploy.VaultConfig(admin, pauser, executor, 100 ether, 500 ether, recovery, address(0)),
            makeAddr("upgradeAdmin")
        );
        handler = new AmxVaultHandler(vault, executor);

        targetContract(address(handler));
    }

    /// @notice Cumulative AMX ever released must never exceed cumulative AMX ever funded —
    /// value can never materialize from nowhere.
    function invariant_ConservationOfFunds() public view {
        assertLe(handler.totalReleased(), handler.totalFunded());
    }

    /// @notice The vault's actual balance must always equal what was funded minus what was
    /// released — no drift between ground truth and on-chain state.
    function invariant_BalanceMatchesGroundTruth() public view {
        assertEq(address(vault).balance, handler.totalFunded() - handler.totalReleased());
    }
}
