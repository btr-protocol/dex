// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {LibTimelock as TL} from "./LibTimelock.sol";
import {Err} from "../Errors.sol";

/// @title LibUpgradeQueue
/// @notice Generic queue/consume/cancel API for timelocked upgrade operations.
/// @dev Internal-only helpers. Stores packed (executeAt|grace) in `opsMap` and ABI-encoded
///      payload in `dataMap`. Caller controls the keying scheme and event emission.
///      Building block: LibTimelock primitives (pack/validate).
library LibUpgradeQueue {
    /// @notice Queue an operation: pack timelock + persist payload.
    /// @param opsMap mapping(id => packed timelock slot)
    /// @param dataMap mapping(id => encoded payload)
    /// @param id operation key
    /// @param delay timelock delay (seconds)
    /// @param grace grace window after executeAt (seconds)
    /// @param data ABI-encoded payload
    /// @return eta absolute timestamp at which the op becomes executable (alm Queued.eta semantics)
    function queue(
        mapping(bytes32 => uint96) storage opsMap,
        mapping(bytes32 => bytes) storage dataMap,
        bytes32 id,
        uint48 delay,
        uint48 grace,
        bytes memory data
    ) internal returns (uint48 eta) {
        opsMap[id] = TL.pack(delay, grace);
        dataMap[id] = data;
        unchecked { eta = uint48(block.timestamp) + delay; }
    }

    /// @notice Consume an operation: validate timelock, return payload, clear slots.
    /// @dev Reverts via LibTimelock.validate if not ready or expired.
    function consume(
        mapping(bytes32 => uint96) storage opsMap,
        mapping(bytes32 => bytes) storage dataMap,
        bytes32 id
    ) internal returns (bytes memory data) {
        TL.validate(opsMap[id]);
        data = dataMap[id];
        delete opsMap[id];
        delete dataMap[id];
    }

    /// @notice Cancel a queued operation. Reverts if no operation is queued.
    function cancel(
        mapping(bytes32 => uint96) storage opsMap,
        mapping(bytes32 => bytes) storage dataMap,
        bytes32 id
    ) internal {
        if (opsMap[id] == 0) revert Err.InvalidState();
        delete opsMap[id];
        delete dataMap[id];
    }
}
