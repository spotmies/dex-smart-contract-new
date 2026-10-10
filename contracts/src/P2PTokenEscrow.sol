// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// Stateless in OZ 5.5 (fixed namespaced slot, zero status == not entered): proxy-safe as-is.
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @dev UPGRADEABLE behind a TransparentUpgradeableProxy.
///
/// Rules for any future version - violating these corrupts live escrow state:
///   * Storage is APPEND-ONLY. Never reorder, remove, retype or insert above existing variables
///     (`listings`, `purchases` and every mapping below are live user funds' bookkeeping).
///   * The `Listing` / `Purchase` structs are stored in arrays: never add, remove or reorder
///     struct fields, which would shift every existing element's layout.
///   * New initialisation goes in a new `reinitializer(n)` function, never in `initialize`.
contract P2PTokenEscrows is Initializable, ReentrancyGuard, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    struct Listing {
        address seller;
        IERC20 token;
        uint256 totalAmount;
        uint256 remaining;
        uint256 pricePerToken;
        bool active;
        uint256 createdAt;
        bool cancelled; // L2: set on deliberate delist so a refund can't silently re-activate it
    }

    enum PurchaseStatus { Proposed, Locked, Released, Refunded, Cancelled, Disputed }

    struct Purchase {
        uint256 listingId;
        address buyer;
        uint256 quantity;
        uint256 agreedPricePerToken;
        PurchaseStatus status;
        address seller;
        uint256 createdAt;
    }

    Listing[] public listings;
    // Mapping to track listings created by a seller
    mapping(address => uint256[]) public sellerListings;

    Purchase[] public purchases;
    // Mapping to track purchases received by a listing (for the seller to see)
    mapping(uint256 => uint256[]) public listingPurchases;
    
    // Mapping to track purchases that have been completed/released for a buyer ("My Orders" - completed)
    mapping(address => uint256[]) public buyerPurchases;

    // Mapping to track purchases proposed by a buyer (offers / proposed)
    mapping(address => uint256[]) public buyerProposedPurchases;

    // MAPPING: Stores allowed tokens (True = Allowed, False = Not Allowed)
    mapping(address => bool) public whitelistedTokens;

    // Mapping to track purchases completed/released for a seller ("My Sales" - completed)
    mapping(address => uint256[]) public sellerCompletedPurchases;


    event ListingCreated(uint256 indexed listingId, address indexed seller, address token, uint256 totalAmount, uint256 pricePerToken);
    event PurchaseProposed(uint256 indexed purchaseId, uint256 indexed listingId, address indexed buyer, uint256 quantity, uint256 pricePerToken);
    event PurchaseLocked(uint256 indexed purchaseId, uint256 indexed listingId, address indexed seller, uint256 quantity);
    event PurchaseReleased(uint256 indexed purchaseId, uint256 indexed listingId, address indexed buyer, uint256 quantity);
    event ListingUpdatedRemaining(uint256 indexed listingId, uint256 remaining);
    event PurchaseRefunded(uint256 indexed purchaseId, uint256 indexed listingId, address indexed seller, uint256 quantity);
    event PurchaseCancelled(uint256 indexed purchaseId);
    event ListingCancelled(uint256 indexed listingId);
    event PurchaseDisputed(uint256 indexed purchaseId, address indexed disputer);
    event TokenWhitelistUpdated(address indexed token, bool isWhitelisted);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Lock the bare implementation so it can never be initialised and owned directly.
        _disableInitializers();
    }

    /// @param _owner admin who manages the token whitelist (previously `msg.sender`).
    function initialize(address _owner) external initializer {
        __Ownable_init(_owner);
    }

    // ==========================================
    //                 MODIFIERS
    // ==========================================
    modifier validListing(uint256 _listingId) {
        require(_listingId < listings.length, "Invalid listing ID");
        _;
    }

    modifier validPurchase(uint256 _purchaseId) {
        require(_purchaseId < purchases.length, "Invalid purchase ID");
        _;
    }

    modifier onlyListingSeller(uint256 _listingId) {
        require(listings[_listingId].seller == msg.sender, "Only seller can perform this");
        _;
    }

    // ==========================================
    //                 CORE FUNCTIONS
    // ==========================================

    function setTokenWhitelist(address token, bool status) external onlyOwner {
        require(token != address(0), "Invalid token address");
        whitelistedTokens[token] = status;
        emit TokenWhitelistUpdated(token, status);
    }

    function createListing(IERC20 token, uint256 totalAmount, uint256 pricePerToken) external returns (uint256) {
        require(totalAmount > 0, "Amount(qty of token) must be > 0");
        require(pricePerToken > 0, "Price must be > 0"); // L2: reject zero-price listings
        require(address(token) != address(0), "Invalid token address");

        // Whitelist Check
        require(whitelistedTokens[address(token)], "Token not whitelisted by Admin");

        // Check if the seller actually has the tokens in their wallet
        require(token.balanceOf(msg.sender) >= totalAmount, "Insufficient token balance");

        Listing memory l = Listing({
            seller: msg.sender,
            token: token,
            totalAmount: totalAmount,
            remaining: totalAmount,
            pricePerToken: pricePerToken,
            active: true,
            createdAt: block.timestamp,
            cancelled: false
        });

        listings.push(l);
        uint256 listingId = listings.length - 1;
        sellerListings[msg.sender].push(listingId);

        emit ListingCreated(listingId, msg.sender, address(token), totalAmount, pricePerToken);
        return listingId;
    }

    function proposePurchase(uint256 listingId, uint256 quantity, uint256 agreedPricePerToken) 
        external 
        validListing(listingId) 
        returns (uint256) 
    {
        Listing memory l = listings[listingId]; 

        require(l.active, "Listing not active");
        require(quantity > 0 && quantity <= l.remaining, "Invalid quantity");

        Purchase memory p = Purchase({
            listingId: listingId,
            buyer: msg.sender,
            quantity: quantity,
            agreedPricePerToken: agreedPricePerToken,
            status: PurchaseStatus.Proposed,
            seller: l.seller,
            createdAt: block.timestamp
        });

        purchases.push(p);
        uint256 purchaseId = purchases.length - 1;
        
        // Update Mappings
        listingPurchases[listingId].push(purchaseId);          // For Seller: all offers on this listing
        buyerProposedPurchases[msg.sender].push(purchaseId);   // For Buyer: proposals/offers they made

        emit PurchaseProposed(purchaseId, listingId, msg.sender, quantity, agreedPricePerToken);
        return purchaseId;
    }

    function lockPurchase(uint256 purchaseId) 
        external 
        nonReentrant 
        validPurchase(purchaseId) 
    {
        Purchase storage p = purchases[purchaseId];
        Listing storage l = listings[p.listingId];

        require(p.status == PurchaseStatus.Proposed, "Purchase not proposed");
        require(msg.sender == l.seller, "Only seller can lock");
        require(l.remaining >= p.quantity, "Not enough tokens remaining");
        require(l.active, "Listing inactive");

        // Seller moves tokens into escrow (contract)
        l.token.safeTransferFrom(msg.sender, address(this), p.quantity);

        p.status = PurchaseStatus.Locked;
        l.remaining -= p.quantity;

        // NOTE: we do NOT add to buyerPurchases here because buyerPurchases is intended
        // to track purchases once they are released/completed. If you want to show "active"
        // or "escrowed" for buyer, the frontend can fetch purchase details and filter by status == Locked.

        emit PurchaseLocked(purchaseId, p.listingId, msg.sender, p.quantity);
        emit ListingUpdatedRemaining(p.listingId, l.remaining);
    }

    function releasePurchase(uint256 purchaseId) 
        external 
        nonReentrant 
        onlyOwner 
        validPurchase(purchaseId) 
    {
        Purchase storage p = purchases[purchaseId];
        Listing storage l = listings[p.listingId];
        
        require(p.status == PurchaseStatus.Locked || p.status == PurchaseStatus.Disputed, "Not releasable");

        p.status = PurchaseStatus.Released;

        // Record this as a completed purchase for the buyer
        buyerPurchases[p.buyer].push(purchaseId);

        // Record this as a completed sale for the seller
        sellerCompletedPurchases[l.seller].push(purchaseId);

        // Transfer tokens to buyer
        l.token.safeTransfer(p.buyer, p.quantity);

        emit PurchaseReleased(purchaseId, p.listingId, p.buyer, p.quantity);
    }


    function refundPurchase(uint256 purchaseId) 
        external 
        nonReentrant 
        onlyOwner 
        validPurchase(purchaseId) 
    {
        Purchase storage p = purchases[purchaseId];
        Listing storage l = listings[p.listingId];

        require(p.status == PurchaseStatus.Locked || p.status == PurchaseStatus.Disputed, "Not refundable");

        p.status = PurchaseStatus.Refunded;
        l.token.safeTransfer(l.seller, p.quantity);

        l.remaining += p.quantity;
        // L2: restore availability only if the seller didn't deliberately delist it.
        l.active = !l.cancelled;

        emit PurchaseRefunded(purchaseId, p.listingId, l.seller, p.quantity);
        emit ListingUpdatedRemaining(p.listingId, l.remaining);
    }

    function cancelProposedPurchase(uint256 purchaseId) 
        external 
        validPurchase(purchaseId) 
    {
        Purchase storage p = purchases[purchaseId];
        require(p.status == PurchaseStatus.Proposed, "Not cancellable");
        require(msg.sender == p.buyer || msg.sender == p.seller, "Only buyer or seller");

        p.status = PurchaseStatus.Cancelled;
        emit PurchaseCancelled(purchaseId);
    }

    function cancelListing(uint256 listingId) 
        external 
        validListing(listingId) 
        onlyListingSeller(listingId) 
    {
        require(listings[listingId].active, "Listing already inactive");
        listings[listingId].active = false;
        listings[listingId].cancelled = true; // L2: mark as deliberately delisted
        emit ListingCancelled(listingId);
    }

    function raiseDispute(uint256 purchaseId) 
        external 
        validPurchase(purchaseId) 
    {
        Purchase storage p = purchases[purchaseId];

        // 1. Only the Buyer or Seller involved in this specific purchase can dispute
        require(msg.sender == p.buyer || msg.sender == p.seller, "Not party to transaction");

        // 2. Can only dispute if funds are currently in Escrow (Locked)
        // We cannot dispute 'Proposed' (just cancel it) or 'Released' (funds are gone)
        require(p.status == PurchaseStatus.Locked, "Status must be Locked");

        // 3. Update Status
        p.status = PurchaseStatus.Disputed;

        emit PurchaseDisputed(purchaseId, msg.sender);
    }

    // ==========================================
    //           VIEW / HELPER FUNCTIONS
    // ==========================================

    // 1. Pagination: Essential so we don't run out of gas returning 10,000 listings
    function getPaginatedListings(uint256 offset, uint256 limit) external view returns (Listing[] memory result) {
        uint256 total = listings.length;
        if (offset >= total) return new Listing[](0);

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 resultSize = end - offset;
        result = new Listing[](resultSize);

        for (uint256 i = 0; i < resultSize; i++) {
            result[i] = listings[offset + i];
        }
    }

    // 2. Batch Fetch: Allows Frontend to send an array of IDs and get all Structs in 1 call
    // Useful for showing "My Orders" or "Offers on my Listing"
    function getBatchPurchases(uint256[] calldata purchaseIds) external view returns (Purchase[] memory batch) {
        batch = new Purchase[](purchaseIds.length);
        for(uint256 i=0; i < purchaseIds.length; i++) {
            if (purchaseIds[i] < purchases.length) {
                batch[i] = purchases[purchaseIds[i]];
            }
        }
    }

    // 2 --> 3 are linked should be called from F.E for "My Orders dashboard..."

    // 3. Buyer Helper: Returns IDs of purchases completed/released for a specific address
    function getBuyerPurchaseIds(address buyer) external view returns (uint256[] memory) {
        return buyerPurchases[buyer];
    }

    // 3b. Buyer Helper: Returns IDs of purchases proposed by a specific address (offers)
    function getBuyerProposedPurchaseIds(address buyer) external view returns (uint256[] memory) {
        return buyerProposedPurchases[buyer];
    }
    
    // 4. Seller Helper: Returns IDs of purchases (offers) on a specific listing
    function getListingPurchaseIds(uint256 listingId) external view returns (uint256[] memory) {
        return listingPurchases[listingId];
    }

    // Keep original for backward compatibility or simple use cases
    function getListings() external view returns (Listing[] memory) {
        return listings;
    }

    function getListingById(uint256 id) public view validListing(id) returns (Listing memory) {
        return listings[id];
    }

    // 5. Seller Helper: Batch fetch Listings (just like we do for Purchases)
    // Use this with getSellerListings() to show the "My Dashboard" page
    function getBatchListings(uint256[] calldata listingIds) external view returns (Listing[] memory batch) {
        batch = new Listing[](listingIds.length);
        for(uint256 i = 0; i < listingIds.length; i++) {
            if (listingIds[i] < listings.length) {
                batch[i] = listings[listingIds[i]];
            }
        }
    }

    // 6. Seller Helper: Returns listing IDs created by a seller
    function getSellerListings(address seller) external view returns (uint256[] memory) {
        return sellerListings[seller];
    }
    
    // Seller Helper: Returns IDs of purchases completed/released for a specific seller
    function getSellerCompletedPurchaseIds(address seller) external view returns (uint256[] memory) {
        return sellerCompletedPurchases[seller];
    }

}
