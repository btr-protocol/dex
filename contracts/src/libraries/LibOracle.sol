// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IOracleV1} from "../interfaces/IOracleV1.sol";
import {LibMaths as M} from "./LibMaths.sol";
import {LibConstants as C} from "./LibConstants.sol";

/// @title LibOracle - Pure oracle math and decoding
/// @notice Handles conversion between spot prices + offsets ↔ EMAs
/// @dev Pure math library - no caching, no external calls
///      Caching is handled by LibTransientCache at higher layers
library LibOracle {

    /// @notice Oracle offset precision: 0.00001% = 1 unit (10x finer than PBPS)
    /// @dev Stored as int32 in FeedData, giving ±21,474% range
    ///      Kept separate from C.PBPS for backward compatibility with deployed contracts
    uint256 public constant ORACLE_PBPS = 10_000_000;

    // ========== EFFICIENT 1E18 DECODING (NO REDUNDANT CONVERSIONS) ==========

    /// @notice Apply offset to decoded price directly in 1e18
    /// @dev Avoids redundant B64 encode/decode cycle
    /// @param price1e18 Decoded current price in 1e18
    /// @param offset EMA offset (ORACLE_PBPS precision, signed)
    /// @return ema1e18 EMA price in 1e18 format
    function _applyOffset(uint256 price1e18, int32 offset) private pure returns (uint256 ema1e18) {
        // Short-circuit for zero offset
        if (offset == 0) return price1e18;

        // Apply offset: ema = current * (1 + offset/ORACLE_PBPS)
        // ema = current * (ORACLE_PBPS + offset) / ORACLE_PBPS
        int256 multiplier = int256(ORACLE_PBPS) + int256(offset);

        // Handle extreme negative offsets (EMA would be <= 0)
        if (multiplier <= 0) return 1; // Minimum representable price in 1e18

        // Apply offset in 1e18 space
        return (price1e18 * uint256(multiplier)) / ORACLE_PBPS;
    }

    /// @notice Decode feed data to 1e18 prices efficiently
    /// @dev Single decode of lastPriceB64, then applies offsets in 1e18 space
    /// @param feed Oracle feed data
    /// @return priceFast Fast EMA in 1e18 format
    /// @return priceSlow Slow EMA in 1e18 format
    function decodeB64s(IOracleV1.FeedData memory feed)
        internal
        pure
        returns (uint256 priceFast, uint256 priceSlow)
    {
        // Decode current price once
        uint256 currentPrice = M.b64To1e18(feed.lastPriceB64);

        // Apply offsets directly in 1e18 space (no redundant encoding)
        priceFast = _applyOffset(currentPrice, feed.fastOffset);
        priceSlow = _applyOffset(currentPrice, feed.slowOffset);
    }

    /// @notice Get fast price only (optimized for hot path)
    /// @param feed Oracle feed data
    /// @return priceFast Fast EMA in 1e18 format
    function getFastEMA(IOracleV1.FeedData memory feed)
        internal
        pure
        returns (uint256 priceFast)
    {
        uint256 currentPrice = M.b64To1e18(feed.lastPriceB64);
        priceFast = _applyOffset(currentPrice, feed.fastOffset);
    }

    /// @notice Get slow price only
    /// @param feed Oracle feed data
    /// @return priceSlow Slow EMA in 1e18 format
    function getSlowPrice(IOracleV1.FeedData memory feed)
        internal
        pure
        returns (uint256 priceSlow)
    {
        uint256 currentPrice = M.b64To1e18(feed.lastPriceB64);
        priceSlow = _applyOffset(currentPrice, feed.slowOffset);
    }

    // ========== OFFSET ENCODING ==========

    /// @notice Encode offset from current price and EMA
    /// @dev offset = ((ema / current) - 1) * ORACLE_PBPS
    ///      Correctly handles B64 format: decode both → compute ratio → encode offset
    /// @param current Current price (b64)
    /// @param ema EMA price (b64)
    /// @return offset Encoded offset (ORACLE_PBPS precision, signed)
    function encodeOffset(uint64 current, uint64 ema) internal pure returns (int32 offset) {
        if (current == 0) return 0;

        // Decode B64 to 1e18 for arithmetic
        uint256 currentPrice = M.b64To1e18(current);
        uint256 emaPrice = M.b64To1e18(ema);

        // Compute ratio in high precision: (ema * ORACLE_PBPS) / current
        uint256 ratio = (emaPrice * ORACLE_PBPS) / currentPrice;

        // Subtract base (ORACLE_PBPS represents 100%)
        int256 offset256 = int256(ratio) - int256(ORACLE_PBPS);

        // Clamp to int32 range [-2,147,483,648, 2,147,483,647]
        // This covers ±214,748% range in 0.0001% units
        if (offset256 > int256(int32(type(int32).max))) return type(int32).max;
        if (offset256 < int256(int32(type(int32).min))) return type(int32).min;

        return int32(offset256);
    }

    /// @notice Encode offset from 1e18 prices (avoids redundant decoding)
    /// @dev offset = ((ema / current) - 1) * ORACLE_PBPS
    /// @param currentPrice Current price in 1e18
    /// @param emaPrice EMA price in 1e18
    /// @return offset Encoded offset (ORACLE_PBPS precision, signed)
    function encodeOffset1e18(uint256 currentPrice, uint256 emaPrice) internal pure returns (int32 offset) {
        if (currentPrice == 0) return 0;

        // Compute ratio in high precision: (ema * ORACLE_PBPS) / current
        uint256 ratio = (emaPrice * ORACLE_PBPS) / currentPrice;

        // Subtract base (ORACLE_PBPS represents 100%)
        int256 offset256 = int256(ratio) - int256(ORACLE_PBPS);

        // Clamp to int32 range
        if (offset256 > int256(int32(type(int32).max))) return type(int32).max;
        if (offset256 < int256(int32(type(int32).min))) return type(int32).min;

        return int32(offset256);
    }

    // ========== VOLATILITY (σ) & DEVIATION (Δ) COMPUTATION ==========

    /// @notice Compute effective volatility (σ) from fast and slow EMAs
    /// @dev Uses mean (average) of fast and slow to blend timeframes
    /// @param feed Oracle feed data
    /// @return sigma Effective volatility σ (1e6 units, mean of fast/slow)
    function getSigma(IOracleV1.FeedData memory feed)
        internal
        pure
        returns (uint32 sigma)
    {
        // σ = (σ_fast + σ_slow) / 2
        return (feed.fastVolEMA + feed.slowVolEMA) / 2;
    }

    /// @notice Compute effective deviation (Δ) from multi-timeframe price divergence
    /// @dev Measures directional uncertainty via fast/slow EMA spread and fast/current divergence
    /// @param feed Oracle feed data
    /// @return delta Effective deviation Δ (offset units, max of fast-slow and fast-current spreads)
    function getDelta(IOracleV1.FeedData memory feed)
        internal
        pure
        returns (uint32 delta)
    {
        // d_fs = |fastOffset - slowOffset| (fast vs slow EMA divergence)
        uint256 dfs = feed.fastOffset > feed.slowOffset
            ? uint256(int256(feed.fastOffset - feed.slowOffset))
            : uint256(int256(feed.slowOffset - feed.fastOffset));

        // d_fc = |fastOffset| (fast vs current price, since current has offset 0)
        uint256 dfc = feed.fastOffset >= 0
            ? uint256(int256(feed.fastOffset))
            : uint256(-int256(feed.fastOffset));

        // Conservative: Δ = max(d_fs, d_fc)
        uint256 maxDelta = dfs > dfc ? dfs : dfc;

        // Cap at uint32 max
        return maxDelta > type(uint32).max ? type(uint32).max : uint32(maxDelta);
    }

    // ========== BASE TOKEN FEED SYNTHESIS ==========

    /// @notice Synthesize feed for base token (no oracle needed, always 1.0)
    /// @dev Used by CoreV1 and LibPricing to avoid duplication
    /// @return feed Synthetic FeedData for base token at 1e18 price
    function getBaseFeed() internal view returns (IOracleV1.FeedData memory feed) {
        uint64 oneB64 = M.encodeB64(C.WAD, 18); // 1.0 in b64 format

        return IOracleV1.FeedData({
            lastPriceB64: oneB64,
            fastOffset: 0,
            slowOffset: 0,
            fastVolEMA: uint32(C.ONE_PCT_PBPS),  // 0.01% baseline volatility
            slowVolEMA: uint32(C.ONE_PCT_PBPS),
            updatedAt: uint32(block.timestamp),
            ttl: type(uint16).max, // Never expires
            confidence: 100
        });
    }
}