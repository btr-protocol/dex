// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IOracle} from "../interfaces/IOracle.sol";

/// @title LibTransientCache
/// @notice Tx-scoped oracle cache via transient storage (EIP-1153). ~2.1k gas/hit.
library LibTransientCache {
    // SALT (high 64 bits) | TYPE (bit 168) | ADDR (160 bits) — collision-free.
    uint256 private constant NAMESPACE_SALT = uint256(keccak256("pool.cache")) >> 192 << 192;
    uint256 private constant TYPE_ORACLE_FEED = 1 << 168;

    function _slot(uint256 typeMask, address token) private pure returns (bytes32 slot) {
        unchecked { slot = bytes32(NAMESPACE_SALT | typeMask | uint256(uint160(token))); }
    }

    /// @notice Cache oracle feed (packed in single 256-bit slot).
    function cacheOracleFeed(address token, IOracle.FeedData memory data) internal {
        bytes32 slot = _slot(TYPE_ORACLE_FEED, token);
        uint256 packed = _packFeedData(data);
        if (packed == 0) return;
        assembly { tstore(slot, packed) }
    }

    /// @notice Try-load cached oracle feed.
    function tryLoadOracleFeed(address token)
        internal
        view
        returns (bool found, IOracle.FeedData memory data)
    {
        bytes32 slot = _slot(TYPE_ORACLE_FEED, token);
        uint256 packed;
        assembly { packed := tload(slot) }
        if (packed == 0) return (false, data);
        data = _unpackFeedData(packed);
        return (true, data);
    }

    // Layout: lastPrice(64)|fastOff(32)|slowOff(32)|fastVol(32)|slowVol(32)|updAt(32)|ttl(16)|conf(16)
    function _packFeedData(IOracle.FeedData memory d) private pure returns (uint256 packed) {
        packed |= uint256(d.lastPriceB64) << 192;
        packed |= uint256(uint32(d.fastOffset)) << 160;
        packed |= uint256(uint32(d.slowOffset)) << 128;
        packed |= uint256(d.fastVolEMA) << 96;
        packed |= uint256(d.slowVolEMA) << 64;
        packed |= uint256(d.updatedAt) << 32;
        packed |= uint256(d.ttl) << 16;
        packed |= uint256(d.confidence);
    }

    function _unpackFeedData(uint256 packed) private pure returns (IOracle.FeedData memory d) {
        d.confidence = uint16(packed & 0xFFFF); packed >>= 16;
        d.ttl = uint16(packed & 0xFFFF); packed >>= 16;
        d.updatedAt = uint32(packed & 0xFFFFFFFF); packed >>= 32;
        d.slowVolEMA = uint32(packed & 0xFFFFFFFF); packed >>= 32;
        d.fastVolEMA = uint32(packed & 0xFFFFFFFF); packed >>= 32;
        d.slowOffset = int32(uint32(packed & 0xFFFFFFFF)); packed >>= 32;
        d.fastOffset = int32(uint32(packed & 0xFFFFFFFF)); packed >>= 32;
        d.lastPriceB64 = uint64(packed & 0xFFFFFFFFFFFFFFFF);
    }
}
