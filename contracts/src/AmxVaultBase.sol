// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
// OZ 5.5 flags ReentrancyGuard as stateless (its status lives in a fixed namespaced slot and an
// all-zero status already means "not entered"), so the plain contract is proxy-safe and has no
// separate upgradeable variant.
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice The one function a previous vault must expose for this one to honour its payouts.
interface IAmxVaultReleased {
    function released(bytes32 depositId) external view returns (bool);
}

/// @notice Shared custody/authorization logic for AmxVault (native AMX, production) and
/// AmxVaultTestERC20 (ERC20 test token, testnet-only). All the security-critical logic — role
/// scoping, the one-shot-per-depositId nullifier, per-tx/per-day caps, pause asymmetry, and the
/// last-resort recovery sweep — lives here exactly once, so the prod and test contracts can
/// never drift apart on the parts that matter. Subclasses only implement how the underlying
/// asset actually moves (native call{value:} vs SafeERC20).
///
/// Roles:
/// - EXECUTOR_ROLE: the relayer's hot key. Can only call release(). Cannot touch caps, pause,
///   or admin functions — a leaked executor key is bounded by the caps below, not an open drain.
/// - PAUSER_ROLE: a fast-response circuit breaker. Can only pause(), never unpause(). Worst case
///   of this key being careless/compromised is a temporary DoS, never a fund loss or a lock.
/// - DEFAULT_ADMIN_ROLE: governs caps, role rotation, unpause(), and emergencyRecoverAll().
///   Currently intended to be a single EOA (see project plan) with a documented, no-redeploy
///   migration path to a multisig/timelock later via grantRole/revokeRole.
///
/// UPGRADEABLE: subclasses are deployed behind a proxy. Whoever owns that proxy's ProxyAdmin can
/// replace this logic, which bypasses every role and cap above — so it must be a timelock, never
/// a hot key. Rules for any future version (violating these corrupts live state):
///   * Storage is APPEND-ONLY. Never reorder, remove, retype or insert above existing variables;
///     new base variables come out of `__gap`, shrinking it by the same number of slots.
///   * New initialisation goes in a new `reinitializer(n)` function, never in `initialize`.
abstract contract AmxVaultBase is Initializable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuard {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @dev depositId => released by THIS vault. Read through released(), which also consults
    /// legacyVault.
    mapping(bytes32 => bool) private _released;
    /// @notice UTC calendar day index => cumulative amount released that day.
    mapping(uint256 => uint256) public releasedInDay;

    uint256 public maxReleasePerTx;
    uint256 public maxReleasePerDay;
    address public treasuryRecoveryAddress;

    /// @notice The vault this one replaced, or address(0). Every depositId it already paid counts
    /// as released here too, so a purchase can never be paid once by each vault. Set once, at
    /// initialisation, and never changeable.
    address public legacyVault;

    /// @dev Reserved slots so a future version can add base variables without shifting the
    /// storage of subclasses (AmxVaultTestERC20 declares its own).
    uint256[44] private __gap;

    event Released(bytes32 indexed depositId, address indexed to, uint256 amount);
    event CapsUpdated(uint256 maxReleasePerTx, uint256 maxReleasePerDay);
    event RecoveryAddressUpdated(address indexed newAddress);
    event EmergencyRecovered(address indexed to, uint256 amount);
    event LegacyVaultSet(address indexed legacyVault);

    function __AmxVaultBase_init(
        address admin,
        address pauser,
        address initialExecutor,
        uint256 _maxReleasePerTx,
        uint256 _maxReleasePerDay,
        address _treasuryRecoveryAddress,
        address _legacyVault
    ) internal onlyInitializing {
        require(admin != address(0), "invalid admin");
        require(pauser != address(0), "invalid pauser");
        require(initialExecutor != address(0), "invalid executor");
        require(_treasuryRecoveryAddress != address(0), "invalid recovery address");
        require(_maxReleasePerTx > 0 && _maxReleasePerTx <= _maxReleasePerDay, "invalid caps");

        if (_legacyVault != address(0)) {
            require(_legacyVault.code.length > 0, "invalid legacy vault");
            // Reverts unless it really answers released(bytes32), so a wrong address fails here
            // instead of bricking every release() later.
            IAmxVaultReleased(_legacyVault).released(bytes32(0));
        }

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(EXECUTOR_ROLE, initialExecutor);

        maxReleasePerTx = _maxReleasePerTx;
        maxReleasePerDay = _maxReleasePerDay;
        treasuryRecoveryAddress = _treasuryRecoveryAddress;

        legacyVault = _legacyVault;
        if (_legacyVault != address(0)) emit LegacyVaultSet(_legacyVault);
    }

    /// @notice True once `depositId` has been paid out, by this vault or by legacyVault.
    function released(bytes32 depositId) public view returns (bool) {
        if (_released[depositId]) return true;
        address legacy = legacyVault;
        return legacy != address(0) && IAmxVaultReleased(legacy).released(depositId);
    }

    /// @notice Pays out `amount` to `to` for a given source-chain `depositId`. Callable only by
    /// EXECUTOR_ROLE, never twice for the same depositId (across this vault and legacyVault),
    /// bounded by per-tx and rolling calendar-day caps.
    function release(bytes32 depositId, address to, uint256 amount)
        external
        onlyRole(EXECUTOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        require(to != address(0) && to != address(this), "invalid recipient");
        require(!released(depositId), "already released");
        require(amount > 0 && amount <= maxReleasePerTx, "exceeds per-tx cap");

        uint256 day = block.timestamp / 1 days;
        uint256 newDayTotal = releasedInDay[day] + amount;
        require(newDayTotal <= maxReleasePerDay, "exceeds daily cap");
        require(_availableBalance() >= amount, "insufficient balance");

        // Effects before interaction: nullifier and daily counter are updated before the
        // underlying asset actually moves, so a failed/reverted payout rolls back atomically
        // with no partial state change, and a reentrant call sees released(depositId) already
        // true.
        _released[depositId] = true;
        releasedInDay[day] = newDayTotal;

        _payOut(to, amount);

        emit Released(depositId, to, amount);
    }

    function setCaps(uint256 _maxReleasePerTx, uint256 _maxReleasePerDay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_maxReleasePerTx > 0 && _maxReleasePerTx <= _maxReleasePerDay, "invalid caps");
        maxReleasePerTx = _maxReleasePerTx;
        maxReleasePerDay = _maxReleasePerDay;
        emit CapsUpdated(_maxReleasePerTx, _maxReleasePerDay);
    }

    function setRecoveryAddress(address _treasuryRecoveryAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_treasuryRecoveryAddress != address(0), "invalid recovery address");
        treasuryRecoveryAddress = _treasuryRecoveryAddress;
        emit RecoveryAddressUpdated(_treasuryRecoveryAddress);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Last-resort decommission path: sweeps the full available balance to the
    /// pre-declared treasuryRecoveryAddress only (never attacker/admin-arbitrary). Not gated by
    /// whenNotPaused so recovery remains possible even while the vault is paused.
    function emergencyRecoverAll() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        uint256 balance = _availableBalance();
        require(balance > 0, "nothing to recover");

        _payOut(treasuryRecoveryAddress, balance);

        emit EmergencyRecovered(treasuryRecoveryAddress, balance);
    }

    /// @dev Returns the vault's current spendable balance of the underlying asset.
    function _availableBalance() internal view virtual returns (uint256);

    /// @dev Moves `amount` of the underlying asset to `to`. Must revert on failure.
    function _payOut(address to, uint256 amount) internal virtual;
}
