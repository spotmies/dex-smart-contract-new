// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {console} from "forge-std/Script.sol";
import {AmxVault} from "../src/AmxVault.sol";
import {AmxUpgradeableDeploy} from "./lib/AmxUpgradeableDeploy.sol";
import {UpgradeAuthority} from "./lib/UpgradeAuthority.sol";

/// @notice Deploys the production AmxVault (native AMX) behind a TransparentUpgradeableProxy. Run
/// against the Amero X chain (3535) with a deployer key that holds AMX to pay gas.
///
/// Amero X quirks: build with FOUNDRY_PROFILE=amerox (evm_version = london — the chain has no
/// PUSH0), pass --legacy (no EIP-1559), and confirm each tx from its receipt `status`, because
/// forge cannot parse this chain's receipts and may report failure on success.
///
/// The PROXY address is the vault's permanent address (frontend VITE_AMX_VAULT_ADDRESS, relayer
/// AMX_VAULT_ADDRESS).
///
/// Required env vars:
///   PRIVATE_KEY                 - deployer key, pays gas (defaults to the well-known Anvil dev key)
///   ADMIN_ADDRESS                - holds DEFAULT_ADMIN_ROLE
///   PAUSER_ADDRESS                - holds PAUSER_ROLE
///   EXECUTOR_ADDRESS              - holds EXECUTOR_ROLE (the relayer's key)
///   TREASURY_RECOVERY_ADDRESS     - emergencyRecoverAll() destination
/// Upgrade authority (required on a real network; AMX contracts have their own, see UpgradeAuthority):
///   AMX_UPGRADE_ADMIN=<address>, OR
///   AMX_UPGRADE_TIMELOCK_DELAY=<secs> + AMX_UPGRADE_PROPOSER=<address>
/// Optional env vars:
///   LEGACY_VAULT_ADDRESS (default: none) - the vault being replaced; every depositId it already
///                                          paid is treated as released by the new vault
///   MAX_RELEASE_PER_TX (wei, default 10,000 AMX)
///   MAX_RELEASE_PER_DAY (wei, default 100,000 AMX)
///   INITIAL_TOPUP (wei, default 0) - native AMX sent to the vault right after deployment
contract DeployAmxVault is UpgradeAuthority {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey =
            vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));

        AmxUpgradeableDeploy.VaultConfig memory c = AmxUpgradeableDeploy.VaultConfig({
            admin: vm.envAddress("ADMIN_ADDRESS"),
            pauser: vm.envAddress("PAUSER_ADDRESS"),
            executor: vm.envAddress("EXECUTOR_ADDRESS"),
            maxReleasePerTx: vm.envOr("MAX_RELEASE_PER_TX", uint256(10_000 ether)),
            maxReleasePerDay: vm.envOr("MAX_RELEASE_PER_DAY", uint256(100_000 ether)),
            treasuryRecovery: vm.envAddress("TREASURY_RECOVERY_ADDRESS"),
            legacyVault: vm.envOr("LEGACY_VAULT_ADDRESS", address(0))
        });
        uint256 initialTopUp = vm.envOr("INITIAL_TOPUP", uint256(0));

        vm.startBroadcast(deployerPrivateKey);

        // Fail fast, before the vault is deployed, if upgrade authority is not configured.
        address upgradeAdmin = _resolveUpgradeAdmin("AMX_", vm.addr(deployerPrivateKey));

        (AmxVault vault, address impl) = AmxUpgradeableDeploy.deployVault(c, upgradeAdmin);
        console.log("AmxVault PROXY (use this address):", address(vault));
        console.log("Implementation:", impl);
        console.log("Upgrade admin (owns the ProxyAdmin):", upgradeAdmin);
        console.log("Legacy vault honoured:", vault.legacyVault());

        if (initialTopUp > 0) {
            (bool ok,) = address(vault).call{value: initialTopUp}("");
            require(ok, "initial top-up failed");
            console.log("AmxVault topped up with:", initialTopUp);
        }

        vm.stopBroadcast();
    }
}
