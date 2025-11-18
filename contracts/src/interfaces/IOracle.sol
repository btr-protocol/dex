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

    /// @notice Oracle feed data - FITS IN SINGLE 256-BIT SLOT
    /// @dev Layout (total 256 bits):
    ///      - currentPrice: 64 bits (b64 format)
    ///      - fastOffset: 32 bits signed (0.0001% precision: ±214,748% range)
    ///      - slowOffset: 32 bits signed (0.0001% precision: ±214,748% range)
    ///      - fastVolEMA: 32 bits (1e6 base: 1_000_000 = 1%)
    ///      - slowVolEMA: 32 bits (1e6 base: 1_000_000 = 1%)
    ///      - updatedAt: 32 bits (timestamp)
    ///      - ttl: 16 bits (staleness threshold in seconds)
    ///      - confidence: 16 bits (0-100, where 100 = highest confidence)
    ///
    /// @dev Fast/slow EMAs reconstructed as:
    ///      fastEMA = currentPrice * (OFFSET_PRECISION + fastOffset) / OFFSET_PRECISION
    ///      slowEMA = currentPrice * (OFFSET_PRECISION + slowOffset) / OFFSET_PRECISION
    ///
    /// @dev Confidence interpretation:
    ///      100: Perfect consensus, low latency
    ///      80-99: Good confidence, normal conditions
    ///      50-79: Medium confidence, some lag/dispersion
    ///      20-49: Low confidence, high dispersion
    ///      0-19: Very low confidence, stale or unreliable
    struct FeedData {
        uint64 currentPrice;    // Current spot price (b64)
        int32 fastOffset;       // Fast EMA offset from current (0.0001% = 1 unit)
        int32 slowOffset;       // Slow EMA offset from current (0.0001% = 1 unit)
        uint32 fastVolEMA;      // Fast volatility EMA (1e6: 1_000_000 = 1%)
        uint32 slowVolEMA;      // Slow volatility EMA (1e6: 1_000_000 = 1%)
        uint32 updatedAt;       // Timestamp of last update
        uint16 ttl;             // Time-to-live: max age in seconds before feed is stale
        uint16 confidence;      // Oracle confidence (0-100)
    }

    /// @notice Offset precision: represents 100% when multiplied by price
    /// @dev 0.0001% = 1 unit, so OFFSET_PRECISION = 10,000,000
    uint256 constant OFFSET_PRECISION = 10_000_000;

    /// @notice Decoded oracle data with computed TWAPs and prices
    /// @dev This is a compatibility struct for pricing modules
    /// @dev In the new model, use LibOracle.decodePrices() instead
    struct DecodedFeedData {
        uint64 fastTWAP;
        uint64 slowTWAP;
        uint256 priceFast;      // 1e18
        uint256 priceSlow;      // 1e18
        uint32 volFast;
        uint32 volSlow;
        uint32 volBaseline;     // = volSlow
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
