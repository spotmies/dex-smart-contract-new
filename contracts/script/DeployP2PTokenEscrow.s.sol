// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {console} from "forge-std/Script.sol";
import {P2PTokenEscrows} from "../src/P2PTokenEscrow.sol";
import {UpgradeableDeploy} from "./lib/UpgradeableDeploy.sol";
import {UpgradeAuthority} from "./lib/UpgradeAuthority.sol";

/**
 * @notice Deploy the P2P escrow behind a TransparentUpgradeableProxy.
 *
 * The PROXY address is the escrow's permanent address: record it, point the frontend / backend at
 * it, and it never changes across upgrades. The implementation address is incidental.
 *
 * Who may upgrade is required config (see UpgradeAuthority):
 *   UPGRADE_ADMIN           - use this address (an existing Safe / timelock), OR
 *   UPGRADE_TIMELOCK_DELAY  - seconds; deploys a TimelockController
 * The script refuses to run on a real network without one of them. The deployer is the escrow's
 * `owner` (token whitelist admin); that is a different role from upgrade authority.
 */
contract DeployP2PTokenEscrow is UpgradeAuthority {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address deployer = msg.sender;
        address upgradeAdmin = _resolveUpgradeAdmin(deployer);

        (P2PTokenEscrows escrow, address impl) = UpgradeableDeploy.deployP2P(deployer, upgradeAdmin);
        console.log("P2PTokenEscrows PROXY (use this address):", address(escrow));
        console.log("Implementation:", impl);
        console.log("Owner (whitelist admin):", escrow.owner());
        console.log("Upgrade admin (owns the ProxyAdmin):", upgradeAdmin);

        vm.stopBroadcast();
    }
}
