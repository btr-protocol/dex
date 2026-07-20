// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title IRecenterHook - lean after-swap hook for range recentering (Bunni-inspired).
/// @dev Pool calls `afterSwap` with itself as `msg.sender`. Hook may call back into the pool.
interface IRecenterHook {
  function afterSwap(address pool) external;
}
