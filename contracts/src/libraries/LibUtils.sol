// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {BAMMErrors as E} from "../bamm/BAMMEvents.sol";

/// @title LibUtils
/// @notice Consolidated utility library for casting and validation helpers
/// @dev Combines LibCast and LibValidation for cleaner imports
library LibUtils {

    // ========== TYPE CASTING ==========

    /// @notice Safely cast uint256 to uint128 with overflow check
    function toUint128(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) revert E.Overflow();
        return uint128(value);
    }

    /// @notice Safely cast uint256 to uint64 with overflow check
    function toUint64(uint256 value) internal pure returns (uint64) {
        if (value > type(uint64).max) revert E.Overflow();
        return uint64(value);
    }

    /// @notice Safely cast uint256 to uint32 with overflow check
    function toUint32(uint256 value) internal pure returns (uint32) {
        if (value > type(uint32).max) revert E.Overflow();
        return uint32(value);
    }

    /// @notice Safely cast uint256 to uint16 with overflow check
    function toUint16(uint256 value) internal pure returns (uint16) {
        if (value > type(uint16).max) revert E.Overflow();
        return uint16(value);
    }

    /// @notice Safely cast uint256 to uint8 with overflow check
    function toUint8(uint256 value) internal pure returns (uint8) {
        if (value > type(uint8).max) revert E.Overflow();
        return uint8(value);
    }

    /// @notice Convert address to token ID (for ERC1155)
    function addressToTokenId(address token) internal pure returns (uint256 id) {
        assembly { id := token }
    }

    /// @notice Convert address to hex string (without 0x prefix)
    function toHexString(address addr) internal pure returns (string memory) {
        bytes memory buffer = new bytes(40);
        unchecked {
            for (uint256 i; i < 20; ++i) {
                uint8 b = uint8(uint160(addr) >> (8 * (19 - i)));
                buffer[i * 2] = bytes1(b >> 4 < 10 ? b >> 4 + 0x30 : b >> 4 + 0x57);
                buffer[i * 2 + 1] = bytes1((b & 0x0f) < 10 ? (b & 0x0f) + 0x30 : (b & 0x0f) + 0x57);
            }
        }
        return string(buffer);
    }

    // ========== VALIDATION ==========

    /// @notice Require asset exists (reserves > 0)
    function requireExists(IBAMM.Asset storage asset) internal view {
        if (asset.reserves == 0) revert E.AssetNotFound();
    }

    /// @notice Require asset is registered (has segment configuration)
    function requireRegistered(IBAMM.Asset storage asset) internal view {
        if (asset.segmentCount == 0) revert E.AssetNotFound();
    }

    /// @notice Require asset is not frozen
    function requireNotFrozen(IBAMM.Asset storage asset) internal view {
        if (asset.isFrozen) revert E.AssetFrozen();
    }

    /// @notice Require asset exists and is not frozen
    function requireActive(IBAMM.Asset storage asset) internal view {
        requireExists(asset);
        requireNotFrozen(asset);
    }

    /// @notice Require pool is not paused
    function requireNotPaused(bool isPoolPaused) internal pure {
        if (isPoolPaused) revert E.Paused();
    }

    /// @notice Require address is not zero
    function requireNonZero(address addr) internal pure {
        if (addr == address(0)) revert E.ZeroAddress();
    }

    /// @notice Require amount is not zero
    function requireNonZero(uint256 amount) internal pure {
        if (amount == 0) revert E.ZeroAmount();
    }

    /// @notice Require reserves meet minimum liquidity
    function requireMinLiquidity(IBAMM.Asset storage asset) internal view {
        if (asset.reserves < asset.minLiquidity) revert E.BelowMinimumLiquidity();
    }
}
