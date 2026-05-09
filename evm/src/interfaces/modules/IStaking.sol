// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IStaking — governance + LP staking
interface IStaking {
    /// @dev lpStaked + totalLPStaked live in IPool.PoolStorage (shared w/ Distributor).
    struct StakingStorage {
        mapping(address user => uint256 amount) govStaked;
        uint256 totalGovStaked;
        mapping(address user => uint48 unlockTime) govUnlockTime;
        mapping(address lpToken => address sLPToken) sLPTokens;
        mapping(address user => mapping(address lpToken => uint48)) lpUnlockTime;
        address[] lpTokens;
        mapping(address owner => address delegate) delegateOf;
    }

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

    function stakeGov(uint256 amount) external;
    function unstakeGov(uint256 amount) external;

    /// @notice Configure LP staking (deploys sLP via CREATE3)
    function updateStakingConfig(address lpToken, bytes32 salt) external;
    function stakeLP(address lpToken, uint256 amount) external;
    function unstakeLP(address lpToken, uint256 amount) external;

    function pause() external;
    function unpause() external;
    function requestStakeLockDurationUpdate(uint48 newLockDuration) external;
    function executeStakeLockDurationUpdate() external;

    function getStakedGov(address user) external view returns (uint256);
    function getStakedLP(address user, address lpToken) external view returns (uint256);
    /// @param lpToken address(0) for governance token
    function getUnlockTime(address user, address lpToken) external view returns (uint48);
    function getSLPToken(address lpToken) external view returns (address);
    function getTotalLPStaked(address lpToken) external view returns (uint256);
    /// @param underlying gov token or LP asset
    function getStakedBalance(address user, address underlying) external view returns (uint256);
    function getTotalStaked(address underlying) external view returns (uint256);

    /// @param to address(0) to clear
    function delegateVoting(address to) external;
    function getDelegateOf(address owner) external view returns (address delegate);
}
