// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// Stateless in OZ 5.5 (fixed namespaced slot, zero status == not entered): proxy-safe as-is.
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "./Vault.sol";
import "../oracle/OracleModule.sol";

/// @notice Isolated perpetual market (peer-to-pool).
/// @dev UPGRADEABLE. One implementation, one BeaconProxy per market (see MarketFactory), so a
/// single beacon upgrade moves every market at once.
///
/// Rules for any future version - violating these corrupts live positions:
///   * Storage is APPEND-ONLY. Never reorder, remove, retype or insert above existing variables.
///   * Former `immutable`s (quote, vault, oracle, priceFeed, quoteDecimals, quoteScale) are
///     storage now: all proxies share this one bytecode, so an immutable cannot differ per market.
///   * Values that used to come from field initialisers (`= 10_000_000 * WAD`, `= 10`, `= 1`)
///     are set in `initialize`. A proxy never runs the implementation's constructor or field
///     initialisers, so leaving them as initialisers would silently deploy them as zero.
///   * New initialisation goes in a new `reinitializer(n)` function, never in `initialize`.
contract Market is Initializable, ReentrancyGuard, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    struct Position {
        uint256 size; // USD notionals in 1e18
        uint256 collateral; // USDC 6d
        uint256 entryPrice; // 1e18
        int256 fundingEntry; // funding snapshot
        bool isLong;
    }

    string public baseSymbol; // e.g., "ETH"
    IERC20 public quote; // USDC (6d)
    Vault public vault;
    OracleModule public oracle;
    address public priceFeed; // chainlink feed

    uint256 public constant WAD = 1e18;
    uint256 public quoteDecimals;
    uint256 public quoteScale;
    uint256 public constant FEE_BPS = 10; // 0.1%
    uint256 public constant BPS_DIV = 10_000;
    uint256 public constant MAINT_MARGIN_BPS = 500; // 5%
    uint256 public constant FUNDING_RATE_FACTOR = 1e11; // ~0.0001% per second (1e18 scale)

    uint256 public maxOpenInterestLong; // initialised to 10m notionals in initialize()
    uint256 public maxOpenInterestShort; // initialised to 10m notionals in initialize()

    uint256 public oiLong;
    uint256 public oiShort;

    /// @notice Sum of collateral across all open positions, in quote units.
    /// The Vault reads this to keep trader money out of LP share pricing - without it
    /// LPs redeem against collateral they do not own. Must be kept in lockstep with
    /// every write to Position.collateral below.
    uint256 public totalCollateral;

    // Aggregate average entry prices (1e18) for solvency estimation
    uint256 public avgEntryLongPrice;
    uint256 public avgEntryShortPrice;

    // H5: sum(size*entry) per side; avgEntry = sum/oi, kept accurate on close too.
    uint256 public sumEntryLong;
    uint256 public sumEntryShort;

    // C3: max leverage at open (must stay <20x so initial margin > 5% maintenance).
    uint256 public maxLeverage; // initialised to 10 in initialize()

    int256 public cumulativeFundingLong;
    int256 public cumulativeFundingShort;
    uint256 public lastFundingTime;

    address public positionManager; // executor authority

    // Position ID system for multiple positions per user
    uint256 public nextPositionId; // initialised to 1 in initialize()
    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) public userPositionIds;
    mapping(uint256 => address) public positionOwner;

    event PositionIncreased(address indexed user, uint256 indexed positionId, bool isLong, uint256 size, uint256 collateral, uint256 price);
    event PositionDecreased(address indexed user, uint256 indexed positionId, bool isLong, uint256 size, uint256 collateral, uint256 price, int256 pnl);
    event Liquidated(address indexed user, uint256 indexed positionId, bool isLong, uint256 size, uint256 collateral, uint256 price, int256 pnl);
    event FundingUpdated(int256 cumulativeLong, int256 cumulativeShort);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Lock the bare implementation so it can never be initialised and owned directly.
        _disableInitializers();
    }

    function initialize(
        string memory _baseSymbol,
        address _quote,
        address _vault,
        address _oracle,
        address _priceFeed,
        address _owner
    ) external initializer {
        __Ownable_init(_owner);

        baseSymbol = _baseSymbol;
        quote = IERC20(_quote);
        quoteDecimals = IERC20Metadata(_quote).decimals();
        require(quoteDecimals <= 18, "too many decimals");
        quoteScale = 10 ** (18 - quoteDecimals);
        vault = Vault(_vault);
        oracle = OracleModule(_oracle);
        priceFeed = _priceFeed;
        lastFundingTime = block.timestamp;

        // Former field initialisers; they do not run behind a proxy.
        maxOpenInterestLong = 10_000_000 * WAD; // 10m notionals
        maxOpenInterestShort = 10_000_000 * WAD;
        maxLeverage = 10;
        nextPositionId = 1;
    }

    modifier onlyPM() {
        require(msg.sender == positionManager, "not pm");
        _;
    }

    // ---- Views ----

    function getOraclePrice() public view returns (uint256) {
        return oracle.getPrice(priceFeed); // 1e18
    }

    /// @notice Returns positive unrealized profits that the vault must keep (approx, aggregate).
    /// Converts to USDC (6d).
    function unrealizedProfits() external view returns (uint256) {
        uint256 price = getOraclePrice();
        uint256 longPnl;
        if (oiLong > 0 && price > avgEntryLongPrice && avgEntryLongPrice > 0) {
            longPnl = (oiLong * (price - avgEntryLongPrice)) / avgEntryLongPrice; // 1e18
        }
        uint256 shortPnl;
        if (oiShort > 0 && price < avgEntryShortPrice && avgEntryShortPrice > 0) {
            shortPnl = (oiShort * (avgEntryShortPrice - price)) / avgEntryShortPrice; // 1e18
        }
        uint256 totalUsd = longPnl + shortPnl; // 1e18
        return _usdToUsdc(totalUsd);
    }

    // ---- Core logic ----

    function _updateFunding(uint256 price) internal {
        uint256 dt = block.timestamp - lastFundingTime;
        if (dt == 0) return;
        lastFundingTime = block.timestamp;

        // funding = (oiLong - oiShort) / max(oiTotal,1) * factor * dt
        uint256 oiTotal = oiLong + oiShort;
        if (oiTotal == 0) return;

        int256 imbalance = int256(oiLong) - int256(oiShort);
        int256 fundingDelta = (imbalance * int256(FUNDING_RATE_FACTOR) * int256(dt)) / int256(oiTotal);

        // Long pays positive delta to short, and vice versa
        cumulativeFundingLong += fundingDelta;
        cumulativeFundingShort -= fundingDelta;
        emit FundingUpdated(cumulativeFundingLong, cumulativeFundingShort);
    }

    function increasePosition(
        address user,
        uint256 positionId, // 0 = new position, >0 = existing position
        uint256 sizeDelta, // 1e18 USD notionals
        uint256 collateralDelta, // 6d (already transferred to vault by router/pm)
        bool isLong,
        uint256 price // 1e18
    ) external nonReentrant onlyPM {
        // A zero-size increase would mint a position that decreasePosition can never
        // close (it requires p.size > 0), stranding the collateral inside
        // totalCollateral and reserving it away from LPs forever.
        require(sizeDelta > 0, "size=0");
        _updateFunding(price);

        Position storage p;
        bool isNewPosition = (positionId == 0);

        if (isNewPosition) {
            // Create new position
            positionId = nextPositionId++;
            p = positions[positionId];
            p.entryPrice = price;
            p.isLong = isLong;
            p.fundingEntry = isLong ? cumulativeFundingLong : cumulativeFundingShort;
            p.size = sizeDelta;
            positionOwner[positionId] = user;
            userPositionIds[user].push(positionId);
        } else {
            // Add to existing position
            require(positionOwner[positionId] == user, "not owner");
            p = positions[positionId];
            require(p.size > 0, "pos not found");
            require(p.isLong == isLong, "side mismatch");

            // H5: settle accrued funding before resetting snapshot (else a dust-add wipes it).
            int256 accruedFunding = _fundingPnl(p, p.size, isLong);
            if (accruedFunding >= 0) {
                uint256 credit = _usdToUsdc(uint256(accruedFunding));
                p.collateral += credit;
                totalCollateral += credit;
            } else {
                uint256 owedUsdc = _usdToUsdc(uint256(-accruedFunding));
                uint256 debit = owedUsdc >= p.collateral ? p.collateral : owedUsdc;
                p.collateral -= debit;
                totalCollateral -= debit;
            }

            // Update weighted average entry price
            uint256 newSize = p.size + sizeDelta;
            p.entryPrice = (p.entryPrice * p.size + price * sizeDelta) / newSize;
            p.fundingEntry = isLong ? cumulativeFundingLong : cumulativeFundingShort;
            p.size = newSize;
        }

        uint256 feeUsd = (sizeDelta * FEE_BPS) / BPS_DIV;
        uint256 feeUsdc = _usdToUsdc(feeUsd);
        require(collateralDelta > feeUsdc, "collat<fee");
        uint256 collateralNet = collateralDelta - feeUsdc;

        // The Router already moved collateralDelta into the vault; feeUsdc stays there
        // as LP revenue and only collateralNet is owed back to the trader.
        p.collateral += collateralNet;
        totalCollateral += collateralNet;

        // OI caps and accurate weighted-entry tracking (H5)
        if (isLong) {
            uint256 newOi = oiLong + sizeDelta;
            require(newOi <= maxOpenInterestLong, "oi long cap");
            oiLong = newOi;
            sumEntryLong += sizeDelta * price;
            avgEntryLongPrice = oiLong > 0 ? sumEntryLong / oiLong : 0;
        } else {
            uint256 newOi = oiShort + sizeDelta;
            require(newOi <= maxOpenInterestShort, "oi short cap");
            oiShort = newOi;
            sumEntryShort += sizeDelta * price;
            avgEntryShortPrice = oiShort > 0 ? sumEntryShort / oiShort : 0;
        }

        // C3: enforce max leverage on the resulting position.
        require(_usdcToUsd(p.collateral) * maxLeverage >= p.size, "exceeds max leverage");

        emit PositionIncreased(user, positionId, isLong, p.size, p.collateral, price);
    }

    function decreasePosition(
        address user,
        uint256 positionId,
        uint256 sizeDelta,
        bool isLong,
        uint256 price
    ) external nonReentrant onlyPM {
        _updateFunding(price);

        require(positionOwner[positionId] == user, "not owner");
        Position storage p = positions[positionId];
        require(p.size >= sizeDelta && p.size > 0, "size too big");
        require(p.isLong == isLong, "side mismatch");

        // H5: cache entry before the full-close branch can zero it.
        uint256 entryPriceCache = p.entryPrice;

        // Compute PnL
        int256 pnl = _calculatePnl(p, sizeDelta, price);

        // Funding payment
        int256 fundingPnl = _fundingPnl(p, sizeDelta, isLong);
        pnl += fundingPnl;

        // Fees (charged on notional reduced)
        uint256 feeUsd = (sizeDelta * FEE_BPS) / BPS_DIV;
        uint256 feeUsdc = _usdToUsdc(feeUsd);

        // proportional collateral to return
        uint256 collateralPortion = (p.collateral * sizeDelta) / p.size;

        // Update position
        p.size -= sizeDelta;
        if (p.size == 0) {
            totalCollateral -= p.collateral;
            p.collateral = 0;
            p.entryPrice = 0;
            // Remove position ID from user's list (mark as deleted by setting to 0)
            uint256[] storage ids = userPositionIds[user];
            for (uint256 i = 0; i < ids.length; i++) {
                if (ids[i] == positionId) {
                    ids[i] = ids[ids.length - 1];
                    ids.pop();
                    break;
                }
            }
        } else {
            p.collateral -= collateralPortion;
            totalCollateral -= collateralPortion;
        }

        uint256 userReturnUsdc = 0;
        if (pnl >= 0) {
            uint256 profitUsdc = _usdToUsdc(uint256(pnl));
            userReturnUsdc = profitUsdc + collateralPortion;
        } else {
            uint256 lossUsd = uint256(-pnl);
            uint256 lossUsdc = _usdToUsdc(lossUsd);
            if (lossUsdc >= collateralPortion) {
                userReturnUsdc = 0;
            } else {
                userReturnUsdc = collateralPortion - lossUsdc;
            }
        }

        // deduct fee from userReturn, fee stays in vault (already there)
        if (userReturnUsdc > feeUsdc) {
            userReturnUsdc -= feeUsdc;
        } else {
            userReturnUsdc = 0;
        }

        if (userReturnUsdc > 0) {
            vault.pull(user, userReturnUsdc);
        }

        emit PositionDecreased(user, positionId, isLong, sizeDelta, p.collateral, price, pnl);

        // reduce OI and keep weighted-entry sums accurate (H5)
        if (isLong) {
            oiLong -= sizeDelta;
            sumEntryLong -= sizeDelta * entryPriceCache;
            avgEntryLongPrice = oiLong > 0 ? sumEntryLong / oiLong : 0;
        } else {
            oiShort -= sizeDelta;
            sumEntryShort -= sizeDelta * entryPriceCache;
            avgEntryShortPrice = oiShort > 0 ? sumEntryShort / oiShort : 0;
        }
    }

    function liquidate(uint256 positionId, uint256 price) external nonReentrant onlyPM {
        Position storage p = positions[positionId];
        require(p.size > 0, "no pos");
        address user = positionOwner[positionId];
        _updateFunding(price);

        // Check maintenance margin
        int256 pnl = _calculatePnl(p, p.size, price);
        int256 fundingPnl = _fundingPnl(p, p.size, p.isLong);
        pnl += fundingPnl;

        uint256 notional = p.size; // USD 1e18
        uint256 mmRequirement = (notional * MAINT_MARGIN_BPS) / BPS_DIV; // 1e18
        uint256 mmUsdc = _usdToUsdc(mmRequirement);

        uint256 collateralPlusPnl;
        if (pnl >= 0) {
            collateralPlusPnl = p.collateral + _usdToUsdc(uint256(pnl));
        } else {
            uint256 lossUsdc = _usdToUsdc(uint256(-pnl));
            if (lossUsdc >= p.collateral) {
                collateralPlusPnl = 0;
            } else {
                collateralPlusPnl = p.collateral - lossUsdc;
            }
        }
        require(collateralPlusPnl < mmUsdc, "healthy");

        emit Liquidated(user, positionId, p.isLong, p.size, p.collateral, price, pnl);

        // Nothing is paid out on liquidation - the seized collateral becomes LP revenue,
        // so it stops being reserved.
        totalCollateral -= p.collateral;

        // adjust OI and weighted-entry sums (H5)
        if (p.isLong) {
            oiLong -= p.size;
            sumEntryLong -= p.size * p.entryPrice;
            avgEntryLongPrice = oiLong > 0 ? sumEntryLong / oiLong : 0;
        } else {
            oiShort -= p.size;
            sumEntryShort -= p.size * p.entryPrice;
            avgEntryShortPrice = oiShort > 0 ? sumEntryShort / oiShort : 0;
        }

        // Remove position ID from user's list
        uint256[] storage ids = userPositionIds[user];
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == positionId) {
                ids[i] = ids[ids.length - 1];
                ids.pop();
                break;
            }
        }

        delete positions[positionId];
        delete positionOwner[positionId];
    }

    // ---- Internal math ----

    function _calculatePnl(Position memory p, uint256 sizeDelta, uint256 price) internal pure returns (int256) {
        // PnL = size * (price - entry) / entry
        int256 priceDiff = int256(price) - int256(p.entryPrice);
        int256 pnl = (int256(sizeDelta) * priceDiff) / int256(p.entryPrice);
        if (!p.isLong) {
            pnl = -pnl;
        }
        return pnl;
    }

    function _fundingPnl(Position memory p, uint256 sizeDelta, bool isLong) internal view returns (int256) {
        int256 cumulative = isLong ? cumulativeFundingLong : cumulativeFundingShort;
        int256 entry = p.fundingEntry;
        int256 diff = cumulative - entry;
        return (int256(sizeDelta) * diff) / int256(WAD);
    }

    function _usdToUsdc(uint256 usdWad) internal view returns (uint256) {
        return usdWad / quoteScale;
    }

    function _usdcToUsd(uint256 usdcAmount) internal view returns (uint256) {
        return usdcAmount * quoteScale;
    }

    // Admin setters
    function setMaxOI(uint256 longCap, uint256 shortCap) external onlyOwner {
        maxOpenInterestLong = longCap;
        maxOpenInterestShort = shortCap;
    }

    function setPositionManager(address pm) external onlyOwner {
        positionManager = pm;
    }

    // C3: cap leverage; must stay <20x (initial margin > maintenance).
    function setMaxLeverage(uint256 _maxLeverage) external onlyOwner {
        require(_maxLeverage >= 1 && _maxLeverage * MAINT_MARGIN_BPS < BPS_DIV, "bad leverage");
        maxLeverage = _maxLeverage;
    }

    // ---- View functions for multiple positions ----

    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    function getUserPositionIds(address user) external view returns (uint256[] memory) {
        return userPositionIds[user];
    }

    function getUserPositionCount(address user) external view returns (uint256) {
        return userPositionIds[user].length;
    }

    /// @notice Get all active positions for a user
    function getUserPositions(address user) external view returns (uint256[] memory positionIds, Position[] memory positionList) {
        uint256[] memory ids = userPositionIds[user];
        uint256 activeCount = 0;
        
        // Count active positions first
        for (uint256 i = 0; i < ids.length; i++) {
            if (positions[ids[i]].size > 0) {
                activeCount++;
            }
        }

        // Allocate arrays
        positionIds = new uint256[](activeCount);
        positionList = new Position[](activeCount);
        
        uint256 index = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            if (positions[ids[i]].size > 0) {
                positionIds[index] = ids[i];
                positionList[index] = positions[ids[i]];
                index++;
            }
        }
    }
}


