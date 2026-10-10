// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Decides who holds upgrade authority for a deployment. Inherit it in a deploy script.
///
/// Resolution order, first match wins:
///   1. UPGRADE_ADMIN=<address>        use exactly this address (e.g. an existing Safe or timelock).
///   2. UPGRADE_TIMELOCK_DELAY=<secs>  deploy a TimelockController and use it. The proposer and
///                                     executor default to the deployer; override with
///                                     UPGRADE_PROPOSER=<address>. The timelock is deployed with no
///                                     separate admin, so changing its roles later must itself go
///                                     through the delay.
///   3. otherwise the deployer         ONLY on a local chain (31337), or if
///                                     ALLOW_DEPLOYER_UPGRADE_ADMIN=true is set explicitly.
///
/// Step 3 exists for local development. Anywhere else the script reverts instead of quietly making
/// a hot deployer key the owner of every contract's logic: whoever holds upgrade authority can
/// replace the code that holds user funds.
///
/// Moving from one signer to a multisig later is a role change on the timelock (grant the multisig
/// PROPOSER_ROLE, revoke the old key), not a redeploy; no contract address changes.
abstract contract UpgradeAuthority is Script {
    /// @notice Reads the configuration from the environment and applies the rules above.
    function _resolveUpgradeAdmin(address deployer) internal returns (address) {
        return _pickUpgradeAdmin(
            vm.envOr("UPGRADE_ADMIN", address(0)),
            vm.envOr("UPGRADE_TIMELOCK_DELAY", uint256(0)),
            vm.envOr("UPGRADE_PROPOSER", deployer),
            vm.envOr("ALLOW_DEPLOYER_UPGRADE_ADMIN", false),
            deployer
        );
    }

    /// @dev The rules themselves, with the configuration passed in. Split from the env reads so the
    /// guard can be unit-tested without mutating process-wide environment variables.
    function _pickUpgradeAdmin(
        address explicitAdmin,
        uint256 timelockDelay,
        address proposer,
        bool allowDeployer,
        address deployer
    ) internal returns (address admin) {
        if (explicitAdmin != address(0)) {
            console.log("Upgrade admin (UPGRADE_ADMIN):", explicitAdmin);
            return explicitAdmin;
        }

        if (timelockDelay > 0) {
            address[] memory roleHolders = new address[](1);
            roleHolders[0] = proposer;
            TimelockController timelock = new TimelockController(timelockDelay, roleHolders, roleHolders, address(0));
            console.log("Upgrade admin: new TimelockController", address(timelock));
            console.log("  min delay (s):", timelockDelay);
            console.log("  proposer + executor:", proposer);
            return address(timelock);
        }

        require(
            block.chainid == 31337 || allowDeployer,
            "Set UPGRADE_ADMIN or UPGRADE_TIMELOCK_DELAY; refusing to make the deployer the upgrade owner"
        );
        console.log("WARNING: deployer is the upgrade admin. Local/test use only:", deployer);
        return deployer;
    }
}
