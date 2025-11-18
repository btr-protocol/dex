// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IOracle
/// @notice Shared interface for all oracle types (internal and external)
/// @dev This interface allows BAMM to uniformly read from any oracle type
///      All prices use b64 float format (56-bit mantissa, 8-bit signed exponent)
///      Format: uint64 = (mantissa << 8) | uint8(exponent + 128)
///      All volatility uses 1e6 base (1_000_000 = 1%)
interface IOracle {

    // ========== TYPES ==========

    /// @notice Feed data structure (price feed for a specific base/quote pair)
    /// @dev For internal oracles: Prices use accumulator pattern, volatility uses EMA
    /// @dev For external oracles: Both prices and volatility can use any methodology
    /// @dev One oracle contract can manage multiple feeds (1:N relationship)
    /// @dev Storage: Fits in single 256-bit slot (32 bytes exactly, fully packed)
    ///      - fastEMA (8 bytes) + slowEMA (8 bytes) = 16 bytes
    ///      - fastVolEMA (4 bytes) + slowVolEMA (4 bytes) = 8 bytes
    ///      - updatedAt (4 bytes) + maxDeviation (2 bytes) + ttl (2 bytes) = 8 bytes
    ///      Total: 32 bytes → Single SSTORE per update (~5,000 gas)
    struct FeedData {
        uint64 fastEMA;               // Fast price EMA (shorter window, e.g., ~6 hours) - b64 format
        uint64 slowEMA;               // Slow price EMA (longer window, e.g., ~1 week) - b64 format
        uint32 fastVolEMA;            // Fast volatility EMA (1e6 base: 1_000_000 = 1%)
        uint32 slowVolEMA;            // Slow volatility EMA (1e6 base: 1_000_000 = 1%)
        uint32 updatedAt;             // Timestamp of last update
        uint16 maxDeviation;          // Deviation threshold triggering update (0.0001% precision: 10_000 = 1%, max 6.5%)
        uint16 ttl;                   // Time-to-live: max age in seconds before feed is stale (e.g., 3600 = 1 hour)
    }

    /// @notice Decoded oracle data with computed TWAPs and prices
    /// @dev Output format for oracle decoding (both internal and external)
    /// @dev Used by pricing and other modules that need computed values
    struct DecodedFeedData {
        uint64 fastTWAP;
        uint64 slowTWAP;
        uint256 priceFast;      // 1e18
        uint256 priceSlow;      // 1e18
        uint32 volFast;
        uint32 volSlow;
        uint32 volBaseline;     // = volSlow (baseline volatility, no clamping)
    }

    // ========== VIEW FUNCTIONS ==========
    // These functions MUST be implemented by both internal and external oracles

    /// @notice Get feed data for a specific feed ID (base/quote pair)
    /// @dev Feed ID = keccak256(abi.encodePacked(baseAsset, quoteAsset))
    /// @param feedId Feed identifier (base/quote pair hash)
    /// @return data Feed data with fast/slow EMAs, volatility EMAs, and timestamp
    function getFeedData(bytes32 feedId) external view returns (FeedData memory data);

    /// @notice Check if feed data is fresh against a custom max age
    /// @param feedId Feed identifier to check
    /// @param maxAge Maximum acceptable age in seconds
    /// @return True if data is fresh (age <= maxAge)
    function isFresh(bytes32 feedId, uint32 maxAge) external view returns (bool);

    /// @notice Check if feed data is fresh using the feed's configured TTL
    /// @dev ALWAYS uses FeedData.ttl as staleness threshold (no external config)
    /// @param feedId Feed identifier to check
    /// @return True if data is fresh (age <= feed.ttl)
    function isFreshDefault(bytes32 feedId) external view returns (bool);

    /// @notice Get just the fast price EMA (most gas efficient)
    /// @param feedId Feed identifier to query
    /// @return fastEMA Current fast EMA in b64 format
    function getFastPrice(bytes32 feedId) external view returns (uint64 fastEMA);
}
