// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IOracle} from "../interfaces/IOracle.sol";
import {Maths as M} from "./Maths.sol";
import {Constants as C} from "./Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title Oracle -pure oracle math (decode/encode offsets, σ, Δ).
/// @dev Caching @ LibTransientCache; no external calls here.
library Oracle {
    /// @notice Offset precision (0.00001%/unit, 10x finer than PBPS). int32 stored ⇒ ±21,474% range.
    uint256 public constant ORACLE_PBPS = 10_000_000;

    /// @dev ema = price * (1 + offset/ORACLE_PBPS), clamps to 1 wei on extreme negative.
    function _applyOffset(uint256 price1e18, int32 offset) private pure returns (uint256 ema1e18) {
        if (offset == 0) return price1e18;
        int256 multiplier = int256(ORACLE_PBPS) + int256(offset);
        if (multiplier <= 0) return 1;
        // Phase 42D R3-A4-1: fullMulDiv hardens vs theoretical b64-extreme overflow.
        return FixedPointMathLib.fullMulDiv(price1e18, uint256(multiplier), ORACLE_PBPS);
    }

    /// @notice Decode feed → (priceFast, priceSlow) in 1e18.
    function decodeB64s(IOracle.FeedData memory feed)
        internal pure returns (uint256 priceFast, uint256 priceSlow)
    {
        uint256 cur = M.b64To1e18(feed.lastPriceB64);
        priceFast = _applyOffset(cur, feed.fastOffset);
        priceSlow = _applyOffset(cur, feed.slowOffset);
    }

    /// @notice Encode offset from 1e18 prices.
    function encodeOffset1e18(uint256 currentPrice, uint256 emaPrice) internal pure returns (int32) {
        if (currentPrice == 0) return 0;
        uint256 ratio = (emaPrice * ORACLE_PBPS) / currentPrice;
        int256 off = int256(ratio) - int256(ORACLE_PBPS);
        if (off > int256(int32(type(int32).max))) return type(int32).max;
        if (off < int256(int32(type(int32).min))) return type(int32).min;
        return int32(off);
    }

    /// @notice σ = mean(σ_fast, σ_slow) in 1e6 units.
    function getSigma(IOracle.FeedData memory feed) internal pure returns (uint32) {
        return (feed.fastVolEMA + feed.slowVolEMA) / 2;
    }

    /// @notice Synthetic feed for base token (price 1.0, never expires).
    function getBaseFeed() internal view returns (IOracle.FeedData memory feed) {
        feed = IOracle.FeedData({
            lastPriceB64: M.encodeB64(SC.WAD, 18),
            fastOffset: 0,
            slowOffset: 0,
            fastVolEMA: uint32(SC.ONE_PCT_PBPS),
            slowVolEMA: uint32(SC.ONE_PCT_PBPS),
            updatedAt: uint32(block.timestamp),
            ttl: type(uint16).max,
            confidence: 100
        });
    }
}
