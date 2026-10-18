// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// TEST FIXTURE ONLY. A verbatim copy of the non-upgradeable AmxVaultV1 as live on Amero X mainnet
// at 0x13D65e7BD4D76D5f9BFc23068fD992956FC8Dbf8 (git: src/AmxVaultBaseV1.sol + src/AmxVaultV1.sol
// before they became upgradeable), with only the contract names changed (suffix V1) so it can sit
// next to the new code. Used to prove the cutover: funds move out of it, and the new vault
// honours every depositId it already paid. Never deploy this.


import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Shared custody/authorization logic for AmxVaultV1 (native AMX, production) and
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
abstract contract AmxVaultBaseV1 is AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice depositId => already released. One payout per source-chain deposit, ever.
    mapping(bytes32 => bool) public released;
    /// @notice UTC calendar day index => cumulative amount released that day.
    mapping(uint256 => uint256) public releasedInDay;

    uint256 public maxReleasePerTx;
    uint256 public maxReleasePerDay;
    address public treasuryRecoveryAddress;

    event Released(bytes32 indexed depositId, address indexed to, uint256 amount);
    event CapsUpdated(uint256 maxReleasePerTx, uint256 maxReleasePerDay);
    event RecoveryAddressUpdated(address indexed newAddress);
    event EmergencyRecovered(address indexed to, uint256 amount);

    constructor(
        address admin,
        address pauser,
        address initialExecutor,
        uint256 _maxReleasePerTx,
        uint256 _maxReleasePerDay,
        address _treasuryRecoveryAddress
    ) {
        require(admin != address(0), "invalid admin");
        require(pauser != address(0), "invalid pauser");
        require(initialExecutor != address(0), "invalid executor");
        require(_treasuryRecoveryAddress != address(0), "invalid recovery address");
        require(_maxReleasePerTx > 0 && _maxReleasePerTx <= _maxReleasePerDay, "invalid caps");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(EXECUTOR_ROLE, initialExecutor);

        maxReleasePerTx = _maxReleasePerTx;
        maxReleasePerDay = _maxReleasePerDay;
        treasuryRecoveryAddress = _treasuryRecoveryAddress;
    }

    /// @notice Pays out `amount` to `to` for a given source-chain `depositId`. Callable only by
    /// EXECUTOR_ROLE, never twice for the same depositId, bounded by per-tx and rolling
    /// calendar-day caps.
    function release(bytes32 depositId, address to, uint256 amount)
        external
        onlyRole(EXECUTOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        require(to != address(0) && to != address(this), "invalid recipient");
        require(!released[depositId], "already released");
        require(amount > 0 && amount <= maxReleasePerTx, "exceeds per-tx cap");

        uint256 day = block.timestamp / 1 days;
        uint256 newDayTotal = releasedInDay[day] + amount;
        require(newDayTotal <= maxReleasePerDay, "exceeds daily cap");
        require(_availableBalance() >= amount, "insufficient balance");

        // Effects before interaction: nullifier and daily counter are updated before the
        // underlying asset actually moves, so a failed/reverted payout rolls back atomically
        // with no partial state change, and a reentrant call sees released[depositId] already
        // true.
        released[depositId] = true;
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

/// @notice Production vault: holds native AMX on the Amero X chain and releases it via the
/// shared, guarded release() flow in AmxVaultBaseV1. This is the contract intended to hold real
/// funds. For testnet exercises against an ERC20 mock token, use AmxVaultTestERC20 instead —
/// never point real AMX at that contract.
contract AmxVaultV1 is AmxVaultBaseV1 {
    event ToppedUp(address indexed from, uint256 amount);

    constructor(
        address admin,
        address pauser,
        address initialExecutor,
        uint256 maxReleasePerTx_,
        uint256 maxReleasePerDay_,
        address treasuryRecoveryAddress_
    )
        AmxVaultBaseV1(admin, pauser, initialExecutor, maxReleasePerTx_, maxReleasePerDay_, treasuryRecoveryAddress_)
    {}

    receive() external payable {
        emit ToppedUp(msg.sender, msg.value);
    }

    function _availableBalance() internal view override returns (uint256) {
        return address(this).balance;
    }

    function _payOut(address to, uint256 amount) internal override {
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }
}
