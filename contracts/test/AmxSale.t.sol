// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {AmxSale} from "../src/AmxSale.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AmxUpgradeableDeploy} from "../script/lib/AmxUpgradeableDeploy.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal controllable Chainlink-style aggregator for testing staleness/sanity-bound paths.
contract MockAggregatorV3 {
    uint8 public decimals_ = 8;
    int256 public answer = 600 * 1e8; // $600
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;

    constructor() {
        updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return decimals_;
    }

    function setDecimals(uint8 d) external {
        decimals_ = d;
    }

    function setAnswer(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function setRounds(uint80 _roundId, uint80 _answeredInRound) external {
        roundId = _roundId;
        answeredInRound = _answeredInRound;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}

/// @dev 6-decimal ERC20, to verify the decimals-scaling math independently of the 18-decimal
/// MockERC20 used for the primary BSC-realistic tests.
contract SixDecimalToken is ERC20 {
    constructor() ERC20("Six Decimal USD", "SIX") {
        _mint(msg.sender, 1_000_000 * 10 ** 6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AmxSaleTest is Test {
    AmxSale public sale;
    MockERC20 public usdc;
    MockERC20 public usdt;
    MockAggregatorV3 public feed;

    address public admin = makeAddr("admin");
    address public pauser = makeAddr("pauser");
    address public bnbTreasury = makeAddr("bnbTreasury");
    address public usdcTreasury = makeAddr("usdcTreasury");
    address public usdtTreasury = makeAddr("usdtTreasury");
    address public buyer = makeAddr("buyer");
    address public upgradeAdmin = makeAddr("upgradeAdmin");

    /// @dev Shared implementation for the initialize-revert tests, so the only call they make is
    /// the proxy creation that is expected to revert.
    AmxSale public impl;

    uint256 public constant AMX_PRICE = 0.5e18; // $0.50
    uint256 public constant MIN_PURCHASE = 1e18; // $1
    uint256 public constant MAX_PURCHASE = 10_000e18; // $10,000

    event Purchased(
        uint256 indexed purchaseId,
        address indexed buyer,
        address indexed asset,
        uint256 amountIn,
        uint256 amxOut,
        bytes32 depositId
    );

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC");
        usdt = new MockERC20("Tether", "USDT");
        feed = new MockAggregatorV3();

        sale = _deploySale(address(usdc));
        impl = new AmxSale();

        usdc.mint(buyer, 1_000_000 ether);
        usdt.mint(buyer, 1_000_000 ether);
        vm.deal(buyer, 1_000 ether);
    }

    /// @dev A full sale deployment (implementation + proxy) with the standard config, `usdcToken`
    /// as its USDC.
    function _deploySale(address usdcToken) internal returns (AmxSale s) {
        (s,) = AmxUpgradeableDeploy.deploySale(
            AmxUpgradeableDeploy.SaleConfig(
                admin, pauser, usdcToken, address(usdt), address(feed), bnbTreasury, usdcTreasury, usdtTreasury,
                AMX_PRICE, MIN_PURCHASE, MAX_PURCHASE
            ),
            upgradeAdmin
        );
    }

    /// @dev A proxy over the shared implementation, in a single external call.
    function _proxy(bytes memory init) internal returns (AmxSale) {
        return AmxSale(address(new TransparentUpgradeableProxy(address(impl), upgradeAdmin, init)));
    }

    // ==========================================
    //              INITIALIZE
    // ==========================================

    function test_InitializeSetsConfig() public view {
        assertTrue(sale.hasRole(sale.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(sale.hasRole(sale.PAUSER_ROLE(), pauser));
        assertEq(sale.amxPriceUsdE18(), AMX_PRICE);
        assertEq(sale.bnbTreasury(), bnbTreasury);
        assertEq(sale.usdcTreasury(), usdcTreasury);
        assertEq(sale.usdtTreasury(), usdtTreasury);
        // Formerly immutables / a field initialiser: must be set by initialize() behind a proxy.
        assertEq(address(sale.usdc()), address(usdc));
        assertEq(address(sale.usdt()), address(usdt));
        assertEq(sale.usdcDecimals(), 18);
        assertEq(sale.usdtDecimals(), 18);
        assertEq(sale.feedMaxStale(), 1 hours);
    }

    function test_RevertWhen_InitializeZeroAdmin() public {
        bytes memory init = abi.encodeCall(
            AmxSale.initialize,
            (address(0), pauser, address(usdc), address(usdt), address(feed), bnbTreasury, usdcTreasury, usdtTreasury, AMX_PRICE, MIN_PURCHASE, MAX_PURCHASE)
        );
        vm.expectRevert("invalid admin");
        _proxy(init);
    }

    function test_RevertWhen_InitializeInvalidLimits() public {
        bytes memory init = abi.encodeCall(
            AmxSale.initialize,
            (admin, pauser, address(usdc), address(usdt), address(feed), bnbTreasury, usdcTreasury, usdtTreasury, AMX_PRICE, MAX_PURCHASE, MIN_PURCHASE)
        );
        vm.expectRevert("invalid limits");
        _proxy(init);
    }

    // ==========================================
    //             BUY WITH BNB
    // ==========================================

    function test_BuyWithBNB_ComputesCorrectAmxOut() public {
        // 1 BNB at $600, AMX at $0.50 -> $600 / $0.50 = 1200 AMX
        vm.expectEmit(true, true, true, true);
        emit Purchased(1, buyer, address(0), 1 ether, 1200 ether, sale.computeDepositId(1));

        vm.prank(buyer);
        sale.buyWithBNB{value: 1 ether}();

        assertEq(address(sale).balance, 1 ether);
        assertEq(sale.purchaseCount(), 1);
    }

    function test_RevertWhen_BuyWithBNBZeroValue() public {
        vm.prank(buyer);
        vm.expectRevert("zero value");
        sale.buyWithBNB{value: 0}();
    }

    function test_RevertWhen_BuyWithBNBBelowMinPurchase() public {
        // 0.001 BNB at $600 = $0.60, below $1 min
        vm.prank(buyer);
        vm.expectRevert("below min purchase");
        sale.buyWithBNB{value: 0.001 ether}();
    }

    function test_RevertWhen_BuyWithBNBAboveMaxPurchase() public {
        // 20 BNB at $600 = $12,000, above $10,000 max
        vm.prank(buyer);
        vm.expectRevert("exceeds max purchase");
        sale.buyWithBNB{value: 20 ether}();
    }

    function test_RevertWhen_PriceFeedStale() public {
        vm.warp(block.timestamp + 3 hours); // ensure timestamp arithmetic below can't underflow
        feed.setUpdatedAt(block.timestamp - 2 hours); // default max stale is 1 hour
        vm.prank(buyer);
        vm.expectRevert(AmxSale.StalePrice.selector);
        sale.buyWithBNB{value: 1 ether}();
    }

    function test_RevertWhen_PriceFeedAnswerNonPositive() public {
        feed.setAnswer(0);
        vm.prank(buyer);
        vm.expectRevert(AmxSale.InvalidPrice.selector);
        sale.buyWithBNB{value: 1 ether}();
    }

    function test_RevertWhen_PriceFeedRoundIncomplete() public {
        feed.setRounds(5, 3); // answeredInRound < roundId
        vm.prank(buyer);
        vm.expectRevert(AmxSale.IncompleteRound.selector);
        sale.buyWithBNB{value: 1 ether}();
    }

    function test_RevertWhen_PriceFeedOutOfBounds() public {
        vm.prank(admin);
        sale.setFeedConfig(1 hours, 700e18, 900e18); // $600 answer now below the $700 floor

        vm.prank(buyer);
        vm.expectRevert(AmxSale.PriceOutOfBounds.selector);
        sale.buyWithBNB{value: 1 ether}();
    }

    function test_RevertWhen_BuyWhilePaused() public {
        vm.prank(pauser);
        sale.pause();

        vm.prank(buyer);
        vm.expectRevert();
        sale.buyWithBNB{value: 1 ether}();
    }

    // ==========================================
    //            BUY WITH STABLECOIN
    // ==========================================

    function test_BuyWithUSDC_ComputesCorrectAmxOut() public {
        // 100 USDC (18 decimals here, matching real BSC USDC) at $1 = $100 -> 200 AMX
        vm.startPrank(buyer);
        usdc.approve(address(sale), 100 ether);

        vm.expectEmit(true, true, true, true);
        emit Purchased(1, buyer, address(usdc), 100 ether, 200 ether, sale.computeDepositId(1));
        sale.buyWithStable(usdc, 100 ether);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(sale)), 100 ether);
    }

    function test_BuyWithUSDT_ComputesCorrectAmxOut() public {
        vm.startPrank(buyer);
        usdt.approve(address(sale), 50 ether);
        sale.buyWithStable(usdt, 50 ether); // $50 -> 100 AMX
        vm.stopPrank();

        assertEq(usdt.balanceOf(address(sale)), 50 ether);
    }

    function test_RevertWhen_BuyWithUnsupportedToken() public {
        MockERC20 randomToken = new MockERC20("Random", "RND");
        randomToken.mint(buyer, 100 ether);

        vm.startPrank(buyer);
        randomToken.approve(address(sale), 100 ether);
        vm.expectRevert("unsupported token");
        sale.buyWithStable(randomToken, 100 ether);
        vm.stopPrank();
    }

    function test_SixDecimalTokenScalingIsCorrect() public {
        // Verifies the decimals-scaling formula in isolation, independent of the 18-decimal
        // MockERC20 used elsewhere — real BSC USDC/USDT are 18 decimals, but the math must be
        // correct for any decimals count.
        SixDecimalToken sixDec = new SixDecimalToken();
        AmxSale saleWithSixDec = _deploySale(address(sixDec));
        sixDec.mint(buyer, 1000 * 10 ** 6);

        vm.startPrank(buyer);
        sixDec.approve(address(saleWithSixDec), 100 * 10 ** 6); // 100 tokens, 6 decimals
        saleWithSixDec.buyWithStable(IERC20(address(sixDec)), 100 * 10 ** 6);
        vm.stopPrank();

        // 100 tokens @ $1 = $100 -> 200 AMX, regardless of the token's own decimals
        assertEq(saleWithSixDec.purchaseCount(), 1);
    }

    // ==========================================
    //                 QUOTE
    // ==========================================

    function test_QuoteAmxOutMatchesActualPurchase() public view {
        uint256 quoted = sale.quoteAmxOut(address(usdc), 100 ether);
        assertEq(quoted, 200 ether);

        uint256 quotedBnb = sale.quoteAmxOut(address(0), 1 ether);
        assertEq(quotedBnb, 1200 ether);
    }

    // ==========================================
    //               DEPOSIT ID
    // ==========================================

    function test_DepositIdMatchesFormula() public view {
        bytes32 expected = keccak256(abi.encodePacked(address(sale), uint256(1)));
        assertEq(sale.computeDepositId(1), expected);
    }

    function test_DepositIdIsUniquePerPurchase() public {
        vm.startPrank(buyer);
        sale.buyWithBNB{value: 1 ether}();
        sale.buyWithBNB{value: 1 ether}();
        vm.stopPrank();

        assertTrue(sale.computeDepositId(1) != sale.computeDepositId(2));
    }

    function test_DepositIdIsBoundToThisContractAddress() public {
        // Same purchaseId, a different (hypothetical) AmxSale deployment must produce a
        // different depositId — this is exactly what prevents a future redeploy's purchases
        // from ever colliding with this one's in AmxVault's nullifier mapping.
        AmxSale otherSale = _deploySale(address(usdc));
        assertTrue(sale.computeDepositId(1) != otherSale.computeDepositId(1));
    }

    // ==========================================
    //                 SWEEP
    // ==========================================

    function test_SweepBNBSendsFullBalanceToTreasury() public {
        vm.prank(buyer);
        sale.buyWithBNB{value: 2 ether}();

        sale.sweepBNB(); // permissionless
        assertEq(bnbTreasury.balance, 2 ether);
        assertEq(address(sale).balance, 0);
    }

    function test_SweepIsPermissionless() public {
        vm.prank(buyer);
        sale.buyWithBNB{value: 1 ether}();

        vm.prank(makeAddr("randomStranger"));
        sale.sweepBNB();
        assertEq(bnbTreasury.balance, 1 ether);
    }

    function test_RevertWhen_SweepWithZeroBalance() public {
        vm.expectRevert("nothing to sweep");
        sale.sweepBNB();
    }

    function test_SweepTokenSendsToCorrectTreasury() public {
        vm.startPrank(buyer);
        usdc.approve(address(sale), 100 ether);
        sale.buyWithStable(usdc, 100 ether);
        usdt.approve(address(sale), 50 ether);
        sale.buyWithStable(usdt, 50 ether);
        vm.stopPrank();

        sale.sweepToken(usdc);
        sale.sweepToken(usdt);

        assertEq(usdc.balanceOf(usdcTreasury), 100 ether);
        assertEq(usdt.balanceOf(usdtTreasury), 50 ether);
    }

    // ==========================================
    //         AUTHORIZATION BOUNDARIES
    // ==========================================

    function test_RevertWhen_NonAdminSetsPrice() public {
        vm.expectRevert();
        sale.setPrice(1e18);
    }

    function test_RevertWhen_NonAdminSetsLimits() public {
        vm.expectRevert();
        sale.setPurchaseLimits(1e18, 100e18);
    }

    function test_RevertWhen_NonAdminSetsTreasuryAddresses() public {
        vm.expectRevert();
        sale.setTreasuryAddresses(buyer, buyer, buyer);
    }

    function test_RevertWhen_NonAdminSetsPriceFeed() public {
        vm.expectRevert();
        sale.setPriceFeed(address(feed));
    }

    function test_RevertWhen_NonPauserPauses() public {
        vm.expectRevert();
        sale.pause();
    }

    function test_RevertWhen_PauserUnpauses() public {
        vm.prank(pauser);
        sale.pause();

        vm.prank(pauser);
        vm.expectRevert();
        sale.unpause();
    }

    function test_AdminCanUnpause() public {
        vm.prank(pauser);
        sale.pause();

        vm.prank(admin);
        sale.unpause();

        vm.prank(buyer);
        sale.buyWithBNB{value: 1 ether}();
        assertEq(sale.purchaseCount(), 1);
    }

    // ==========================================
    //              ADMIN UPDATES
    // ==========================================

    function test_AdminCanUpdatePrice() public {
        vm.prank(admin);
        sale.setPrice(1e18); // $1/AMX

        assertEq(sale.quoteAmxOut(address(usdc), 100 ether), 100 ether); // $100 / $1 = 100 AMX
    }

    function test_AdminCanUpdateTreasuryAddresses() public {
        address newBnbTreasury = makeAddr("newBnbTreasury");
        vm.prank(admin);
        sale.setTreasuryAddresses(newBnbTreasury, usdcTreasury, usdtTreasury);

        vm.prank(buyer);
        sale.buyWithBNB{value: 1 ether}();
        sale.sweepBNB();

        assertEq(newBnbTreasury.balance, 1 ether);
        assertEq(bnbTreasury.balance, 0);
    }
}
