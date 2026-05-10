// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IStaking
/// @notice Singleton Staking contract — Phase 42H.B.3b.
/// @dev Staking is no longer a Diamond module. It is a standalone contract that holds
///      its own state keyed by (pool, ...) and calls Pool's restricted setters via
///      standard external calls. All public functions take `address pool` as the first arg.
interface IStaking {
    // ── governance staking ──
    function stakeGov(address pool, uint256 amount) external;
    function unstakeGov(address pool, uint256 amount) external;

    // ── LP staking ──
    function configurePool(address pool, address gov, address sGov, uint16 cooldownSeconds) external;
    function setFlowCooldown(address pool, uint16 cooldownSeconds) external;
    function updateStakingConfig(address pool, address lpToken, bytes32 salt) external;
    function stakeLP(address pool, address lpToken, uint256 amount) external;
    function unstakeLP(address pool, address lpToken, uint256 amount) external;

    // ── delegation (advisory) ──
    function delegateVoting(address pool, address to) external;

    // ── pause + lock duration ──
    function pause(address pool) external;
    function unpause(address pool) external;
    function requestStakeLockDurationUpdate(address pool, uint48 newLockDuration) external;
    function executeStakeLockDurationUpdate(address pool) external;

    // ── views ──
    function getStakedGov(address pool, address user) external view returns (uint256);
    function getStakedLP(address pool, address user, address lpToken) external view returns (uint256);
    function getUnlockTime(address pool, address user, address lpToken) external view returns (uint48);
    function getSLPToken(address pool, address lpToken) external view returns (address);
    function getTotalLPStaked(address pool, address lpToken) external view returns (uint256);
    function getStakedBalance(address pool, address user, address underlying) external view returns (uint256);
    function getTotalStaked(address pool, address underlying) external view returns (uint256);
    function getDelegateOf(address pool, address owner_) external view returns (address);
    function getStakeLockDuration(address pool) external view returns (uint48);
    function isStakingPaused(address pool) external view returns (bool);
    function getLPTokens(address pool) external view returns (address[] memory);

    // ── events (pool-keyed) ──
    event GovStaked(address indexed pool, address indexed user, uint256 amount, uint48 unlockTime);
    event GovUnstaked(address indexed pool, address indexed user, uint256 amount);
    event LPStaked(address indexed pool, address indexed user, address indexed lpToken, uint256 amount, uint48 unlockTime);
    event LPUnstaked(address indexed pool, address indexed user, address indexed lpToken, uint256 amount);
    event StakingConfigured(address indexed pool, address indexed lpToken, address indexed sLPToken, bytes32 salt);
    event PoolConfigured(address indexed pool, address gov, address sGov, uint16 cooldownSeconds);
    event StakingPaused(address indexed pool, address indexed by);
    event StakingUnpaused(address indexed pool, address indexed by);
    event StakingConfigUpdateRequested(address indexed pool, uint48 newLockDuration, uint48 executableAt);
    event StakingConfigUpdated(address indexed pool, uint48 newLockDuration);
    event DelegateSet(address indexed pool, address indexed owner, address oldDelegate, address newDelegate);
}
