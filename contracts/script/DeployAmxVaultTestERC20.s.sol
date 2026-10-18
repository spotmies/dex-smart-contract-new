// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {console} from "forge-std/Script.sol";
import {AmxVaultTestERC20} from "../src/AmxVaultTestERC20.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {AmxUpgradeableDeploy} from "./lib/AmxUpgradeableDeploy.sol";
import {UpgradeAuthority} from "./lib/UpgradeAuthority.sol";

/// @notice Deploys the testnet-only AmxVaultTestERC20 behind a proxy, backed by a freely-mintable
/// MockERC20 "test AMX" token. Run against any EVM testnet (BSC testnet, Sepolia, local Anvil) —
/// does not require a live Amero X testnet chain. Never point this at anything meant to hold real
/// value.
///
/// Required env vars:
///   PRIVATE_KEY                 - deployer key, pays gas (defaults to the well-known Anvil dev key)
///   ADMIN_ADDRESS                - holds DEFAULT_ADMIN_ROLE
///   PAUSER_ADDRESS                - holds PAUSER_ROLE
///   EXECUTOR_ADDRESS              - holds EXECUTOR_ROLE (the relayer's key)
///   TREASURY_RECOVERY_ADDRESS     - emergencyRecoverAll() destination
/// Upgrade authority: AMX_UPGRADE_ADMIN, or AMX_UPGRADE_TIMELOCK_DELAY + AMX_UPGRADE_PROPOSER;
///   on a testnet ALLOW_DEPLOYER_UPGRADE_ADMIN=true makes the deployer the upgrade owner instead.
/// Optional env vars:
///   TEST_TOKEN_ADDRESS (default: none -> deploys a fresh MockERC20 "Test AMX" / "tAMX")
///   MAX_RELEASE_PER_TX (18-decimal units, default 10,000 tAMX)
///   MAX_RELEASE_PER_DAY (18-decimal units, default 100,000 tAMX)
///   INITIAL_TOPUP (18-decimal units, default 0) - test tokens minted + topped up into the vault
contract DeployAmxVaultTestERC20 is UpgradeAuthority {
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
            legacyVault: address(0)
        });
        address existingTestToken = vm.envOr("TEST_TOKEN_ADDRESS", address(0));
        uint256 initialTopUp = vm.envOr("INITIAL_TOPUP", uint256(0));

        vm.startBroadcast(deployerPrivateKey);

        address upgradeAdmin = _resolveUpgradeAdmin("AMX_", vm.addr(deployerPrivateKey));

        MockERC20 testToken;
        if (existingTestToken == address(0)) {
            testToken = new MockERC20("Test AMX", "tAMX");
            console.log("MockERC20 (Test AMX) deployed at:", address(testToken));
        } else {
            testToken = MockERC20(existingTestToken);
            console.log("Reusing existing test token at:", existingTestToken);
        }

        (AmxVaultTestERC20 vault, address impl) =
            AmxUpgradeableDeploy.deployTestVault(c, address(testToken), upgradeAdmin);
        console.log("AmxVaultTestERC20 PROXY (use this address):", address(vault));
        console.log("Implementation:", impl);
        console.log("Upgrade admin (owns the ProxyAdmin):", upgradeAdmin);

        if (initialTopUp > 0) {
            testToken.mint(vm.addr(deployerPrivateKey), initialTopUp);
            testToken.approve(address(vault), initialTopUp);
            vault.topUp(initialTopUp);
            console.log("AmxVaultTestERC20 topped up with:", initialTopUp);
        }

        vm.stopBroadcast();
    }
}
