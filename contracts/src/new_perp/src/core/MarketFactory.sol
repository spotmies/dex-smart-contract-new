// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "./Market.sol";
import "./Vault.sol";

/// @notice Deploys isolated markets and vaults for each pair.
/// @dev Every market and vault is a BeaconProxy, so upgrading is a single call on a beacon
/// (`UpgradeableBeacon.upgradeTo`) and moves EVERY market, past and future, to the new logic.
///
/// Two separate authorities, deliberately kept apart:
///   * this factory's `owner`  - may create markets (and nothing else);
///   * each beacon's owner     - may replace the logic. It should be a TimelockController, and
///                               must NOT be the same key that creates markets.
/// The factory itself is not upgradeable: it holds no funds and no per-market state beyond a
/// registry, and its immutables (the two beacons) are what pin every market to its upgrade path.
contract MarketFactory {
    address public immutable marketBeacon;
    address public immutable vaultBeacon;

    address[] public allMarkets;
    address public owner;

    event MarketCreated(address indexed market, address indexed vault, string base, address quote);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @param _marketBeacon beacon whose implementation is the Market logic
    /// @param _vaultBeacon beacon whose implementation is the Vault logic
    constructor(address _marketBeacon, address _vaultBeacon) {
        require(_marketBeacon != address(0) && _vaultBeacon != address(0), "zero beacon");
        marketBeacon = _marketBeacon;
        vaultBeacon = _vaultBeacon;
        owner = msg.sender;
    }

    function setOwner(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    /// @param baseSymbol string identifier, e.g., "ETH"
    /// @param quote stable token address (USDC)
    /// @param oracle oracle module
    /// @param priceFeed chainlink feed for base/quote
    function createMarket(
        string memory baseSymbol,
        address quote,
        address oracle,
        address priceFeed,
        address positionManager
    ) external onlyOwner returns (address market, address vault) {
        // Initialised in the proxy's own constructor, in the same transaction, so there is no
        // window in which an uninitialised proxy can be front-run and claimed.
        vault = address(new BeaconProxy(vaultBeacon, abi.encodeCall(Vault.initialize, (quote, address(this)))));

        // 1. Deploy Market with Factory as initial owner so it can configure it
        market = address(
            new BeaconProxy(
                marketBeacon,
                abi.encodeCall(Market.initialize, (baseSymbol, quote, vault, oracle, priceFeed, address(this)))
            )
        );

        Vault(vault).setMarket(market);

        // 2. Set position manager for the market (Factory is owner, so this works)
        if (positionManager != address(0)) {
            Market(market).setPositionManager(positionManager);
        }

        // 3. Transfer ownership to the caller (msg.sender)
        Market(market).transferOwnership(msg.sender);

        allMarkets.push(market);
        emit MarketCreated(market, vault, baseSymbol, quote);
    }

    function getMarkets() external view returns (address[] memory) {
        return allMarkets;
    }
}
