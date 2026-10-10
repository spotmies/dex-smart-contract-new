// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {P2PTokenEscrows} from "../src/P2PTokenEscrow.sol"; 
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UpgradeableDeploy} from "../script/lib/UpgradeableDeploy.sol";

// 1. Create a Mock Token to test transfers
contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "mUSDT") {
        _mint(msg.sender, 1000000 * 10**18);
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

// 2. The Main Test Contract
contract P2PTokenEscrowsTest is Test {
    P2PTokenEscrows public escrow;
    MockUSDT public token;

    address public owner;
    address public seller;
    address public buyer;
    address public stranger;

    // Events to check
    event PurchaseLocked(uint256 indexed purchaseId, uint256 indexed listingId, address indexed seller, uint256 quantity);
    event PurchaseReleased(uint256 indexed purchaseId, uint256 indexed listingId, address indexed buyer, uint256 quantity);
    event TokenWhitelistUpdated(address indexed token, bool isWhitelisted);

    function setUp() public {
        // Setup accounts
        owner = address(this);
        seller = makeAddr("seller");
        buyer = makeAddr("buyer");
        stranger = makeAddr("stranger");

        // Deploy contracts
        token = new MockUSDT();
        (escrow, ) = UpgradeableDeploy.deployP2P(owner, address(this));

        // Whitelist the token
        escrow.setTokenWhitelist(address(token), true);

        // Fund the seller with tokens (1 Million)
        token.mint(seller, 1_000_000 * 10**18);
        
        // Seller must approve the escrow contract to move funds
        vm.prank(seller);
        token.approve(address(escrow), type(uint256).max);
    }


    function test_CreateListing() public {
        vm.prank(seller);
        uint256 listingId = escrow.createListing(IERC20(address(token)), 500 * 10**18, 1 * 10**18);

        P2PTokenEscrows.Listing memory l = escrow.getListingById(listingId);
        
        assertEq(l.seller, seller);
        assertEq(l.totalAmount, 500 * 10**18);
        assertTrue(l.active);
    }

    function test_RevertCreateListing_ZeroAmount() public {
        vm.prank(seller);
        vm.expectRevert("Amount(qty of token) must be > 0");
        escrow.createListing(IERC20(address(token)), 0, 1);
    }

    function test_RevertCreateListing_NotWhitelisted() public {
        escrow.setTokenWhitelist(address(token), false);
        vm.prank(seller);
        vm.expectRevert("Token not whitelisted by Admin");
        escrow.createListing(IERC20(address(token)), 100 * 10**18, 1);
    }


    function test_RevertCreateListing_InsufficientBalance() public {

        vm.prank(seller);
        vm.expectRevert("Insufficient token balance");
        escrow.createListing(IERC20(address(token)), 2_000_000 * 10**18, 1);
    }

    function test_FullPurchaseFlow() public {
        // 1. Seller creates listing
        vm.prank(seller);
        uint256 listingId = escrow.createListing(IERC20(address(token)), 100 * 10**18, 10);

        // 2. Buyer proposes purchase (Buying 50 tokens)
        vm.prank(buyer);
        uint256 purchaseId = escrow.proposePurchase(listingId, 50 * 10**18, 10);

        // Verify purchase created
        (uint256 pid, address pBuyer, uint256 pQty, , P2PTokenEscrows.PurchaseStatus status, ,) = escrow.purchases(purchaseId);
        assertEq(pid, listingId);
        assertEq(pBuyer, buyer);
        assertLe(pQty, 100 * 10**18);
        assertEq(uint(status), uint(P2PTokenEscrows.PurchaseStatus.Proposed));

        // 3. Seller Locks tokens
        vm.prank(seller);
        vm.expectEmit(true, true, true, true);
        emit PurchaseLocked(purchaseId, listingId, seller, 50 * 10**18);
        escrow.lockPurchase(purchaseId);

        // Check Balances: 
        // Start: 1,000,000. Locked: 50. Remaining: 999,950.
        assertEq(token.balanceOf(seller), 999_950 * 10**18); 
        assertEq(token.balanceOf(address(escrow)), 50 * 10**18);

        // 4. Owner Releases
        vm.expectEmit(true, true, true, true);
        emit PurchaseReleased(purchaseId, listingId, buyer, 50 * 10**18);
        escrow.releasePurchase(purchaseId);

        // Check Final Balances
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(buyer), 50 * 10**18);
    }


    function test_Dispute_SellerClaimsNoFiat_OwnerRefunds() public {
        vm.prank(seller);
        uint256 listingId = escrow.createListing(IERC20(address(token)), 100 * 10**18, 10);
        
        vm.prank(buyer);
        uint256 purchaseId = escrow.proposePurchase(listingId, 50 * 10**18, 10);
        
        vm.prank(seller);
        escrow.lockPurchase(purchaseId);

        vm.prank(seller);
        escrow.raiseDispute(purchaseId);

        // Owner refunds
        escrow.refundPurchase(purchaseId);

        // Seller should have their original 1,000,000 back
        assertEq(token.balanceOf(seller), 1_000_000 * 10**18); 
        assertEq(token.balanceOf(buyer), 0);              
    }

    function test_Dispute_BuyerClaimsFiatSent_OwnerReleases() public {
        vm.prank(seller);
        uint256 listingId = escrow.createListing(IERC20(address(token)), 100 * 10**18, 10);
        
        vm.prank(buyer);
        uint256 purchaseId = escrow.proposePurchase(listingId, 50 * 10**18, 10);
        
        vm.prank(seller);
        escrow.lockPurchase(purchaseId);

        vm.prank(buyer);
        escrow.raiseDispute(purchaseId);

        // Owner releases
        escrow.releasePurchase(purchaseId);

        assertEq(token.balanceOf(buyer), 50 * 10**18);     
        // Seller stays at 999,950
        assertEq(token.balanceOf(seller), 999_950 * 10**18);   
    }

    function test_RevertLock_IfNotSeller() public {
        vm.prank(seller);
        uint256 listingId = escrow.createListing(IERC20(address(token)), 100, 10);
        
        vm.prank(buyer);
        uint256 purchaseId = escrow.proposePurchase(listingId, 50, 10);

        vm.prank(stranger);
        vm.expectRevert("Only seller can lock");
        escrow.lockPurchase(purchaseId);
    }

    function test_RevertRelease_IfNotOwner() public {
        vm.prank(seller);
        uint256 listingId = escrow.createListing(IERC20(address(token)), 100, 10);
        vm.prank(buyer);
        uint256 purchaseId = escrow.proposePurchase(listingId, 50, 10);
        vm.prank(seller);
        escrow.lockPurchase(purchaseId);

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, seller)
        );
        escrow.releasePurchase(purchaseId);
    }

   
    function test_RefundFlow() public {
        vm.prank(seller);
        uint256 listingId = escrow.createListing(IERC20(address(token)), 100 * 10**18, 10);
        vm.prank(buyer);
        uint256 purchaseId = escrow.proposePurchase(listingId, 50 * 10**18, 10);
        vm.prank(seller);
        escrow.lockPurchase(purchaseId);

        escrow.refundPurchase(purchaseId);

        // Back to 1,000,000
        assertEq(token.balanceOf(seller), 1_000_000 * 10**18); 
        assertEq(token.balanceOf(buyer), 0);
        
        P2PTokenEscrows.Listing memory l = escrow.getListingById(listingId);
        assertEq(l.remaining, 100 * 10**18);
    }


    function testFuzz_CreateListing(uint256 amount, uint256 price) public {
        // Bound amount to seller's actual balance
        amount = bound(amount, 1, token.balanceOf(seller));
        price = bound(price, 1, 1000 * 10**18);

        vm.prank(seller);
        uint256 listingId = escrow.createListing(IERC20(address(token)), amount, price);

        P2PTokenEscrows.Listing memory l = escrow.getListingById(listingId);
        assertEq(l.totalAmount, amount);
        assertEq(l.remaining, amount);
        assertEq(l.pricePerToken, price);
        assertTrue(l.active);
    }

    function testFuzz_ProposeAndLock(uint256 listAmount, uint256 buyAmount) public {
        // Bound listAmount to seller's actual balance
        uint256 sellerBalance = token.balanceOf(seller);
        listAmount = bound(listAmount, 100, sellerBalance); 
        uint256 price = 1 ether;

        vm.prank(seller);
        uint256 listingId = escrow.createListing(IERC20(address(token)), listAmount, price);

        buyAmount = bound(buyAmount, 1, listAmount);

        vm.prank(buyer);
        uint256 purchaseId = escrow.proposePurchase(listingId, buyAmount, price);

        vm.prank(seller);
        escrow.lockPurchase(purchaseId);

        P2PTokenEscrows.Listing memory l = escrow.getListingById(listingId);
        assertEq(l.remaining, listAmount - buyAmount);
        assertEq(token.balanceOf(address(escrow)), buyAmount);
    }

    function testFuzz_Pagination(uint8 numListings, uint256 offset, uint256 limit) public {
        numListings = uint8(bound(numListings, 1, 20));
        
        vm.startPrank(seller);
        for(uint i=0; i < numListings; i++) {
             escrow.createListing(IERC20(address(token)), 100 * 10**18, 1);
        }
        vm.stopPrank();

        offset = bound(offset, 0, numListings + 5); 
        limit = bound(limit, 0, 50);

        P2PTokenEscrows.Listing[] memory results = escrow.getPaginatedListings(offset, limit);

        if (offset >= numListings) {
            assertEq(results.length, 0);
        } else {
            uint256 remainingItems = numListings - offset;
            uint256 expectedLen = limit < remainingItems ? limit : remainingItems;
            assertEq(results.length, expectedLen);
        }
    }
}