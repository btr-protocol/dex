// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IErrors} from "../IErrors.sol";

/// @title IStaking
/// @notice Interface for governance token and LP staking operations
interface IStakingV1 is IErrors {
    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE STRUCT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Staking-specific storage (governance token staking, LP staking, timelocks)
    struct StakingStorage {
        // Governance token staking balances (explicit tracking to avoid recursion)
        mapping(address user => uint256 amount) govStaked;  // User's staked governance tokens
        uint256 totalGovStaked;                             // Total staked governance tokens

        // Governance token staking timelocks
        mapping(address user => uint48 unlockTime) govUnlockTime;

        // LP staking registry and timelocks
        mapping(address lpToken => address sLPToken) sLPTokens;  // LP -> sLP token mapping
        mapping(address user => mapping(address lpToken => uint48)) lpUnlockTime;
        address[] lpTokens;  // List of registered LP tokens
        // NB: lpStaked and totalLPStaked are in IPoolV1.PoolStorage (shared with Distributor for rewards)

        // Delegation: metadata-only for off-chain (not used on-chain)
        mapping(address owner => address delegate) delegateOf;  // 0 = self, read by off-chain snapshot
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event GovStaked(address indexed user, uint256 amount, uint48 unlockTime);
    event GovUnstaked(address indexed user, uint256 amount);
    event LPStaked(address indexed user, address indexed lpToken, uint256 amount, uint48 unlockTime);
    event LPUnstaked(address indexed user, address indexed lpToken, uint256 amount);
    event StakingConfigured(address indexed lpToken, address indexed sLPToken, bytes32 salt);
    event StakingPaused(address indexed by);
    event StakingUnpaused(address indexed by);
    event StakeLockDurationUpdated(uint48 newDuration);
    event StakingConfigUpdateRequested(uint48 newLockDuration, uint48 executableAt);
    event StakingConfigUpdated(uint48 newLockDuration);
    event DelegateSet(address indexed owner, address indexed oldDelegate, address indexed newDelegate);

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════
    // All errors inherited from IErrors - see IErrors.sol for details

    // ═══════════════════════════════════════════════════════════════════════════
    // GOVERNANCE TOKEN STAKING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Stake governance tokens to receive staked governance tokens
    /// @param amount Amount of governance tokens to stake
    function stakeGov(uint256 amount) external;

    /// @notice Unstake staked governance tokens to receive governance tokens (after timelock)
    /// @param amount Amount of staked governance tokens to unstake
    function unstakeGov(uint256 amount) external;

    // ═══════════════════════════════════════════════════════════════════════════
    // LP STAKING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Configure LP token for staking (deploys sLP token via CREATE3)
    /// @param lpToken LP token address to enable staking for
    /// @param salt CREATE3 salt for deterministic sLP deployment
    function updateStakingConfig(address lpToken, bytes32 salt) external;

    /// @notice Stake LP tokens to receive sLP
    /// @param lpToken LP token address
    /// @param amount Amount of LP to stake
    function stakeLP(address lpToken, uint256 amount) external;

    /// @notice Unstake sLP to free up LP tokens (after timelock)
    /// @param lpToken LP token address
    /// @param amount Amount to unstake
    function unstakeLP(address lpToken, uint256 amount) external;


    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Pause all staking operations (emergency only)
    function pause() external;

    /// @notice Unpause staking operations
    function unpause() external;

    /// @notice Request update to stake lock duration (timelocked)
    /// @param newLockDuration New stake lock duration
    function requestStakeLockDurationUpdate(uint48 newLockDuration) external;

    /// @notice Execute stake lock duration update after timelock expires
    function executeStakeLockDurationUpdate() external;

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEWS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Get staked governance token balance for user
    /// @param user User address
    /// @return Staked governance token balance
    function getStakedGov(address user) external view returns (uint256);

    /// @notice Get staked LP balance for user
    /// @param user User address
    /// @param lpToken LP token address
    /// @return Staked LP balance
    function getStakedLP(address user, address lpToken) external view returns (uint256);

    /// @notice Get unlock time for user
    /// @param user User address
    /// @param lpToken LP token address (address(0) for governance token)
    /// @return Unlock timestamp
    function getUnlockTime(address user, address lpToken) external view returns (uint48);

    /// @notice Get sLP token address for LP asset
    /// @param lpToken LP token address
    /// @return sLP token address (address(0) if not configured)
    function getSLPToken(address lpToken) external view returns (address);

    /// @notice Get total staked LP for an asset
    /// @param lpToken LP token address
    /// @return Total staked amount
    function getTotalLPStaked(address lpToken) external view returns (uint256);

    /// @notice Get staked balance for a user (used by StakedToken.balanceOf)
    /// @param user User address
    /// @param underlying Underlying token (governance token or LP asset)
    /// @return Staked balance
    function getStakedBalance(address user, address underlying) external view returns (uint256);

    /// @notice Get total staked supply (used by StakedToken.totalSupply)
    /// @param underlying Underlying token (governance token or LP asset)
    /// @return Total staked supply
    function getTotalStaked(address underlying) external view returns (uint256);

    // ═══════════════════════════════════════════════════════════════════════════
    // DELEGATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Delegate voting power to another address
    /// @param to Address to delegate to (address(0) to clear delegation)
    function delegateVoting(address to) external;

    /// @notice Get current delegate for an owner (metadata-only for off-chain)
    /// @param owner Owner address
    /// @return delegate Delegate address (address(0) if not delegating)
    function getDelegateOf(address owner) external view returns (address delegate);
}
