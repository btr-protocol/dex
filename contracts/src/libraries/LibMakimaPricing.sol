// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {LibLiquiditySegments as Seg} from "./LibLiquiditySegments.sol";
import {LibMakima} from "./LibMakima.sol";
import {LibMaths as M} from "./LibMaths.sol";
import {FPMaths as FPMath} from "solady/utils/FixedPointMathLib.sol";

/// @title LibMakimaPricing - Makima cubic spline pricing for AMM
/// @notice Replaces linear piecewise with smooth C¹ cubic Hermite curves
/// @dev All slopes pre-computed off-chain, only evaluation on-chain
library LibMakimaPricing {
    using FPMath for uint256;
    using Seg for Seg.PackedSegments;

    // ========== CONSTANTS ==========

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS_BASE = 1_000_000; // 0.0001% base (same as fees)
    uint256 private constant VOL_BASE = 1_000_000; // Volatility 1e6 precision

    // Max breadth: 100% (10M units in 0.0001% base)
    uint256 private constant MAX_BREADTH = 10_000_000;

    // ========== ERRORS ==========

    error InvalidSegmentCount();
    error InvalidWeightSum();
    error InvalidOffsetRange();
    error InvalidBreadthConfig();
    error NoLiquidity();

    // ========== BREADTH CALCULATION ==========

    /// @notice Calculate dynamic breadth based on volatility
    /// @dev breadth = min(baseBreadth + volatility × κ, maxBreadth)
    /// @param profile Liquidity profile with breadth config
    /// @param volatility Baseline volatility (1e6 precision, 100% = 100_000_000)
    /// @return breadth Dynamic breadth in bps (1M precision)
    function calculateBreadth(
        IBAMM.LiquidityProfile storage profile,
        uint32 volatility
    )
        internal
        view
        returns (uint32 breadth)
    {
        unchecked {
            // rawBreadth = baseBreadth + (volatility × κ / VOL_BASE)
            uint256 volTerm = (uint256(volatility) * uint256(profile.volKappa)) / VOL_BASE;
            uint256 rawBreadth = uint256(profile.baseBreadth) + volTerm;

            // Cap at maxBreadth
            breadth = rawBreadth > profile.maxBreadth
                ? profile.maxBreadth
                : uint32(rawBreadth);
        }
    }

    // ========== KNOT PRICE CALCULATION ==========

    /// @notice Convert offset percentage to absolute price
    /// @dev knotPrice = TWAP × (1 + (endOffset × breadth / 100) / BPS_BASE)
    /// @param twap Reference TWAP price (1e18)
    /// @param endOffset Offset as % of breadth (-100 to +100)
    /// @param breadth Breadth in bps (1M precision)
    /// @return price Knot price (1e18)
    function offsetToPrice(
        uint256 twap,
        int8 endOffset,
        uint32 breadth
    )
        internal
        pure
        returns (uint256 price)
    {
        unchecked {
            // offsetBps = endOffset × breadth / 100
            int256 offsetBps = (int256(int16(endOffset)) * int256(uint256(breadth))) / 100;

            // price = TWAP × (BPS_BASE + offsetBps) / BPS_BASE
            int256 multiplier = int256(BPS_BASE) + offsetBps;
            if (multiplier < 0) multiplier = 0; // Floor at 0

            price = (twap * uint256(multiplier)) / BPS_BASE;
        }
    }

    // ========== SEGMENT LIQUIDITY CALCULATION ==========

    /// @notice Calculate liquidity available in a segment
    /// @param totalReserves Total pool reserves
    /// @param weight Segment weight (0-255)
    /// @return liquidity Liquidity in this segment
    function segmentLiquidity(
        uint256 totalReserves,
        uint8 weight
    )
        internal
        pure
        returns (uint256 liquidity)
    {
        unchecked {
            // liquidity = totalReserves × weight / 255
            liquidity = (totalReserves * uint256(weight)) / 255;
        }
    }

    // ========== SWAP PRICING ==========

    /// @notice Quote swap using Makima cubic spline
    /// @dev Walks through segments, integrating cubic price curve
    /// @param amountIn Amount to swap
    /// @param totalReserves Total pool reserves
    /// @param profile Liquidity profile
    /// @param twap Current TWAP (1e18)
    /// @param volatility Baseline volatility (1e6)
    /// @return amountOut Amount received
    /// @return avgPrice Weighted average execution price (1e18)
    function quoteSwap(
        uint256 amountIn,
        uint256 totalReserves,
        IBAMM.LiquidityProfile storage profile,
        uint256 twap,
        uint32 volatility,
        uint8 segmentCount
    )
        internal
        view
        returns (uint256 amountOut, uint256 avgPrice)
    {
        if (amountIn == 0) return (0, twap);
        if (totalReserves == 0) revert NoLiquidity();

        // Calculate current breadth
        uint32 breadth = calculateBreadth(profile, volatility);

        uint256 remaining = amountIn;
        uint256 totalCost = 0;

        // Lower bound price (segment 0 starts at -100)
        uint256 prevPrice = offsetToPrice(twap, -100, breadth);
        int32 prevSlope = 0; // Flat at lower bound

        // Walk segments
        for (uint256 i = 0; i < segmentCount && remaining > 0; ++i) {
            // Load segment
            (uint8 weight, int8 endOffset, int32 slope) = profile.segments.get(i);

            // Calculate knot prices
            uint256 rightPrice = offsetToPrice(twap, endOffset, breadth);

            // Segment liquidity
            uint256 segLiq = segmentLiquidity(totalReserves, weight);
            if (segLiq == 0) {
                prevPrice = rightPrice;
                prevSlope = slope;
                continue;
            }

            // Amount to consume in this segment
            uint256 fillAmount = remaining > segLiq ? segLiq : remaining;

            // Calculate segment cost using cubic Hermite integration
            // t0 = 0 (start of segment), t1 = fillAmount/segLiq (fractional fill)
            uint256 t1 = (fillAmount * WAD) / segLiq;
            if (t1 > WAD) t1 = WAD;

            uint256 segmentWidth = rightPrice > prevPrice ? rightPrice - prevPrice : 0;

            uint256 cost = LibMakima.computeSegmentCost(
                0,               // t0
                t1,              // t1
                prevPrice,       // y0
                rightPrice,      // y1
                prevSlope,       // slope0
                slope,           // slope1
                segmentWidth,
                fillAmount
            );

            totalCost += cost;
            remaining -= fillAmount;

            // Update for next segment
            prevPrice = rightPrice;
            prevSlope = slope;
        }

        // Calculate average price and amount out
        if (totalCost == 0) return (0, twap);

        avgPrice = totalCost.divWad(amountIn);
        amountOut = amountIn.divWad(avgPrice);
    }

    // ========== SEGMENT LOCATION ==========

    /// @notice Find segment containing given price (linear scan)
    /// @dev For n ≤ 32, linear scan is cheaper than binary search
    /// @param profile Liquidity profile
    /// @param targetPrice Price to locate (1e18)
    /// @param twap Reference TWAP (1e18)
    /// @param breadth Current breadth (bps)
    /// @return segmentIndex Index of segment containing price
    function locateSegment(
        IBAMM.LiquidityProfile storage profile,
        uint256 targetPrice,
        uint256 twap,
        uint32 breadth,
        uint8 segmentCount
    )
        internal
        view
        returns (uint256 segmentIndex)
    {
        unchecked {
            uint256 lowerBound = offsetToPrice(twap, -100, breadth);

            // If below lower bound, return segment 0
            if (targetPrice <= lowerBound) return 0;

            // Linear scan through segments
            for (uint256 i = 0; i < segmentCount; ++i) {
                (, int8 endOffset,) = profile.segments.get(i);
                uint256 rightPrice = offsetToPrice(twap, endOffset, breadth);

                if (targetPrice <= rightPrice) {
                    return i;
                }
            }

            // If above all segments, return last segment
            return segmentCount > 0 ? segmentCount - 1 : 0;
        }
    }

    // ========== CONFIGURATION VALIDATION ==========

    /// @notice Validate liquidity profile configuration
    /// @param params Profile parameters
    function validateProfile(IBAMM.LiquidtyConfig memory params) internal pure {
        uint256 segmentCount = params.weights.length;

        // Check segment count
        if (segmentCount < 2 || segmentCount > 32) {
            revert InvalidSegmentCount();
        }

        // Check array lengths match
        if (params.endOffsets.length != segmentCount) revert InvalidSegmentCount();
        if (params.slopes.length != segmentCount) revert InvalidSegmentCount();

        // Check weight sum = 255
        uint256 weightSum = 0;
        for (uint256 i = 0; i < segmentCount; ++i) {
            weightSum += params.weights[i];
        }
        if (weightSum != 255) revert InvalidWeightSum();

        // Check offsets in valid range and monotone increasing
        int8 prevOffset = -100;
        for (uint256 i = 0; i < segmentCount; ++i) {
            int8 offset = params.endOffsets[i];
            if (offset < -100 || offset > 100) revert InvalidOffsetRange();
            if (offset <= prevOffset) revert InvalidOffsetRange(); // Must be strictly increasing
            prevOffset = offset;
        }

        // Check breadth config
        if (params.baseBreadth == 0 || params.baseBreadth >= params.maxBreadth) {
            revert InvalidBreadthConfig();
        }
        if (params.maxBreadth > MAX_BREADTH) revert InvalidBreadthConfig();
    }

    /// @notice Set liquidity profile from parameters
    /// @param profile Storage profile to update
    /// @param params Configuration parameters
    function setProfile(
        IBAMM.LiquidityProfile storage profile,
        IBAMM.LiquidtyConfig memory params
    )
        internal
    {
        // Validate first
        validateProfile(params);

        // Set global config
        profile.baseBreadth = params.baseBreadth;
        profile.maxBreadth = params.maxBreadth;
        profile.volKappa = params.volKappa;

        // Clear old segments
        for (uint256 i = 0; i < 32; ++i) {
            profile.segments.set(i, 0, 0, 0);
        }

        // Set new segments
        for (uint256 i = 0; i < params.weights.length; ++i) {
            profile.segments.set(
                i,
                params.weights[i],
                params.endOffsets[i],
                params.slopes[i]
            );
        }
    }
}
