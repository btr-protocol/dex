// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPoolHooks} from "../interfaces/IPoolHooks.sol";

/// @title BasePoolHook — no-op lean IPoolHooks base for adapters.
abstract contract BasePoolHook is IPoolHooks {
  function preOutflow(address, address, address, uint256) external virtual override {}

  function postInflow(address, address, address, uint256, uint256) external virtual override {}
}
