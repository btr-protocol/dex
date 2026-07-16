// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @notice Immutable authorization wiring exposed by the delegated PoolAux dispatcher.
interface IPoolAuxWiring {
  function AC() external view returns (address);
  function admin() external view returns (address);
  function flash() external view returns (address);
}
