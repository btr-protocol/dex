// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IAdmin} from "../interfaces/IAdmin.sol";
import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Timelock as TL} from "@btr-shared/Timelock.sol";

/// @title AdminHooks — linked library for per-asset hook timelock setters (EIP-170 relief).
/// @dev External fns are DELEGATECALL'd from Admin; events appear as Admin.
library AdminHooks {
  bytes32 private constant OP_UPDATE_HOOK = keccak256("UPDATE_HOOK");

  function request(
    mapping(bytes32 => uint96) storage pendingOps,
    mapping(bytes32 => bytes) storage pendingData,
    address pool,
    address token,
    address hook,
    uint32 flags
  ) external {
    if (hook == address(0)) revert Err.ZeroAddr();
    // HOOK-EOA: a hook is fund-custody (deploys reserves to Venus). An EOA / not-yet-deployed
    // target could wedge invested funds (no recall code) — require real contract code.
    if (hook.code.length == 0) revert Err.NotCode();
    bytes32 key = keccak256(abi.encode(pool, OP_UPDATE_HOOK, token));
    // HOOK-TIMELOCK: a hook takes fund custody (deploys reserves to Venus), so install rides the
    // HIGH tier used for owner/custody ops (bridge/treasury), not the LOW listing/fees tier.
    uint48 delay = SC.govDelay(SC.HIGH_TIMELOCK);
    pendingOps[key] = TL.pack(delay, SC.GRACE_PERIOD);
    pendingData[key] = abi.encode(token, hook, flags);
    uint48 eta;
    unchecked {
      eta = uint48(block.timestamp) + delay;
    }
    emit IAdmin.TimelockRequested(pool, key, uint8(IPool.OpType.UPDATE_HOOK), eta);
  }

  function execute(
    mapping(bytes32 => uint96) storage pendingOps,
    mapping(bytes32 => bytes) storage pendingData,
    address pool,
    address token
  ) external {
    bytes32 key = keccak256(abi.encode(pool, OP_UPDATE_HOOK, token));
    TL.validate(pendingOps[key]);
    bytes memory data = pendingData[key];
    delete pendingOps[key];
    delete pendingData[key];
    (address storedToken, address hook, uint32 flags) = abi.decode(data, (address, address, uint32));
    if (storedToken != token) revert Err.InvalidInput();
    IPool(pool).adminSetAssetHook(token, hook, flags);
    emit IAdmin.AssetHookUpdated(pool, token, hook, flags);
  }

  function cancel(
    mapping(bytes32 => uint96) storage pendingOps,
    mapping(bytes32 => bytes) storage pendingData,
    address pool,
    address token
  ) external {
    bytes32 key = keccak256(abi.encode(pool, OP_UPDATE_HOOK, token));
    if (pendingOps[key] == 0) revert Err.InvalidState();
    delete pendingOps[key];
    delete pendingData[key];
    emit IAdmin.TimelockCancelled(pool, key, uint8(IPool.OpType.UPDATE_HOOK));
  }

  function clear(address pool, address token) external {
    IPool(pool).adminClearAssetHook(token);
    emit IAdmin.AssetHookUpdated(pool, token, address(0), 0);
  }
}
