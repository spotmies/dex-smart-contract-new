// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../src/new_perp/src/mocks/MockUSDC.sol";
import "../src/new_perp/src/mocks/MockOracle.sol";
import "../src/new_perp/src/oracle/OracleModule.sol";
import "../src/new_perp/src/core/MarketFactory.sol";
import "../src/new_perp/src/core/Market.sol";
import "../src/new_perp/src/core/Vault.sol";
import "../src/new_perp/src/router/Router.sol";
import "../src/new_perp/src/router/PositionManager.sol";
import "../src/P2PTokenEscrow.sol";
import {UpgradeableDeploy} from "../script/lib/UpgradeableDeploy.sol";
import {UpgradeAuthority} from "../script/lib/UpgradeAuthority.sol";

// ---------------------------------------------------------------------------------------------
// "Version 2" implementations. Each APPENDS one variable and adds a function, which is exactly
// the shape a real upgrade must have (append-only storage). If the live storage layout were
// wrong, `v2Value` would land on top of real state and the preservation tests below would fail.
// ---------------------------------------------------------------------------------------------
contract MarketV2 is Market {
    uint256 public v2Value;

    function version() external pure returns (uint256) {
        return 2;
    }

    function setV2Value(uint256 v) external onlyOwner {
        v2Value = v;
    }
}

contract VaultV2 is Vault {
    uint256 public v2Value;

    function version() external pure returns (uint256) {
        return 2;
    }

    function setV2Value(uint256 v) external onlyOwner {
        v2Value = v;
    }
}

contract P2PTokenEscrowsV2 is P2PTokenEscrows {
    uint256 public v2Value;

    function version() external pure returns (uint256) {
        return 2;
    }

    function setV2Value(uint256 v) external onlyOwner {
        v2Value = v;
    }
}

contract MockP2PToken is ERC20 {
    constructor() ERC20("Tok", "TOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Exposes the script's decision logic so it can be tested without touching the environment.
contract AuthorityHarness is UpgradeAuthority {
    function pick(address explicitAdmin, uint256 delay, address proposer, bool allowDeployer, address deployer)
        external
        returns (address)
    {
        return _pickUpgradeAdmin(explicitAdmin, delay, proposer, allowDeployer, deployer);
    }
}

contract UpgradeabilityTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant DELAY = 2 days;

    MockUSDC usdc;
    MockOracle feed;
    OracleModule oracleModule;
    Router router;
    PositionManager pm;

    UpgradeableDeploy.Perp perp;
    MarketFactory factory;
    Market market;
    Vault vault;

    address upgradeAdmin = makeAddr("upgradeAdmin");
    address attacker = makeAddr("attacker");
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");
    uint256 createdAt;

    function setUp() public {
        usdc = new MockUSDC();
        usdc.mint(lp, 1_000_000 * 1e6);
        usdc.mint(trader, 10_000 * 1e6);
        feed = new MockOracle(2_000 * 1e8);
        oracleModule = new OracleModule();
        router = new Router(address(usdc));
        pm = new PositionManager(address(router));

        perp = UpgradeableDeploy.deployPerp(upgradeAdmin);
        factory = perp.factory;

        createdAt = block.timestamp;
        (address m, address v) =
            factory.createMarket("ETH", address(usdc), address(oracleModule), address(feed), address(pm));
        market = Market(m);
        vault = Vault(v);

        router.setPositionManager(address(pm));
        market.setPositionManager(address(pm));
        pm.setKeeper(address(this), true);

        vm.prank(lp);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(trader);
        usdc.approve(address(router), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers

    function _openLong() internal returns (uint256 positionId) {
        vm.prank(lp);
        vault.deposit(1_000_000 * 1e6, lp);

        vm.prank(trader);
        uint256 reqId = router.createIncreaseRequest(address(market), 0, 1_000 * WAD, 200 * 1e6, true, 2_050 * 1e18, 1e6);
        vm.roll(block.number + 1);
        pm.executeIncrease(reqId);
        positionId = market.getUserPositionIds(trader)[0];
    }

    // =============================================================================================
    // A. Initialisation: the field-initialiser trap
    //    A proxy never runs the implementation's constructor OR field initialisers. These values
    //    used to come from `uint256 public maxLeverage = 10;` etc. and would silently be ZERO.
    // =============================================================================================

    function test_market_defaultsAreSetThroughTheProxy() public view {
        assertEq(market.maxOpenInterestLong(), 10_000_000 * WAD, "OI long cap");
        assertEq(market.maxOpenInterestShort(), 10_000_000 * WAD, "OI short cap");
        assertEq(market.maxLeverage(), 10, "max leverage");
        assertEq(market.nextPositionId(), 1, "position ids start at 1");
        assertEq(market.quoteDecimals(), 6);
        assertEq(market.quoteScale(), 1e12);
        assertEq(market.lastFundingTime(), createdAt, "funding clock starts at creation");
        assertEq(market.baseSymbol(), "ETH");
        assertEq(address(market.quote()), address(usdc));
        assertEq(address(market.vault()), address(vault));
        assertEq(address(market.oracle()), address(oracleModule));
        assertEq(market.priceFeed(), address(feed));
        assertEq(market.owner(), address(this), "factory hands ownership to the creator");
        assertEq(market.positionManager(), address(pm));
    }

    function test_vault_stateIsSetThroughTheProxy() public view {
        assertEq(vault.name(), "Perp LP");
        assertEq(vault.symbol(), "pLP");
        assertEq(address(vault.usdc()), address(usdc));
        assertEq(vault.quoteScale(), 1e12);
        assertEq(vault.market(), address(market));
        assertEq(vault.owner(), address(factory), "the factory owns the vault");
    }

    // =============================================================================================
    // B. Nobody can take over a logic contract or re-run initialisation
    // =============================================================================================

    function test_implementations_cannotBeInitialised() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Market(perp.marketImpl).initialize("X", address(usdc), address(vault), address(oracleModule), address(feed), attacker);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Vault(perp.vaultImpl).initialize(address(usdc), attacker);

        (, address p2pImpl) = UpgradeableDeploy.deployP2P(address(this), upgradeAdmin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        P2PTokenEscrows(p2pImpl).initialize(attacker);
    }

    function test_proxies_cannotBeReinitialised() public {
        vm.prank(attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        market.initialize("X", address(usdc), address(vault), address(oracleModule), address(feed), attacker);

        vm.prank(attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(address(usdc), attacker);

        (P2PTokenEscrows escrow,) = UpgradeableDeploy.deployP2P(address(this), upgradeAdmin);
        vm.prank(attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        escrow.initialize(attacker);
    }

    // =============================================================================================
    // C. Beacon upgrades (Market + Vault)
    // =============================================================================================

    function test_beaconUpgrade_movesEveryMarket_andPreservesLiveState() public {
        uint256 positionId = _openLong();

        // A second market from the same factory, to prove one upgrade moves ALL of them.
        (address market2,) =
            factory.createMarket("BTC", address(usdc), address(oracleModule), address(feed), address(pm));

        // ---- snapshot everything that matters before the upgrade
        Market.Position memory beforePos = market.getPosition(positionId);
        uint256 oiLong = market.oiLong();
        uint256 totalCollateral = market.totalCollateral();
        uint256 nextId = market.nextPositionId();
        uint256 lpShares = vault.balanceOf(lp);
        uint256 supply = vault.totalSupply();
        uint256 vaultBal = usdc.balanceOf(address(vault));
        assertGt(oiLong, 0, "precondition: a real position exists");

        // ---- upgrade both beacons
        address newMarketImpl = address(new MarketV2());
        address newVaultImpl = address(new VaultV2());
        vm.startPrank(upgradeAdmin);
        perp.marketBeacon.upgradeTo(newMarketImpl);
        perp.vaultBeacon.upgradeTo(newVaultImpl);
        vm.stopPrank();

        // ---- the new logic is live on BOTH markets, at the SAME addresses
        assertEq(MarketV2(address(market)).version(), 2);
        assertEq(MarketV2(market2).version(), 2, "second market upgraded by the same call");
        assertEq(VaultV2(address(vault)).version(), 2);

        // ---- every piece of pre-upgrade state is intact
        Market.Position memory afterPos = market.getPosition(positionId);
        assertEq(afterPos.size, beforePos.size, "position size");
        assertEq(afterPos.collateral, beforePos.collateral, "position collateral");
        assertEq(afterPos.entryPrice, beforePos.entryPrice, "entry price");
        assertEq(afterPos.isLong, beforePos.isLong, "side");
        assertEq(market.oiLong(), oiLong, "open interest");
        assertEq(market.totalCollateral(), totalCollateral, "total collateral");
        assertEq(market.nextPositionId(), nextId, "id counter");
        assertEq(market.owner(), address(this), "ownership");
        assertEq(market.maxLeverage(), 10, "config");
        assertEq(vault.balanceOf(lp), lpShares, "LP shares");
        assertEq(vault.totalSupply(), supply, "LP supply");
        assertEq(usdc.balanceOf(address(vault)), vaultBal, "vault funds");

        // ---- the APPENDED variable does not clobber anything
        MarketV2(address(market)).setV2Value(777);
        assertEq(MarketV2(address(market)).v2Value(), 777);
        assertEq(market.oiLong(), oiLong, "oi untouched by the new variable");
        assertEq(market.totalCollateral(), totalCollateral, "collateral untouched by the new variable");
        assertEq(market.nextPositionId(), nextId, "id counter untouched by the new variable");
        assertEq(MarketV2(market2).v2Value(), 0, "other market has its own storage");
    }

    function test_positionOpenedBeforeUpgrade_canBeClosedAfter() public {
        uint256 positionId = _openLong();

        address newMarketImpl = address(new MarketV2());
        vm.prank(upgradeAdmin);
        perp.marketBeacon.upgradeTo(newMarketImpl);

        vm.prank(trader);
        uint256 decReq = router.createDecreaseRequest(address(market), positionId, 1_000 * WAD, true, 1_900 * 1e18, 1e6);
        vm.roll(block.number + 1);
        pm.executeDecrease(decReq);

        assertEq(market.oiLong(), 0, "position fully closed under the new logic");
        assertEq(market.totalCollateral(), 0, "no collateral left reserved");
    }

    function test_onlyTheBeaconOwner_canUpgrade() public {
        address v2 = address(new MarketV2());

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        perp.marketBeacon.upgradeTo(v2);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        perp.vaultBeacon.upgradeTo(v2);

        assertEq(perp.marketBeacon.implementation(), perp.marketImpl, "unchanged");
    }

    function test_marketCreatorAndFactoryOwner_cannotUpgrade() public {
        // address(this) owns the factory AND every market. Upgrade authority is a separate role.
        address v2 = address(new MarketV2());
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        perp.marketBeacon.upgradeTo(v2);
    }

    function test_beacon_rejectsAnImplementationThatIsNotAContract() public {
        vm.prank(upgradeAdmin);
        vm.expectRevert();
        perp.marketBeacon.upgradeTo(address(0xdead));
    }

    function test_factoryRejectsZeroBeacons() public {
        vm.expectRevert(bytes("zero beacon"));
        new MarketFactory(address(0), address(perp.vaultBeacon));
        vm.expectRevert(bytes("zero beacon"));
        new MarketFactory(address(perp.marketBeacon), address(0));
    }

    // =============================================================================================
    // D. P2P escrow (TransparentUpgradeableProxy)
    // =============================================================================================

    function _p2p() internal returns (P2PTokenEscrows escrow, ProxyAdmin admin, MockP2PToken token) {
        (escrow,) = UpgradeableDeploy.deployP2P(address(this), upgradeAdmin);
        admin = ProxyAdmin(address(uint160(uint256(vm.load(address(escrow), UpgradeableDeploy.ADMIN_SLOT)))));
        token = new MockP2PToken();
        escrow.setTokenWhitelist(address(token), true);
    }

    function test_p2p_upgrade_preservesState() public {
        (P2PTokenEscrows escrow, ProxyAdmin admin, MockP2PToken token) = _p2p();

        address seller = makeAddr("seller");
        token.mint(seller, 100 ether);
        vm.prank(seller);
        uint256 listingId = escrow.createListing(token, 50 ether, 2 ether);

        address v2 = address(new P2PTokenEscrowsV2());
        vm.prank(upgradeAdmin);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(escrow)), v2, "");

        // new logic, same address
        assertEq(P2PTokenEscrowsV2(address(escrow)).version(), 2);

        // old state intact
        (address s, IERC20 t, uint256 total, uint256 remaining, uint256 price, bool active,, bool cancelled) =
            escrow.listings(listingId);
        assertEq(s, seller);
        assertEq(address(t), address(token));
        assertEq(total, 50 ether);
        assertEq(remaining, 50 ether);
        assertEq(price, 2 ether);
        assertTrue(active);
        assertFalse(cancelled);
        assertTrue(escrow.whitelistedTokens(address(token)), "whitelist survived");
        assertEq(escrow.owner(), address(this), "whitelist admin unchanged");

        // appended variable does not collide with the arrays / mappings
        P2PTokenEscrowsV2(address(escrow)).setV2Value(42);
        assertEq(P2PTokenEscrowsV2(address(escrow)).v2Value(), 42);
        (, , uint256 total2,,,,,) = escrow.listings(listingId);
        assertEq(total2, 50 ether, "listing untouched by the new variable");
        assertTrue(escrow.whitelistedTokens(address(token)));
    }

    function test_p2p_onlyTheProxyAdminOwner_canUpgrade() public {
        (P2PTokenEscrows escrow, ProxyAdmin admin,) = _p2p();
        address v2 = address(new P2PTokenEscrowsV2());

        assertEq(admin.owner(), upgradeAdmin, "ProxyAdmin is owned by the upgrade admin");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(escrow)), v2, "");

        // The escrow's own owner (whitelist admin) is a different role and cannot upgrade either.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(escrow)), v2, "");
    }

    function test_p2p_proxyCannotBeUpgradedDirectly() public {
        (P2PTokenEscrows escrow,,) = _p2p();
        address v2 = address(new P2PTokenEscrowsV2());

        // Only the ProxyAdmin contract can reach the proxy's upgrade path. Everyone else falls
        // through to the implementation, which has no such function.
        vm.prank(upgradeAdmin);
        (bool ok,) = address(escrow).call(abi.encodeCall(ITransparentUpgradeableProxy.upgradeToAndCall, (v2, "")));
        assertFalse(ok, "even the upgrade admin EOA cannot upgrade the proxy directly");
    }

    // =============================================================================================
    // E. Timelock: the staged single-signer -> multisig path, proven end to end
    // =============================================================================================

    function _timelockedPerp(address proposer) internal returns (TimelockController tl, UpgradeableDeploy.Perp memory p) {
        address[] memory holders = new address[](1);
        holders[0] = proposer;
        tl = new TimelockController(DELAY, holders, holders, address(0));
        p = UpgradeableDeploy.deployPerp(address(tl));
    }

    function test_timelock_gatesAnUpgradeBehindTheDelay() public {
        address signer = makeAddr("signer");
        (TimelockController tl, UpgradeableDeploy.Perp memory p) = _timelockedPerp(signer);

        address v2 = address(new MarketV2());
        bytes memory data = abi.encodeCall(UpgradeableBeacon.upgradeTo, (v2));

        // the beacon owner is the timelock, not any EOA
        assertEq(p.marketBeacon.owner(), address(tl));

        // a stranger cannot even schedule
        vm.prank(attacker);
        vm.expectRevert();
        tl.schedule(address(p.marketBeacon), 0, data, bytes32(0), bytes32("s"), DELAY);

        vm.startPrank(signer);
        tl.schedule(address(p.marketBeacon), 0, data, bytes32(0), bytes32("s"), DELAY);

        // executing before the delay elapses is refused
        vm.expectRevert();
        tl.execute(address(p.marketBeacon), 0, data, bytes32(0), bytes32("s"));
        assertEq(p.marketBeacon.implementation(), p.marketImpl, "not upgraded early");

        vm.warp(vm.getBlockTimestamp() + DELAY); // not block.timestamp: via-IR may reuse the first read
        tl.execute(address(p.marketBeacon), 0, data, bytes32(0), bytes32("s"));
        vm.stopPrank();

        assertEq(p.marketBeacon.implementation(), v2, "upgraded once the delay elapsed");
    }

    function test_timelock_handoverToANewSigner_keepsEveryAddress() public {
        address oldSigner = makeAddr("oldSigner");
        address multisig = makeAddr("multisig");
        (TimelockController tl, UpgradeableDeploy.Perp memory p) = _timelockedPerp(oldSigner);
        address beaconBefore = address(p.marketBeacon);
        address factoryBefore = address(p.factory);

        // Role changes on a self-administered timelock must themselves go through the delay.
        _timelockCall(tl, oldSigner, address(tl), abi.encodeCall(IAccessControl.grantRole, (tl.PROPOSER_ROLE(), multisig)), "g1");
        _timelockCall(tl, oldSigner, address(tl), abi.encodeCall(IAccessControl.grantRole, (tl.EXECUTOR_ROLE(), multisig)), "g2");
        _timelockCall(tl, oldSigner, address(tl), abi.encodeCall(IAccessControl.revokeRole, (tl.PROPOSER_ROLE(), oldSigner)), "r1");
        _timelockCall(tl, multisig, address(tl), abi.encodeCall(IAccessControl.revokeRole, (tl.EXECUTOR_ROLE(), oldSigner)), "r2");

        // the old key is now powerless ...
        vm.prank(oldSigner);
        vm.expectRevert();
        tl.schedule(address(p.marketBeacon), 0, "", bytes32(0), bytes32("x"), DELAY);

        // ... and the new one can upgrade, at the SAME beacon address.
        address v2 = address(new MarketV2());
        _timelockCall(tl, multisig, address(p.marketBeacon), abi.encodeCall(UpgradeableBeacon.upgradeTo, (v2)), "u1");

        assertEq(p.marketBeacon.implementation(), v2);
        assertEq(address(p.marketBeacon), beaconBefore, "beacon address never changed");
        assertEq(address(p.factory), factoryBefore, "factory address never changed");
    }

    function _timelockCall(TimelockController tl, address who, address target, bytes memory data, bytes32 salt) internal {
        vm.startPrank(who);
        tl.schedule(target, 0, data, bytes32(0), salt, DELAY);
        vm.warp(vm.getBlockTimestamp() + DELAY); // not block.timestamp: via-IR may reuse the first read
        tl.execute(target, 0, data, bytes32(0), salt);
        vm.stopPrank();
    }

    // =============================================================================================
    // F. The deploy script's safety guard: the deployer key must never become upgrade owner by omission
    // =============================================================================================

    function test_authority_refusesTheDeployerOnARealNetwork() public {
        AuthorityHarness h = new AuthorityHarness();
        vm.chainId(56); // BSC mainnet
        vm.expectRevert(bytes("Set UPGRADE_ADMIN or UPGRADE_TIMELOCK_DELAY; refusing to make the deployer the upgrade owner"));
        h.pick(address(0), 0, address(0), false, address(0xD3));
    }

    function test_authority_allowsTheDeployerOnlyLocallyOrWhenExplicit() public {
        AuthorityHarness h = new AuthorityHarness();
        address deployer = address(0xD3);

        vm.chainId(31337);
        assertEq(h.pick(address(0), 0, address(0), false, deployer), deployer, "local chain fallback");

        vm.chainId(97); // a testnet: needs the explicit opt-in
        vm.expectRevert();
        h.pick(address(0), 0, address(0), false, deployer);
        assertEq(h.pick(address(0), 0, address(0), true, deployer), deployer, "explicit opt-in");
    }

    function test_authority_usesAnExplicitAdminFirst() public {
        AuthorityHarness h = new AuthorityHarness();
        vm.chainId(56);
        address safe = makeAddr("safe");
        assertEq(h.pick(safe, 1 days, address(0xAA), false, address(0xD3)), safe, "explicit admin wins over timelock");
    }

    function test_authority_deploysATimelockWithTheRequestedDelayAndProposer() public {
        AuthorityHarness h = new AuthorityHarness();
        vm.chainId(56);
        address proposer = makeAddr("proposer");

        address admin = h.pick(address(0), DELAY, proposer, false, address(0xD3));
        TimelockController tl = TimelockController(payable(admin));

        assertEq(tl.getMinDelay(), DELAY);
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), proposer));
        assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), proposer));
        assertFalse(tl.hasRole(tl.PROPOSER_ROLE(), address(0xD3)), "the deployer is NOT a proposer unless named");
        assertFalse(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(h)), "no outside admin can bypass the delay");
    }
}
