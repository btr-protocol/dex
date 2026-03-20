// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title IPoolProxyFactoryV1
/// @notice Interface for pool proxy factory with token registry
interface IPoolProxyFactoryV1 {
    // ========== STRUCTS ==========

    /// @notice Pool creation parameters
    struct PoolParams {
        address baseToken;       // Pool's base token (price anchor)
        address[] tokens;        // Initial tokens to support
        bytes initdata;          // Initialization calldata
    }

    // ========== STATE ==========

    /// @notice Reference implementation for pool proxies
    function referencePool() external view returns (address);

    /// @notice Protocol deployer (their pools are auto-whitelisted)
    function protocolDeployer() external view returns (address);

    /// @notice All deployed pools
    function allPools(uint256) external view returns (address);

    /// @notice Check if address is a pool
    function isPool(address) external view returns (bool);

    /// @notice Official protocol pools
    function officialPools(uint256) external view returns (address);

    /// @notice Check if pool is official
    function isOfficialPool(address) external view returns (bool);

    /// @notice Get pools that support a token
    function tokenToPools(address, uint256) external view returns (address);

    /// @notice Get tokens supported by a pool
    function poolToTokens(address, uint256) external view returns (address);

    /// @notice Check if pool has token
    function tokenInPool(address, address) external view returns (bool);

    /// @notice Get pool's base token
    function poolBaseTokens(address) external view returns (address);

    // ========== VIEW FUNCTIONS ==========

    /// @notice Get all tokens supported by a pool
    function getPoolTokens(address pool) external view returns (address[] memory);

    /// @notice Get all pools that support a specific token
    function getPoolsForToken(address token) external view returns (address[] memory);

    /// @notice Get pools that support both tokens (direct swap candidates)
    function getCommonPools(address tokenA, address tokenB) external view returns (address[] memory);

    /// @notice Get official pools count
    function getOfficialPoolsCount() external view returns (uint256);

    /// @notice Get all pools count
    function getAllPoolsCount() external view returns (uint256);

    /// @notice Check if a route exists between two tokens
    function checkRoute(address tokenA, address tokenB)
        external
        view
        returns (bool hasDirectRoute, address[] memory commonPools);

    // ========== EVENTS ==========

    event PoolCreated(
        address indexed pool,
        address indexed creator,
        address baseToken,
        bool official
    );

    event TokensRegistered(address indexed pool, address[] tokens);

    event ReferencePoolUpgradeRequested(
        address indexed oldImplementation,
        address indexed newImplementation,
        uint256 executeAt
    );

    event ReferencePoolUpgraded(
        address indexed oldImplementation,
        address indexed newImplementation
    );

    event ProtocolDeployerUpdated(address indexed oldDeployer, address indexed newDeployer);
}
