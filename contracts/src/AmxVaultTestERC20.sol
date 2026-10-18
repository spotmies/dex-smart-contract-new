// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "./AmxVaultBase.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Testnet-only variant of AmxVault. Moves an ERC20 "test AMX" token (e.g. this repo's
/// MockERC20) instead of native coin, so the full release()/caps/roles/pause/recovery mechanism
/// in AmxVaultBase can be exercised on any existing EVM testnet (BSC testnet, Sepolia, local
/// Anvil) without needing a live Amero X testnet chain. Mechanically identical to AmxVault aside
/// from how the underlying asset moves — both inherit the exact same guarded release() logic
/// from AmxVaultBase.
///
/// NEVER deploy this to hold real AMX or real funds; it is a distinct, separately-deployed
/// contract from the production AmxVault specifically so the two can never be confused on-chain.
///
/// UPGRADEABLE like AmxVault: `testToken` used to be immutable and now lives in storage, after
/// AmxVaultBase's reserved gap. Same append-only rules apply.
contract AmxVaultTestERC20 is AmxVaultBase {
    using SafeERC20 for IERC20;

    IERC20 public testToken;

    event ToppedUp(address indexed from, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address pauser,
        address initialExecutor,
        uint256 maxReleasePerTx_,
        uint256 maxReleasePerDay_,
        address treasuryRecoveryAddress_,
        address testToken_
    ) external initializer {
        require(testToken_ != address(0), "invalid test token");
        __AmxVaultBase_init(
            admin, pauser, initialExecutor, maxReleasePerTx_, maxReleasePerDay_, treasuryRecoveryAddress_, address(0)
        );
        testToken = IERC20(testToken_);
    }

    /// @notice Pulls `amount` of the test token from the caller into the vault. Unlike the
    /// production vault's receive(), this is a plain ERC20 pull — fine for a testnet contract
    /// funded from a mock/faucet token, not real treasury funds.
    function topUp(uint256 amount) external {
        testToken.safeTransferFrom(msg.sender, address(this), amount);
        emit ToppedUp(msg.sender, amount);
    }

    function _availableBalance() internal view override returns (uint256) {
        return testToken.balanceOf(address(this));
    }

    function _payOut(address to, uint256 amount) internal override {
        testToken.safeTransfer(to, amount);
    }
}
