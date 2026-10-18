// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {AmxSale} from "../../src/AmxSale.sol";
import {AmxVault} from "../../src/AmxVault.sol";
import {AmxVaultTestERC20} from "../../src/AmxVaultTestERC20.sol";

/// @notice The ONE place that knows how to stand up the upgradeable AMX contracts, shared by the
/// deploy scripts and the test suite so production and tests cannot drift apart.
///
/// Kept separate from UpgradeableDeploy on purpose: that library imports the perp contracts, and
/// AmxVault is deployed to Amero X, which only supports London. Importing anything here that
/// needs a newer EVM would break the London build of the vault deployment.
///
/// All functions are `internal`, so the `new`s run in the caller: under `vm.startBroadcast()` they
/// are real transactions from the broadcaster. Each contract sits behind its own
/// TransparentUpgradeableProxy, which creates a ProxyAdmin owned by `upgradeAdmin` (a timelock on
/// any real network) and is initialised in its own constructor, so there is no window in which an
/// uninitialised proxy can be claimed.
library AmxUpgradeableDeploy {
    /// @dev ERC-1967 admin slot: keccak256("eip1967.proxy.admin") - 1. Holds the proxy's ProxyAdmin.
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    struct SaleConfig {
        address admin;
        address pauser;
        address usdc;
        address usdt;
        address bnbPriceFeed;
        address bnbTreasury;
        address usdcTreasury;
        address usdtTreasury;
        uint256 amxPriceUsdE18;
        uint256 minPurchaseUsdE18;
        uint256 maxPurchaseUsdE18;
    }

    struct VaultConfig {
        address admin;
        address pauser;
        address executor;
        uint256 maxReleasePerTx;
        uint256 maxReleasePerDay;
        address treasuryRecovery;
        address legacyVault; // previous vault whose payouts are honoured, or address(0)
    }

    function deploySale(SaleConfig memory c, address upgradeAdmin) internal returns (AmxSale sale, address impl) {
        impl = address(new AmxSale());
        bytes memory init = abi.encodeCall(
            AmxSale.initialize,
            (
                c.admin,
                c.pauser,
                c.usdc,
                c.usdt,
                c.bnbPriceFeed,
                c.bnbTreasury,
                c.usdcTreasury,
                c.usdtTreasury,
                c.amxPriceUsdE18,
                c.minPurchaseUsdE18,
                c.maxPurchaseUsdE18
            )
        );
        sale = AmxSale(address(new TransparentUpgradeableProxy(impl, upgradeAdmin, init)));
    }

    function deployVault(VaultConfig memory c, address upgradeAdmin) internal returns (AmxVault vault, address impl) {
        impl = address(new AmxVault());
        bytes memory init = abi.encodeCall(
            AmxVault.initialize,
            (c.admin, c.pauser, c.executor, c.maxReleasePerTx, c.maxReleasePerDay, c.treasuryRecovery, c.legacyVault)
        );
        vault = AmxVault(payable(address(new TransparentUpgradeableProxy(impl, upgradeAdmin, init))));
    }

    /// @notice Testnet-only ERC20 vault. `c.legacyVault` is ignored (always address(0)).
    function deployTestVault(VaultConfig memory c, address testToken, address upgradeAdmin)
        internal
        returns (AmxVaultTestERC20 vault, address impl)
    {
        impl = address(new AmxVaultTestERC20());
        bytes memory init = abi.encodeCall(
            AmxVaultTestERC20.initialize,
            (c.admin, c.pauser, c.executor, c.maxReleasePerTx, c.maxReleasePerDay, c.treasuryRecovery, testToken)
        );
        vault = AmxVaultTestERC20(address(new TransparentUpgradeableProxy(impl, upgradeAdmin, init)));
    }
}
