// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title LibTimelock
/// @notice Ultra-compact timelock library with packed storage.
/// @dev    Used by Bridge, AdminV1, Rescue, Staking, Treasury, Router, PoolProxy + LibUpgradeQueue
///         for unified governance. Field naming aligned with alm/evm AccessControl.Queued
///         semantics: the post-delay executable timestamp is referred to as `eta`
///         (cf. `struct Queued { address addr; uint64 eta; }` in alm/evm/src/AccessControl.sol).
///         Storage layout (uint96 packed [hi: eta | lo: grace]) is unchanged — load-bearing for
///         ERC-7201 storage compatibility across all consumers.
library LibTimelock {
    error NotReady();
    error Expired();

    /// @notice Single packed slot: [48 bits eta][48 bits grace]
    /// @dev `eta = block.timestamp + delay` (alm-style ETA semantics). Pack ETA + grace
    ///      into 96 bits (good until year 8921556).
    function pack(uint48 delay, uint48 grace) internal view returns (uint96) {
        unchecked { return (uint96(block.timestamp + delay) << 48) | grace; }
    }

    /// @notice Validate timelock is ready (after eta, before eta+grace).
    /// @dev Reverts NotReady if `block.timestamp < eta`; Expired if past `eta + grace` (when grace>0).
    function validate(uint96 packed) internal view {
        uint48 eta = uint48(packed >> 48);
        uint48 grace = uint48(packed);
        if (eta == 0 || block.timestamp < eta) revert NotReady();
        if (grace > 0 && block.timestamp > eta + grace) revert Expired();
    }
}
