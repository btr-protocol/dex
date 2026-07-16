// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IAdmin} from "../interfaces/IAdmin.sol";
import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @title AdminRisk — linked library for emergency freeze/pause + batch (EIP-170 relief).
/// @dev External fns DELEGATECALL'd from Admin; events appear as Admin.
library AdminRisk {
  function freeze(address pool, address token) external {
    IPool(pool).adminFreezeAsset(token);
    emit IAdmin.EmergencyFreeze(pool, token);
  }

  function unfreeze(address pool, address token) external {
    IPool(pool).adminUnfreezeAsset(token);
    emit IAdmin.EmergencyUnfreeze(pool, token);
  }

  function pause(address pool, address token) external {
    IPool(pool).adminPauseAsset(token);
    emit IAdmin.ProtocolPause(pool, token);
  }

  function unpause(address pool, address token) external {
    IPool(pool).adminUnpauseAsset(token);
    emit IAdmin.ProtocolUnpause(pool, token);
  }

  /// @dev Per-leg try/catch: bad leg skipped (never bricks an emergency sweep).
  function batch(address[] calldata pools, address[] calldata tokens, IAdmin.BatchOp op) external {
    uint256 n = pools.length;
    if (n != tokens.length) revert Err.InvalidInput();
    for (uint256 i; i < n; ++i) {
      address p = pools[i];
      address t = tokens[i];
      bool ok;
      if (op == IAdmin.BatchOp.Pause) {
        try IPool(p).adminPauseAsset(t) {
          ok = true;
        } catch {}
      } else if (op == IAdmin.BatchOp.Unpause) {
        try IPool(p).adminUnpauseAsset(t) {
          ok = true;
        } catch {}
      } else if (op == IAdmin.BatchOp.Freeze) {
        try IPool(p).adminFreezeAsset(t) {
          ok = true;
        } catch {}
      } else {
        try IPool(p).adminUnfreezeAsset(t) {
          ok = true;
        } catch {}
      }
      if (ok) emit IAdmin.BatchRiskOp(p, t, uint8(op));
      else emit IAdmin.BatchLegSkipped(p, t);
    }
  }

  function setFlowCooldown(address pool, uint16 cooldownSeconds) external {
    IPool(pool).adminSetFlowCooldown(cooldownSeconds);
    emit IAdmin.FlowCooldownUpdated(pool, 0, cooldownSeconds);
  }

  function setAnchor(address pool, address token, address anchor) external {
    IPool(pool).adminSetAnchor(token, anchor);
    emit IAdmin.AnchorUpdated(pool, token, anchor, 0);
  }
}
