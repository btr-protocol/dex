// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPoolFactory -Pool clone factory + token registry (Phase 42H.B.3d)
/// @dev Each pool is an EIP-1167 minimal-proxy clone of the singleton Pool impl.
interface IPoolFactory {
    struct PoolParams { address baseToken; address[] tokens; bytes initdata; }

    function referencePool() external view returns (address);
    function protocolDeployer() external view returns (address);
    function allPools(uint256) external view returns (address);
    function isPool(address) external view returns (bool);
    function officialPools(uint256) external view returns (address);
    function isOfficialPool(address) external view returns (bool);
    function tokenToPools(address, uint256) external view returns (address);
    function poolToTokens(address, uint256) external view returns (address);
    function tokenInPool(address, address) external view returns (bool);
    function poolBaseTokens(address) external view returns (address);

    function getPoolTokens(address pool) external view returns (address[] memory);
    function getPoolsForToken(address token) external view returns (address[] memory);
    function getCommonPools(address tokenA, address tokenB) external view returns (address[] memory);
    function getOfficialPoolsCount() external view returns (uint256);
    function getAllPoolsCount() external view returns (uint256);
    function checkRoute(address tokenA, address tokenB)
        external view returns (bool hasDirectRoute, address[] memory commonPools);

    event PoolCreated(address indexed pool, address indexed creator, address baseToken, bool official);
    event TokensRegistered(address indexed pool, address[] tokens);
    event ReferencePoolUpgradeRequested(address indexed oldImplementation, address indexed newImplementation, uint256 executeAt);
    event ReferencePoolUpgraded(address indexed oldImplementation, address indexed newImplementation);
    event ProtocolDeployerUpdated(address indexed oldDeployer, address indexed newDeployer);
}
