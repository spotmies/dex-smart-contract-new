// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "./AmxVaultBase.sol";

/// @notice Production vault: holds native AMX on the Amero X chain and releases it via the
/// shared, guarded release() flow in AmxVaultBase. This is the contract intended to hold real
/// funds. For testnet exercises against an ERC20 mock token, use AmxVaultTestERC20 instead —
/// never point real AMX at that contract.
///
/// UPGRADEABLE: deployed once as an implementation and used through a TransparentUpgradeableProxy;
/// the proxy address is the vault's permanent address. Amero X only enables forks through London,
/// so this contract and its proxy must be compiled with evm_version = london (no PUSH0).
contract AmxVault is AmxVaultBase {
    event ToppedUp(address indexed from, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Lock the bare implementation so nobody can initialise it and take its roles. Proxies
        // are unaffected: they use their own storage.
        _disableInitializers();
    }

    /// @param legacyVault_ the vault this one replaces (its payouts are honoured), or address(0).
    function initialize(
        address admin,
        address pauser,
        address initialExecutor,
        uint256 maxReleasePerTx_,
        uint256 maxReleasePerDay_,
        address treasuryRecoveryAddress_,
        address legacyVault_
    ) external initializer {
        __AmxVaultBase_init(
            admin, pauser, initialExecutor, maxReleasePerTx_, maxReleasePerDay_, treasuryRecoveryAddress_, legacyVault_
        );
    }

    receive() external payable {
        emit ToppedUp(msg.sender, msg.value);
    }

    function _availableBalance() internal view override returns (uint256) {
        return address(this).balance;
    }

    function _payOut(address to, uint256 amount) internal override {
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }
}
