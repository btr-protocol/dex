// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IOracleV1} from "../interfaces/IOracleV1.sol";

/// @title LibTransientCache
/// @notice Transaction-scoped caching for oracle data using transient storage (EIP-1153)
/// @dev Simplified bitmask-based keying to avoid keccak overhead
///      Only caches oracle feeds (expensive external calls worth caching)
///      Saves ~2,100+ gas per cache hit by avoiding repeated STATICCALL + oracle logic
library LibTransientCache {

    // ========== BITMASK KEYING CONSTANTS ==========

    /// @dev High-entropy namespace salt (bits [192:255])
    ///      Derived from keccak256("pool.cache") >> 192
    ///      Occupies high 64 bits to avoid collision with type+address (bits [0:175])
    uint256 private constant NAMESPACE_SALT = uint256(keccak256("pool.cache")) >> 192 << 192;

    /// @dev Type discriminator for oracle feed cache (1 << 168)
    ///      Occupies bits [168:175] between SALT and address
    uint256 private constant TYPE_ORACLE_FEED = 1 << 168;

    // ========== SLOT DERIVATION ==========

    /// @dev Derive transient storage slot from type and token without keccak
    /// @param typeMask Type discriminator (TYPE_ORACLE_FEED or TYPE_DECODED_PRICE)
    /// @param token Token address
    /// @return slot Transient storage slot
    function _slot(uint256 typeMask, address token) private pure returns (bytes32 slot) {
        // Bitmask pattern: SALT (88 bits) | TYPE (8 bits) | ADDRESS (160 bits)
        // Mathematically isolated - no collisions possible
        unchecked {
            slot = bytes32(NAMESPACE_SALT | typeMask | uint256(uint160(token)));
        }
    }

    // ========== ORACLE FEED CACHING (SINGLE SLOT) ==========

    /// @notice Cache oracle feed data for a token
    /// @dev Packs entire FeedData into single 256-bit slot
    /// Layout (MSB→LSB): lastPrice(64) | fastOffset(32) | slowOffset(32) |
    ///                   fastVolEMA(32) | slowVolEMA(32) | updatedAt(32) | ttl(16) | confidence(16)
    /// @param token Token address
    /// @param data Oracle feed data to cache
    function cacheOracleFeed(address token, IOracleV1.FeedData memory data) internal {
        bytes32 slot = _slot(TYPE_ORACLE_FEED, token);

        uint256 packed = _packFeedData(data);
        if (packed == 0) return; // lastPrice never zero for valid feeds

        assembly {
            tstore(slot, packed)
        }
    }

    /// @notice Try to load cached oracle feed
    /// @dev Returns cache hit status and data (only valid if found=true)
    /// @param token Token address
    /// @return found True if cache hit (~100 gas), false if miss
    /// @return data Cached oracle data (only valid if found=true)
    function tryLoadOracleFeed(address token)
        internal
        view
        returns (bool found, IOracleV1.FeedData memory data)
    {
        bytes32 slot = _slot(TYPE_ORACLE_FEED, token);
        uint256 packed;

        assembly {
            packed := tload(slot)
        }

        if (packed == 0) return (false, data);

        data = _unpackFeedData(packed);
        return (true, data);
    }

    // ========== PACKING / UNPACKING ==========

    /// @dev Pack FeedData into single uint256
    /// Layout matches IOracleV1.FeedData: 64+32+32+32+32+32+16+16 = 256 bits
    function _packFeedData(IOracleV1.FeedData memory d) private pure returns (uint256 packed) {
        packed |= uint256(d.lastPriceB64) << 192;
        packed |= uint256(uint32(d.fastOffset)) << 160;
        packed |= uint256(uint32(d.slowOffset)) << 128;
        packed |= uint256(d.fastVolEMA) << 96;
        packed |= uint256(d.slowVolEMA) << 64;
        packed |= uint256(d.updatedAt) << 32;
        packed |= uint256(d.ttl) << 16;
        packed |= uint256(d.confidence);
    }

    /// @dev Unpack uint256 into FeedData
    function _unpackFeedData(uint256 packed) private pure returns (IOracleV1.FeedData memory d) {
        d.confidence = uint16(packed & 0xFFFF);
        packed >>= 16;

        d.ttl = uint16(packed & 0xFFFF);
        packed >>= 16;

        d.updatedAt = uint32(packed & 0xFFFFFFFF);
        packed >>= 32;

        d.slowVolEMA = uint32(packed & 0xFFFFFFFF);
        packed >>= 32;

        d.fastVolEMA = uint32(packed & 0xFFFFFFFF);
        packed >>= 32;

        // Reinterpret uint32 as int32 via two's complement
        d.slowOffset = int32(uint32(packed & 0xFFFFFFFF));
        packed >>= 32;

        d.fastOffset = int32(uint32(packed & 0xFFFFFFFF));
        packed >>= 32;

        d.lastPriceB64 = uint64(packed & 0xFFFFFFFFFFFFFFFF);
    }
}
