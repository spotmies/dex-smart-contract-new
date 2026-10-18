// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
// OZ 5.5 flags ReentrancyGuard as stateless, so the plain contract is proxy-safe.
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice BSC-side payment intake for the AMX buy feature. Accepts BNB, USDC, and USDT, prices
/// AMX at a fixed USD rate (stables 1:1, BNB via a Chainlink feed), and emits a `Purchased` event
/// that an off-chain relayer watches to trigger the matching payout from `AmxVault` on Amero X.
///
/// Funds are NOT instant-forwarded to treasury on every purchase — they accumulate in this
/// contract and a permissionless `sweep*()` call pushes the full balance to a fixed, pre-set
/// treasury address. This keeps `buyWith*()` itself immune to a treasury wallet ever reverting or
/// misbehaving (a push-payment DoS class of bug), mirroring the custody discipline used in
/// AmxVault. Sweep destinations are admin-set but always fixed, pre-declared addresses — never
/// attacker- or caller-supplied.
///
/// UPGRADEABLE: deployed once as an implementation and used through a TransparentUpgradeableProxy;
/// the proxy address is the sale's permanent address, and depositIds are bound to it (address(this)
/// is the proxy under delegatecall), so they stay stable across upgrades. Rules for any future
/// version — violating these corrupts live state:
///   * Storage is APPEND-ONLY. Never reorder, remove, retype or insert above existing variables.
///   * Anything that used to be `immutable` (usdc, usdt and their decimals) now lives in storage.
///   * New initialisation goes in a new `reinitializer(n)` function, never in `initialize`.
contract AmxSale is Initializable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    error StalePrice();
    error InvalidPrice();
    error IncompleteRound();
    error PriceOutOfBounds();

    IERC20 public usdc;
    IERC20 public usdt;
    uint8 public usdcDecimals;
    uint8 public usdtDecimals;

    address public bnbPriceFeed;
    uint256 public feedMaxStale; // initialised to 1 hour in initialize()
    uint256 public feedMinPriceE18;
    uint256 public feedMaxPriceE18;

    /// @notice USD price of 1 AMX, scaled 1e18 (e.g. 0.5e18 = $0.50).
    uint256 public amxPriceUsdE18;
    /// @notice Min/max purchase size, expressed in USD scaled 1e18, asset-agnostic.
    uint256 public minPurchaseUsdE18;
    uint256 public maxPurchaseUsdE18;

    address public bnbTreasury;
    address public usdcTreasury;
    address public usdtTreasury;

    uint256 public purchaseCount;

    /// @notice depositId is the exact key AmxVault.release() will use as its nullifier on Amero
    /// X. Computed here, on-chain, and emitted directly — so neither the relayer nor the
    /// frontend ever needs to independently re-derive it from off-chain data (e.g. a BSC tx hash
    /// + log index); they just read this value straight off the event. Bound to this contract's
    /// own address so a future AmxSale redeploy can never collide with this one's purchaseIds.
    event Purchased(
        uint256 indexed purchaseId,
        address indexed buyer,
        address indexed asset,
        uint256 amountIn,
        uint256 amxOut,
        bytes32 depositId
    );
    event Swept(address indexed asset, address indexed to, uint256 amount);
    event PriceUpdated(uint256 newAmxPriceUsdE18);
    event PurchaseLimitsUpdated(uint256 minUsdE18, uint256 maxUsdE18);
    event TreasuryAddressesUpdated(address bnbTreasury, address usdcTreasury, address usdtTreasury);
    event PriceFeedUpdated(address feed);
    event FeedConfigUpdated(uint256 maxStale, uint256 minPriceE18, uint256 maxPriceE18);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Lock the bare implementation so nobody can initialise it and take its roles.
        _disableInitializers();
    }

    function initialize(
        address admin,
        address pauser,
        address usdcAddress,
        address usdtAddress,
        address bnbPriceFeedAddress,
        address bnbTreasuryAddress,
        address usdcTreasuryAddress,
        address usdtTreasuryAddress,
        uint256 initialAmxPriceUsdE18,
        uint256 initialMinPurchaseUsdE18,
        uint256 initialMaxPurchaseUsdE18
    ) external initializer {
        require(admin != address(0), "invalid admin");
        require(pauser != address(0), "invalid pauser");
        require(usdcAddress != address(0) && usdtAddress != address(0), "invalid stablecoin");
        require(bnbPriceFeedAddress != address(0), "invalid price feed");
        require(
            bnbTreasuryAddress != address(0) && usdcTreasuryAddress != address(0)
                && usdtTreasuryAddress != address(0),
            "invalid treasury"
        );
        require(initialAmxPriceUsdE18 > 0, "invalid price");
        require(initialMinPurchaseUsdE18 > 0 && initialMinPurchaseUsdE18 <= initialMaxPurchaseUsdE18, "invalid limits");

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);

        usdc = IERC20(usdcAddress);
        usdt = IERC20(usdtAddress);
        usdcDecimals = IERC20Metadata(usdcAddress).decimals();
        usdtDecimals = IERC20Metadata(usdtAddress).decimals();

        bnbPriceFeed = bnbPriceFeedAddress;
        feedMaxStale = 1 hours;
        bnbTreasury = bnbTreasuryAddress;
        usdcTreasury = usdcTreasuryAddress;
        usdtTreasury = usdtTreasuryAddress;

        amxPriceUsdE18 = initialAmxPriceUsdE18;
        minPurchaseUsdE18 = initialMinPurchaseUsdE18;
        maxPurchaseUsdE18 = initialMaxPurchaseUsdE18;
    }

    // ==========================================
    //                  BUY
    // ==========================================

    function buyWithBNB() external payable whenNotPaused nonReentrant {
        require(msg.value > 0, "zero value");

        uint256 priceUsdE18 = _getBnbPriceUsdE18();
        uint256 amountInUsdE18 = (msg.value * priceUsdE18) / 1e18;
        uint256 amxOut = _quoteAmxOut(amountInUsdE18);

        purchaseCount += 1;
        emit Purchased(purchaseCount, msg.sender, address(0), msg.value, amxOut, _computeDepositId(purchaseCount));
    }

    function buyWithStable(IERC20 token, uint256 amountIn) external whenNotPaused nonReentrant {
        require(address(token) == address(usdc) || address(token) == address(usdt), "unsupported token");
        require(amountIn > 0, "zero amount");

        uint8 tokenDecimals = address(token) == address(usdc) ? usdcDecimals : usdtDecimals;
        uint256 amountInUsdE18 = (amountIn * 1e18) / (10 ** tokenDecimals);
        uint256 amxOut = _quoteAmxOut(amountInUsdE18);

        purchaseCount += 1;
        token.safeTransferFrom(msg.sender, address(this), amountIn);

        emit Purchased(
            purchaseCount, msg.sender, address(token), amountIn, amxOut, _computeDepositId(purchaseCount)
        );
    }

    /// @notice The exact formula AmxVault.release() callers must use as depositId for a given
    /// purchase. Public so it can be verified/recomputed independently if ever needed, though
    /// consumers should just read the emitted value rather than recompute this themselves.
    function computeDepositId(uint256 purchaseId) public view returns (bytes32) {
        return _computeDepositId(purchaseId);
    }

    function _computeDepositId(uint256 purchaseId) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), purchaseId));
    }

    function _quoteAmxOut(uint256 amountInUsdE18) internal view returns (uint256) {
        require(amountInUsdE18 >= minPurchaseUsdE18, "below min purchase");
        require(amountInUsdE18 <= maxPurchaseUsdE18, "exceeds max purchase");
        return (amountInUsdE18 * 1e18) / amxPriceUsdE18;
    }

    /// @notice Preview the AMX a given amount of `asset` would currently buy, without executing a
    /// purchase. `asset` = address(0) for BNB, or the USDC/USDT address.
    function quoteAmxOut(address asset, uint256 amountIn) external view returns (uint256) {
        uint256 amountInUsdE18;
        if (asset == address(0)) {
            amountInUsdE18 = (amountIn * _getBnbPriceUsdE18()) / 1e18;
        } else if (asset == address(usdc)) {
            amountInUsdE18 = (amountIn * 1e18) / (10 ** usdcDecimals);
        } else if (asset == address(usdt)) {
            amountInUsdE18 = (amountIn * 1e18) / (10 ** usdtDecimals);
        } else {
            revert("unsupported asset");
        }
        return _quoteAmxOut(amountInUsdE18);
    }

    // ==========================================
    //             ORACLE (Chainlink)
    // ==========================================

    function getBnbPriceUsdE18() external view returns (uint256) {
        return _getBnbPriceUsdE18();
    }

    function _getBnbPriceUsdE18() internal view returns (uint256) {
        IAggregatorV3 feed = IAggregatorV3(bnbPriceFeed);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();

        if (answer <= 0) revert InvalidPrice();
        if (updatedAt == 0) revert IncompleteRound();
        if (answeredInRound < roundId) revert IncompleteRound();
        if (block.timestamp - updatedAt > feedMaxStale) revert StalePrice();

        uint8 feedDecimals = feed.decimals();
        uint256 priceE18 = uint256(answer) * (10 ** (18 - feedDecimals));

        if (feedMinPriceE18 != 0 && priceE18 < feedMinPriceE18) revert PriceOutOfBounds();
        if (feedMaxPriceE18 != 0 && priceE18 > feedMaxPriceE18) revert PriceOutOfBounds();

        return priceE18;
    }

    // ==========================================
    //                 SWEEP
    // ==========================================

    /// @notice Sweeps the full BNB balance to the fixed bnbTreasury address. Permissionless —
    /// safe because the destination is always the pre-set treasury, never caller-supplied.
    function sweepBNB() external nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "nothing to sweep");
        (bool ok,) = bnbTreasury.call{value: balance}("");
        require(ok, "sweep transfer failed");
        emit Swept(address(0), bnbTreasury, balance);
    }

    function sweepToken(IERC20 token) external nonReentrant {
        require(address(token) == address(usdc) || address(token) == address(usdt), "unsupported token");
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "nothing to sweep");
        address to = address(token) == address(usdc) ? usdcTreasury : usdtTreasury;
        token.safeTransfer(to, balance);
        emit Swept(address(token), to, balance);
    }

    // ==========================================
    //                 ADMIN
    // ==========================================

    function setPrice(uint256 newAmxPriceUsdE18) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newAmxPriceUsdE18 > 0, "invalid price");
        amxPriceUsdE18 = newAmxPriceUsdE18;
        emit PriceUpdated(newAmxPriceUsdE18);
    }

    function setPurchaseLimits(uint256 minUsdE18, uint256 maxUsdE18) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(minUsdE18 > 0 && minUsdE18 <= maxUsdE18, "invalid limits");
        minPurchaseUsdE18 = minUsdE18;
        maxPurchaseUsdE18 = maxUsdE18;
        emit PurchaseLimitsUpdated(minUsdE18, maxUsdE18);
    }

    function setTreasuryAddresses(address newBnbTreasury, address newUsdcTreasury, address newUsdtTreasury)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(
            newBnbTreasury != address(0) && newUsdcTreasury != address(0) && newUsdtTreasury != address(0),
            "invalid treasury"
        );
        bnbTreasury = newBnbTreasury;
        usdcTreasury = newUsdcTreasury;
        usdtTreasury = newUsdtTreasury;
        emit TreasuryAddressesUpdated(newBnbTreasury, newUsdcTreasury, newUsdtTreasury);
    }

    function setPriceFeed(address feed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(feed != address(0), "invalid feed");
        bnbPriceFeed = feed;
        emit PriceFeedUpdated(feed);
    }

    function setFeedConfig(uint256 maxStale, uint256 minPriceE18, uint256 maxPriceE18)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(maxStale > 0, "invalid staleness window");
        require(maxPriceE18 == 0 || maxPriceE18 >= minPriceE18, "bad bounds");
        feedMaxStale = maxStale;
        feedMinPriceE18 = minPriceE18;
        feedMaxPriceE18 = maxPriceE18;
        emit FeedConfigUpdated(maxStale, minPriceE18, maxPriceE18);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
