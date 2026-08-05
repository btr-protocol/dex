// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Constants as SC} from "@btr-shared/Constants.sol";
import {Timelock as TL} from "@btr-shared/Timelock.sol";
import {Err} from "@btr-shared/Errors.sol";
import {ICdp} from "../interfaces/ICdp.sol";

/// @dev CDP LOW_TIMELOCK queue + tighten predicates.
library CdpTimelock {
  uint8 internal constant OP_SET_TIER = 1;
  uint8 internal constant OP_SET_CEILING = 2;
  uint8 internal constant OP_ENABLE = 3;
  uint8 internal constant OP_SET_HAIRCUTS = 4;
  uint8 internal constant OP_SET_BASIS = 5;
  uint8 internal constant OP_SET_SYNTH_CEILING = 6;
  uint8 internal constant OP_LIST = 7;

  function isTierTighten(
    uint16 oLtv,
    uint16 oLt,
    uint16 oBonus,
    uint16 nLtv,
    uint16 nLt,
    uint16 nBonus
  ) internal pure returns (bool) {
    return nLtv <= oLtv && nLt <= oLt && nBonus <= oBonus;
  }

  function isHaircutTighten(uint16 oHl, uint16 oHo, uint16 nHl, uint16 nHo)
    internal
    pure
    returns (bool)
  {
    return nHl >= oHl && nHo >= oHo;
  }

  function isBasisTighten(uint256 oBasis, uint256 nBasis) internal pure returns (bool) {
    uint256 o = oBasis == 0 ? SC.WAD : oBasis;
    uint256 n = nBasis == 0 ? SC.WAD : nBasis;
    if (o > SC.WAD) o = SC.WAD;
    if (n > SC.WAD) n = SC.WAD;
    return n <= o;
  }

  function isCeilingTighten(uint256 oldC, uint256 newC) internal pure returns (bool) {
    if (oldC == 0) return newC != 0;
    if (newC == 0) return false;
    return newC <= oldC;
  }

  function key(uint8 op, address target) internal pure returns (bytes32) {
    return keccak256(abi.encode(op, target));
  }

  function keyHaircuts() internal pure returns (bytes32) {
    return keccak256(abi.encode(OP_SET_HAIRCUTS));
  }

  function queue(
    mapping(bytes32 => uint96) storage pendingOps,
    mapping(bytes32 => bytes) storage pendingData,
    bytes32 id,
    uint8 opType,
    address target,
    bytes memory data
  ) internal {
    uint96 prev = pendingOps[id];
    if (prev != 0) revert Err.PendingTimelock(uint48(prev >> 48));
    uint48 delay = SC.govDelay(SC.LOW_TIMELOCK);
    pendingOps[id] = TL.pack(delay, SC.GRACE_PERIOD);
    pendingData[id] = data;
    uint48 eta;
    unchecked {
      eta = uint48(block.timestamp) + delay;
    }
    emit ICdp.TimelockRequested(id, opType, target, eta);
  }

  function queueOp(
    mapping(bytes32 => uint96) storage pendingOps,
    mapping(bytes32 => bytes) storage pendingData,
    uint8 opType,
    address target,
    bytes memory data
  ) internal {
    queue(pendingOps, pendingData, key(opType, target), opType, target, data);
  }

  function consume(
    mapping(bytes32 => uint96) storage pendingOps,
    mapping(bytes32 => bytes) storage pendingData,
    bytes32 id,
    uint8 opType,
    address target
  ) internal returns (bytes memory data) {
    TL.validate(pendingOps[id]);
    data = pendingData[id];
    delete pendingOps[id];
    delete pendingData[id];
    emit ICdp.TimelockExecuted(id, opType, target);
  }

  function consumeOp(
    mapping(bytes32 => uint96) storage pendingOps,
    mapping(bytes32 => bytes) storage pendingData,
    uint8 opType,
    address target
  ) internal returns (bytes memory data) {
    return consume(pendingOps, pendingData, key(opType, target), opType, target);
  }

  function cancel(
    mapping(bytes32 => uint96) storage pendingOps,
    mapping(bytes32 => bytes) storage pendingData,
    bytes32 id,
    uint8 opType,
    address target
  ) internal {
    if (pendingOps[id] == 0) revert Err.InvalidState();
    delete pendingOps[id];
    delete pendingData[id];
    emit ICdp.TimelockCancelled(id, opType, target);
  }
}
