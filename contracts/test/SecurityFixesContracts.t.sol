// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "../src/new_perp/src/core/Vault.sol";
import "../src/new_perp/src/oracle/OracleModule.sol";
import "../src/limit_order/LimitOrderProtocol.sol";
import "../src/P2PTokenEscrow.sol";
import "../src/MockERC20.sol";
import {UpgradeableDeploy} from "../script/lib/UpgradeableDeploy.sol";

// --- helpers -------------------------------------------------------------

/// @notice Chainlink-like mock whose every field can be set, to exercise M2 checks.
contract ConfigurableOracle {
    uint80 public roundId;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public answeredInRound;

    function set(uint80 _roundId, int256 _answer, uint256 _updatedAt, uint80 _answeredInRound) external {
        roundId = _roundId;
        answer = _answer;
        updatedAt = _updatedAt;
        answeredInRound = _answeredInRound;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, 0, updatedAt, answeredInRound);
    }
}

/// @notice Minimal EIP-1271 smart-contract wallet for the L1 contract-wallet test.
contract SmartWallet {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes memory sig) external view returns (bytes4) {
        return ECDSA.recover(hash, sig) == owner ? MAGIC : bytes4(0xffffffff);
    }

    function approveToken(address token, address spender, uint256 amount) external {
        MockERC20(token).approve(spender, amount);
    }
}

// --- tests ---------------------------------------------------------------

contract SecurityFixesContractsTest is Test {
    // ===================== H2: Vault first-depositor inflation =====================

    function _deployVault18() internal returns (Vault v, MockERC20 t) {
        t = new MockERC20("Quote18", "Q18"); // 18 decimals → quoteScale == 1 (BSC case)
        v = UpgradeableDeploy.deployVault(address(t), address(this), address(this));
    }

    function testH2_FirstDepositLocksDeadShares() public {
        (Vault v, MockERC20 t) = _deployVault18();
        address lp = address(0xA11CE);
        t.mint(lp, 1000 ether);

        vm.startPrank(lp);
        t.approve(address(v), 1000 ether);
        v.deposit(1000 ether, lp);
        vm.stopPrank();

        assertEq(v.balanceOf(address(0xdead)), 1e3, "dead shares locked");
        assertEq(v.balanceOf(lp), 1000 ether - 1e3, "depositor gets amount minus dead shares");
    }

    function testH2_RejectsDustFirstDeposit() public {
        (Vault v, MockERC20 t) = _deployVault18();
        address lp = address(0xA11CE);
        t.mint(lp, 1000);

        vm.startPrank(lp);
        t.approve(address(v), 1000);
        // minted = 1000 * quoteScale(1) = 1000, not > MINIMUM_LIQUIDITY(1000) → revert
        vm.expectRevert(bytes("first deposit too small"));
        v.deposit(1000, lp);
        vm.stopPrank();
    }

    function testH2_InflationAttackDoesNotGriefVictim() public {
        (Vault v, MockERC20 t) = _deployVault18();
        address attacker = address(0xBAD);
        address victim = address(0x1CE);

        t.mint(attacker, 1_000_000 ether);
        t.mint(victim, 100 ether);

        // Attacker makes a tiny first deposit, then donates a large amount directly to the vault
        // to inflate the share price (classic ERC4626 first-depositor attack).
        vm.startPrank(attacker);
        t.approve(address(v), type(uint256).max);
        v.deposit(1001, attacker); // minted 1001, locks 1000 dead, attacker keeps 1 share
        t.transfer(address(v), 1_000 ether); // donation
        vm.stopPrank();

        // Victim deposits a real amount; without dead shares their shares would round to 0.
        vm.startPrank(victim);
        t.approve(address(v), type(uint256).max);
        v.deposit(100 ether, victim);
        vm.stopPrank();

        assertGt(v.balanceOf(victim), 0, "victim must receive non-zero shares (not griefed)");
    }

    // ===================== M2: OracleModule hardening =====================

    function _module() internal returns (OracleModule m, ConfigurableOracle feed) {
        m = new OracleModule(); // test contract is owner
        feed = new ConfigurableOracle();
    }

    function testM2_HealthyPriceScaledTo1e18() public {
        (OracleModule m, ConfigurableOracle feed) = _module();
        feed.set(5, 2000e8, block.timestamp, 5); // $2000, 8-dec
        assertEq(m.getPrice(address(feed)), 2000e18, "scaled 8->18 dec");
    }

    function testM2_RejectsNonPositiveAnswer() public {
        (OracleModule m, ConfigurableOracle feed) = _module();
        feed.set(5, 0, block.timestamp, 5);
        vm.expectRevert(OracleModule.InvalidPrice.selector);
        m.getPrice(address(feed));
    }

    function testM2_RejectsIncompleteRound() public {
        (OracleModule m, ConfigurableOracle feed) = _module();
        // answeredInRound < roundId → stale/stuck round
        feed.set(6, 2000e8, block.timestamp, 5);
        vm.expectRevert(OracleModule.IncompleteRound.selector);
        m.getPrice(address(feed));
    }

    function testM2_RejectsZeroUpdatedAt() public {
        (OracleModule m, ConfigurableOracle feed) = _module();
        feed.set(5, 2000e8, 0, 5);
        vm.expectRevert(OracleModule.IncompleteRound.selector);
        m.getPrice(address(feed));
    }

    function testM2_RejectsStalePrice() public {
        (OracleModule m, ConfigurableOracle feed) = _module();
        vm.warp(10 hours);
        feed.set(5, 2000e8, 1 hours, 5); // ~9h old, default window is 1h
        vm.expectRevert(OracleModule.StalePrice.selector);
        m.getPrice(address(feed));
    }

    function testM2_PerFeedStalenessOverride() public {
        (OracleModule m, ConfigurableOracle feed) = _module();
        vm.warp(10 hours);
        feed.set(5, 2000e8, 8 hours, 5); // 2h old
        m.setFeedMaxStale(address(feed), 3 hours);
        assertEq(m.getPrice(address(feed)), 2000e18, "within per-feed window");
    }

    function testM2_RejectsOutOfBounds() public {
        (OracleModule m, ConfigurableOracle feed) = _module();
        feed.set(5, 5000e8, block.timestamp, 5); // $5000
        m.setFeedBounds(address(feed), 1000e18, 4000e18); // cap $4000
        vm.expectRevert(OracleModule.PriceOutOfBounds.selector);
        m.getPrice(address(feed));
    }

    // ===================== L1: limit-order rounding + EIP-1271 =====================

    function _domainDigest(LimitOrderProtocol proto, LimitOrderProtocol.Order memory order)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Order(address makerAsset,address takerAsset,address maker,uint256 makingAmount,uint256 takingAmount,uint256 salt,uint256 deadline)"),
                order.makerAsset,
                order.takerAsset,
                order.maker,
                order.makingAmount,
                order.takingAmount,
                order.salt,
                order.deadline
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("LimitOrderProtocol")),
                keccak256(bytes("1")),
                block.chainid,
                address(proto)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function testL1_TakerAmountRoundsUpFavoringMaker() public {
        LimitOrderProtocol proto = new LimitOrderProtocol();
        MockERC20 mkr = new MockERC20("Maker", "MKR");
        MockERC20 tkr = new MockERC20("Taker", "TKR");

        uint256 makerPk = 0xA11CE;
        address maker = vm.addr(makerPk);
        address taker = address(0x7);

        mkr.mint(maker, 100 ether);
        tkr.mint(taker, 100 ether);
        vm.prank(maker);
        mkr.approve(address(proto), type(uint256).max);
        vm.prank(taker);
        tkr.approve(address(proto), type(uint256).max);

        // making=3, taking=2: a fill of 1 → floor(2*1/3)=0 (old, taker pays nothing),
        // ceil = 1 (maker-favoring). Assert taker actually pays 1.
        LimitOrderProtocol.Order memory order = LimitOrderProtocol.Order({
            makerAsset: address(mkr),
            takerAsset: address(tkr),
            maker: maker,
            makingAmount: 3,
            takingAmount: 2,
            salt: 1,
            deadline: block.timestamp + 1 hours
        });
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(makerPk, _domainDigest(proto, order));
        bytes memory sig = abi.encodePacked(r, s, vv);

        uint256 takerBefore = tkr.balanceOf(taker);
        vm.prank(taker);
        proto.fillOrder(order, sig, 1);
        assertEq(takerBefore - tkr.balanceOf(taker), 1, "taker amount rounded up to 1 (favors maker)");
        assertEq(mkr.balanceOf(taker), 1, "taker received 1 maker asset");
    }

    function testL1_EIP1271ContractWalletCanPlaceOrder() public {
        LimitOrderProtocol proto = new LimitOrderProtocol();
        MockERC20 mkr = new MockERC20("Maker", "MKR");
        MockERC20 tkr = new MockERC20("Taker", "TKR");

        uint256 ownerPk = 0xBEEF;
        address walletOwner = vm.addr(ownerPk);
        SmartWallet wallet = new SmartWallet(walletOwner);
        address taker = address(0x8);

        mkr.mint(address(wallet), 100 ether);
        tkr.mint(taker, 200 ether); // full fill owes takingAmount (200)
        wallet.approveToken(address(mkr), address(proto), type(uint256).max);
        vm.prank(taker);
        tkr.approve(address(proto), type(uint256).max);

        LimitOrderProtocol.Order memory order = LimitOrderProtocol.Order({
            makerAsset: address(mkr),
            takerAsset: address(tkr),
            maker: address(wallet), // maker is a contract
            makingAmount: 100 ether,
            takingAmount: 200 ether,
            salt: 1,
            deadline: block.timestamp + 1 hours
        });
        // The wallet's owner signs; SignatureChecker routes to wallet.isValidSignature (EIP-1271).
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(ownerPk, _domainDigest(proto, order));
        bytes memory sig = abi.encodePacked(r, s, vv);

        vm.prank(taker);
        proto.fillOrder(order, sig, 100 ether);

        assertEq(mkr.balanceOf(taker), 100 ether, "taker received maker asset from contract-wallet order");
        assertEq(tkr.balanceOf(address(wallet)), 200 ether, "contract wallet received taker asset");
    }

    // ===================== L2: P2P listing edge cases =====================

    function _escrowWithToken() internal returns (P2PTokenEscrows e, MockERC20 t) {
        (e, ) = UpgradeableDeploy.deployP2P(address(this), address(this)); // test contract is owner
        t = new MockERC20("Tok", "TOK");
        e.setTokenWhitelist(address(t), true);
    }

    function testL2_RejectsZeroPriceListing() public {
        (P2PTokenEscrows e, MockERC20 t) = _escrowWithToken();
        address seller = address(0x5E11E1);
        t.mint(seller, 100 ether);
        vm.prank(seller);
        vm.expectRevert(bytes("Price must be > 0"));
        e.createListing(IERC20(address(t)), 100 ether, 0);
    }

    function testL2_RefundDoesNotReactivateCancelledListing() public {
        (P2PTokenEscrows e, MockERC20 t) = _escrowWithToken();
        address seller = address(0x5E11E1);
        address buyer = address(0xB);
        t.mint(seller, 100 ether);

        vm.prank(seller);
        uint256 listingId = e.createListing(IERC20(address(t)), 100 ether, 10);

        vm.prank(buyer);
        uint256 purchaseId = e.proposePurchase(listingId, 50 ether, 10);

        vm.startPrank(seller);
        t.approve(address(e), type(uint256).max);
        e.lockPurchase(purchaseId);
        e.cancelListing(listingId); // seller deliberately delists
        vm.stopPrank();

        // Owner refunds the locked purchase.
        e.refundPurchase(purchaseId);

        (, , , , , bool active, , bool cancelled) = e.listings(listingId);
        assertTrue(cancelled, "listing marked cancelled");
        assertFalse(active, "refund must NOT re-activate a cancelled listing");
    }

    function testL2_RefundReactivatesNonCancelledListing() public {
        (P2PTokenEscrows e, MockERC20 t) = _escrowWithToken();
        address seller = address(0x5E11E1);
        address buyer = address(0xB);
        t.mint(seller, 100 ether);

        vm.prank(seller);
        uint256 listingId = e.createListing(IERC20(address(t)), 100 ether, 10);

        vm.prank(buyer);
        uint256 purchaseId = e.proposePurchase(listingId, 50 ether, 10);

        vm.startPrank(seller);
        t.approve(address(e), type(uint256).max);
        e.lockPurchase(purchaseId);
        e.raiseDispute(purchaseId);
        vm.stopPrank();

        e.refundPurchase(purchaseId);

        (, , , , , bool active, , bool cancelled) = e.listings(listingId);
        assertFalse(cancelled, "listing not cancelled");
        assertTrue(active, "non-cancelled listing stays active after refund");
    }
}
