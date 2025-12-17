// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title LibTimelock
/// @notice Ultra-compact timelock library with packed storage
/// @dev Used by Bridge, AdminV1, and Rescue modules for unified governance
library LibTimelock {
    error NotReady();
    error Expired();

    /// @notice Single packed slot: [48 bits executeAt][48 bits grace][160 bits reserved]
    /// @dev Pack timestamp + grace period into 96 bits (good until year 8921556)
    function pack(uint48 delay, uint48 grace) internal view returns (uint96) {
        unchecked { return (uint96(block.timestamp + delay) << 48) | grace; }
    }

    /// @notice Validate timelock is ready (after delay, before expiry)
    /// @dev Reverts if not ready or expired
    function validate(uint96 packed) internal view {
        uint48 executeAt = uint48(packed >> 48);
        uint48 grace = uint48(packed);
        if (executeAt == 0 || block.timestamp < executeAt) revert NotReady();
        if (grace > 0 && block.timestamp > executeAt + grace) revert Expired();
    }
}