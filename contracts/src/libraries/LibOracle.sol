// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOracle} from "../interfaces/IOracle.sol";
import {LibMaths as M} from "./LibMaths.sol";

/// @title LibOracle - Oracle offset encoding/decoding and price computation
/// @notice Handles conversion between spot prices + offsets ↔ EMAs
/// @dev Single source of truth for oracle decoding logic
library LibOracle {

    /// @notice Offset precision: 0.0001% = 1 unit
    uint256 internal constant OFFSET_PRECISION = 10_000_000;

    // ========== OFFSET DECODING ==========

    /// @notice Decode fast EMA from current price + offset
    /// @param current Current price (b64)
    /// @param offset Fast EMA offset (0.0001% precision, signed)
    /// @return fastEMA Fast EMA price in b64 format
    function decodeFastEMA(uint64 current, int32 offset) internal pure returns (uint64 fastEMA) {
        // fastEMA = current * (OFFSET_PRECISION + offset) / OFFSET_PRECISION
        uint256 current256 = uint256(current);
        int256 multiplier = int256(OFFSET_PRECISION) + int256(offset);

        // Handle negative offsets (EMA below current)
        if (multiplier <= 0) return 0;  // Clamp to zero

        uint256 result = (current256 * uint256(multiplier)) / OFFSET_PRECISION;

        // Clamp to uint64 max
        if (result > type(uint64).max) return type(uint64).max;

        return uint64(result);
    }

    /// @notice Decode slow EMA from current price + offset
    /// @param current Current price (b64)
    /// @param offset Slow EMA offset (0.0001% precision, signed)
    /// @return slowEMA Slow EMA price in b64 format
    function decodeSlowEMA(uint64 current, int32 offset) internal pure returns (uint64 slowEMA) {
        uint256 current256 = uint256(current);
        int256 multiplier = int256(OFFSET_PRECISION) + int256(offset);

        if (multiplier <= 0) return 0;

        uint256 result = (current256 * uint256(multiplier)) / OFFSET_PRECISION;

        if (result > type(uint64).max) return type(uint64).max;

        return uint64(result);
    }

    // ========== OFFSET ENCODING ==========

    /// @notice Encode offset from current price and EMA
    /// @dev offset = ((ema / current) - 1) * OFFSET_PRECISION
    /// @param current Current price (b64)
    /// @param ema EMA price (b64)
    /// @return offset Encoded offset (0.0001% precision, signed)
    function encodeOffset(uint64 current, uint64 ema) internal pure returns (int32 offset) {
        if (current == 0) return 0;

        // Compute ratio in high precision: (ema * OFFSET_PRECISION) / current
        uint256 ratio = (uint256(ema) * OFFSET_PRECISION) / uint256(current);

        // Subtract base (OFFSET_PRECISION represents 100%)
        int256 offset256 = int256(ratio) - int256(OFFSET_PRECISION);

        // Clamp to int32 range [-2,147,483,648, 2,147,483,647]
        // This covers ±214,748% range in 0.0001% units
        if (offset256 > int256(int32(type(int32).max))) return type(int32).max;
        if (offset256 < int256(int32(type(int32).min))) return type(int32).min;

        return int32(offset256);
    }

    // ========== PRICE DECODING ==========

    /// @notice Decode feed data to 1e18 prices
    /// @param feed Oracle feed data
    /// @return priceFast Fast EMA in 1e18 format
    /// @return priceSlow Slow EMA in 1e18 format
    function decodePrices(IOracle.FeedData memory feed)
        internal
        pure
        returns (uint256 priceFast, uint256 priceSlow)
    {
        uint64 fastEMA = decodeFastEMA(feed.currentPrice, feed.fastOffset);
        uint64 slowEMA = decodeSlowEMA(feed.currentPrice, feed.slowOffset);

        priceFast = M.b64ToPrice(fastEMA);
        priceSlow = M.b64ToPrice(slowEMA);
    }

    /// @notice Get fast price only (optimized for hot path)
    /// @param feed Oracle feed data
    /// @return priceFast Fast EMA in 1e18 format
    function getFastPrice(IOracle.FeedData memory feed)
        internal
        pure
        returns (uint256 priceFast)
    {
        uint64 fastEMA = decodeFastEMA(feed.currentPrice, feed.fastOffset);
        priceFast = M.b64ToPrice(fastEMA);
    }

    /// @notice Get slow price only
    /// @param feed Oracle feed data
    /// @return priceSlow Slow EMA in 1e18 format
    function getSlowPrice(IOracle.FeedData memory feed)
        internal
        pure
        returns (uint256 priceSlow)
    {
        uint64 slowEMA = decodeSlowEMA(feed.currentPrice, feed.slowOffset);
        priceSlow = M.b64ToPrice(slowEMA);
    }
}
