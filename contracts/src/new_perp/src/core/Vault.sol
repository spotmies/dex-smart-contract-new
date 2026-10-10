// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// OZ 5.5 flags ReentrancyGuard as stateless (its status lives in a fixed namespaced slot and an
// all-zero status already means "not entered"), so the plain contract is proxy-safe and has no
// separate upgradeable variant.
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

interface IMarket {
    function unrealizedProfits() external view returns (uint256);
    function totalCollateral() external view returns (uint256);
}

/// @notice LP vault for a single isolated market. Holds USDC liquidity and mints LP shares.
/// @dev UPGRADEABLE. Deployed once as an implementation and then behind one BeaconProxy per
/// market (see MarketFactory), so a single beacon upgrade moves every market's vault at once.
///
/// Rules for any future version - violating these corrupts live state:
///   * Storage is APPEND-ONLY. Never reorder, remove, retype or insert above existing variables.
///   * Anything that used to be `immutable` (usdc, quoteScale) now lives in storage, because
///     every proxy shares this one implementation's bytecode and so cannot differ by immutable.
///   * New initialisation goes in a new `reinitializer(n)` function, never in `initialize`.
contract Vault is Initializable, ERC20Upgradeable, ReentrancyGuard, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public usdc;
    uint256 public quoteScale;
    address public market; // only market can pull funds

    /// @notice Dead shares permanently locked on the first deposit to block first-depositor
    /// share-inflation / donation attacks (H2). Critical when quoteScale == 1 (18-dec quote, BSC).
    uint256 private constant MINIMUM_LIQUIDITY = 1e3;
    address private constant DEAD = address(0xdead);

    error NotMarket();
    error InsufficientLiquidity();
    error MarketAlreadySet();

    modifier onlyMarket() {
        if (msg.sender != market) revert NotMarket();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Lock the bare implementation so nobody can initialise it directly and take ownership
        // of the logic contract. Proxies are unaffected: they use their own storage.
        _disableInitializers();
    }

    /// @param _usdc quote token this vault custodies.
    /// @param _owner owner of the vault; MarketFactory passes itself so it can call setMarket once.
    function initialize(address _usdc, address _owner) external initializer {
        require(_usdc != address(0), "zero quote");
        __ERC20_init("Perp LP", "pLP");
        __Ownable_init(_owner);

        usdc = IERC20(_usdc);
        uint8 decimals_ = IERC20Metadata(_usdc).decimals();
        require(decimals_ <= 18, "too many decimals");
        quoteScale = 10 ** (18 - decimals_);
    }

    /// @notice one-time market setter by owner/factory.
    function setMarket(address _market) external onlyOwner {
        if (market != address(0)) revert MarketAlreadySet();
        market = _market;
    }

    /// @notice Trader collateral the vault is merely custodying for open positions.
    /// This is NOT LP equity - it is owed back to traders when they close.
    function reservedAssets() public view returns (uint256) {
        address _market = market;
        if (_market == address(0)) return 0;
        return IMarket(_market).totalCollateral();
    }

    /// @notice LP-owned assets: the raw balance minus trader collateral.
    /// @dev Trader collateral is transferred into this vault by the Router on every
    /// position increase, so the raw balance mixes two owners' money. Pricing LP
    /// shares against the raw balance let LPs redeem trader collateral and left
    /// traders unable to close. Saturates at 0 rather than reverting so an
    /// undercollateralised vault degrades instead of bricking.
    function totalAssets() public view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        uint256 reserved = reservedAssets();
        return bal > reserved ? bal - reserved : 0;
    }

    /// @notice deposits USDC and mints LP shares proportionally.
    function deposit(uint256 amount, address to) external nonReentrant {
        require(amount > 0, "amount=0");
        uint256 _totalAssets = totalAssets();
        uint256 _totalSupply = totalSupply();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        uint256 shares;
        if (_totalSupply == 0) {
            uint256 minted = amount * quoteScale; // scale to 18-dec LP basis
            // H2: lock MINIMUM_LIQUIDITY dead shares on first deposit so totalSupply can never
            // be driven to ~1, which is what makes the donation/inflation attack profitable.
            require(minted > MINIMUM_LIQUIDITY, "first deposit too small");
            _mint(DEAD, MINIMUM_LIQUIDITY);
            shares = minted - MINIMUM_LIQUIDITY;
        } else {
            // Shares outstanding but no LP equity left means the vault is insolvent.
            // Re-running the seed path here would mint a second batch of dead shares
            // and price the deposit at 1:1, so refuse instead.
            require(_totalAssets > 0, "vault insolvent");
            shares = (amount * _totalSupply) / _totalAssets;
        }
        require(shares > 0, "zero shares");
        _mint(to, shares);
    }

    /// @notice withdraws USDC by burning LP shares; checks solvency vs unrealized profits.
    function withdraw(uint256 shares, address to) external nonReentrant {
        require(shares > 0, "shares=0");
        uint256 _totalSupply = totalSupply();
        require(_totalSupply > 0, "no supply");

        uint256 assets = (shares * totalAssets()) / _totalSupply;
        _burn(msg.sender, shares);

        // Everything the vault owes that is not LP equity: trader collateral held for
        // open positions, plus the profits those positions would realise right now.
        uint256 reserved = reservedAssets() + IMarket(market).unrealizedProfits();
        uint256 bal = usdc.balanceOf(address(this));
        if (assets + reserved > bal) revert InsufficientLiquidity();

        usdc.safeTransfer(to, assets);
    }

    /// @notice callable only by market to pay trader PnL or fees.
    function pull(address to, uint256 amount) external onlyMarket nonReentrant {
        usdc.safeTransfer(to, amount);
    }

    /// @notice market can push fees back to vault.
    function push(uint256 amount) external onlyMarket nonReentrant {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
    }
}
