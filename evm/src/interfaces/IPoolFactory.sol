// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title IPoolFactory -Pool beacon-proxy factory + token registry
/// @dev Each pool is a deterministic ERC1967 beacon proxy reading its impl from the shared
///      Solady UpgradeableBeacon (`beacon()`); `referencePool()` mirrors the current impl.
interface IPoolFactory {
  struct PoolParams {
    address baseToken;
    address[] tokens;
    bytes initdata;
  }

  function referencePool() external view returns (address);
  function beacon() external view returns (address);
  function protocolDeployer() external view returns (address);
  function allPools(uint256) external view returns (address);
  function isPool(address) external view returns (bool);
  function officialPools(uint256) external view returns (address);
  function isOfficialPool(address) external view returns (bool);
  function tokenToPools(address, uint256) external view returns (address);
  function poolToTokens(address, uint256) external view returns (address);
  function tokenInPool(address, address) external view returns (bool);
  function poolBaseTokens(address) external view returns (address);

  function registerTokens(address[] calldata tokens) external;
  function setPoolBaseToken(address newBase) external;
  function deregisterPool(address pool) external;

  function getPoolTokens(address pool) external view returns (address[] memory);
  function getPoolsForToken(address token) external view returns (address[] memory);
  function getCommonPools(address tokenA, address tokenB) external view returns (address[] memory);
  function getOfficialPoolsCount() external view returns (uint256);
  function getAllPoolsCount() external view returns (uint256);
  function checkRoute(address tokenA, address tokenB)
    external
    view
    returns (bool hasDirectRoute, address[] memory commonPools);

  event PoolCreated(
    address indexed pool, address indexed creator, address baseToken, bool official
  );
  event TokensRegistered(address indexed pool, address[] tokens);
  event PoolBaseTokenUpdated(address indexed pool, address indexed newBase);
  event PoolDeregistered(address indexed pool);
  event ReferencePoolUpgradeRequested(
    address indexed oldImplementation, address indexed newImplementation, uint256 executeAt
  );
  event ReferencePoolUpgraded(address indexed oldImplementation, address indexed newImplementation);
  event ReferencePoolUpgradeCancelled(
    address indexed canceller, address indexed cancelledImplementation
  );
  event ProtocolDeployerUpdated(address indexed oldDeployer, address indexed newDeployer);
}
