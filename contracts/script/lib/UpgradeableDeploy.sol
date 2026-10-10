// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Market} from "../../src/new_perp/src/core/Market.sol";
import {Vault} from "../../src/new_perp/src/core/Vault.sol";
import {MarketFactory} from "../../src/new_perp/src/core/MarketFactory.sol";
import {P2PTokenEscrows} from "../../src/P2PTokenEscrow.sol";

/// @notice The ONE place that knows how to stand up the upgradeable contracts, shared by the
/// deploy scripts and the test suite so production and tests cannot drift apart.
///
/// All functions are `internal`, so this library has no bytecode of its own: the `new`s run in
/// the caller. Under `vm.startBroadcast()` they are therefore real transactions from the
/// broadcaster, exactly like a hand-written deployment.
///
/// `upgradeAdmin` is whoever may replace logic later. It owns each beacon / ProxyAdmin. On any
/// real network it should be a TimelockController (see UpgradeAuthority), never the deployer key.
library UpgradeableDeploy {
    /// @dev ERC-1967 admin slot: keccak256("eip1967.proxy.admin") - 1. Holds the ProxyAdmin that
    /// a TransparentUpgradeableProxy created for itself.
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    struct Perp {
        MarketFactory factory;
        UpgradeableBeacon marketBeacon;
        UpgradeableBeacon vaultBeacon;
        address marketImpl;
        address vaultImpl;
    }

    /// @notice Market + Vault implementations, one beacon for each, and the factory wired to both.
    function deployPerp(address upgradeAdmin) internal returns (Perp memory p) {
        p.marketImpl = address(new Market());
        p.vaultImpl = address(new Vault());
        p.marketBeacon = new UpgradeableBeacon(p.marketImpl, upgradeAdmin);
        p.vaultBeacon = new UpgradeableBeacon(p.vaultImpl, upgradeAdmin);
        p.factory = new MarketFactory(address(p.marketBeacon), address(p.vaultBeacon));
    }

    /// @notice P2P escrow behind a TransparentUpgradeableProxy. `owner` runs the token whitelist;
    /// `upgradeAdmin` owns the ProxyAdmin that the proxy creates for itself.
    function deployP2P(address owner, address upgradeAdmin) internal returns (P2PTokenEscrows escrow, address impl) {
        impl = address(new P2PTokenEscrows());
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            impl, upgradeAdmin, abi.encodeCall(P2PTokenEscrows.initialize, (owner))
        );
        escrow = P2PTokenEscrows(address(proxy));
    }

    /// @notice A single Vault behind its own beacon, without a factory. For tests / one-off use.
    function deployVault(address quote, address vaultOwner, address upgradeAdmin) internal returns (Vault v) {
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(new Vault()), upgradeAdmin);
        v = Vault(address(new BeaconProxy(address(beacon), abi.encodeCall(Vault.initialize, (quote, vaultOwner)))));
    }

    /// @notice A single Market behind its own beacon, without a factory. For tests / one-off use.
    function deployMarket(
        string memory baseSymbol,
        address quote,
        address vault,
        address oracle,
        address priceFeed,
        address marketOwner,
        address upgradeAdmin
    ) internal returns (Market m) {
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(new Market()), upgradeAdmin);
        m = Market(
            address(
                new BeaconProxy(
                    address(beacon),
                    abi.encodeCall(Market.initialize, (baseSymbol, quote, vault, oracle, priceFeed, marketOwner))
                )
            )
        );
    }
}
