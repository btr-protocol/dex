// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FPMaths as FPMath} from "solady/utils/FixedPointMathLib.sol";
import {BAMMErrors as E} from "../bamm/BAMMErrors.sol";

/// @title LibMaths
/// @notice Library for mathematical operations including B64 encoding/decoding and decimal conversions
library LibMaths {
    // ========== CONSTANTS ==========

    /// @notice Fee precision: 1,000,000 base (1 unit = 0.0001% = 0.01 bps)
    /// @dev Allows expressing 0.5 bps (0.005%) as 50 units
    /// @dev Max uint32 safe: 65000 = 6.5% (hard cap for safety)
    /// @dev Max theoretical: 4,294,967,295 = 429,496.7% (uint32.max, not used)
    uint256 internal constant BPS_PRECISION = 1_000_000;
    uint256 internal constant MAX_FEE_BPS = 65_000; // 6.5% hard cap
    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant PRICE_PRECISION = 1e18;

    /// @notice Liquidity index initial value (lower than PRECISION for overflow protection)
    /// @dev Starts at 1e12, can grow to uint128.max ≈ 3.4e38 (growth factor of 3.4e26x)
    /// @dev This allows billions of swaps with compound fee accumulation without overflow
    /// @dev With 0.1% fee per swap: 1 billion swaps → index can grow ~1e434342x (theoretical)
    /// @dev But practical limit is uint128.max, giving 3.4e26x growth = 340 quadrillion-fold
    uint256 internal constant INDEX_PRECISION = 1e12;

    uint256 internal constant B64_MANTISSA_BITS = 52;
    uint256 internal constant B64_EXPONENT_BITS = 5;
    uint256 internal constant B64_DECIMAL_BITS = 7;

    uint256 internal constant B64_MANTISSA_MASK = (1 << B64_MANTISSA_BITS) - 1;
    uint256 internal constant B64_EXPONENT_MASK = (1 << B64_EXPONENT_BITS) - 1;
    uint256 internal constant B64_DECIMAL_MASK = (1 << B64_DECIMAL_BITS) - 1;

    uint256 internal constant B64_EXPONENT_SHIFT = B64_DECIMAL_BITS;
    uint256 internal constant B64_MANTISSA_SHIFT = B64_DECIMAL_BITS + B64_EXPONENT_BITS;

    uint256 internal constant B64_MAX_EXPONENT = (1 << B64_EXPONENT_BITS) - 1;

    // B64 52/5/7 encoding constants (52-bit mantissa, 5-bit decimals, 7-bit exponent)
    uint256 internal constant MAX_MANTISSA = (1 << B64_MANTISSA_BITS) - 1;
    int256 internal constant EXPONENT_BIAS = 64;
    int256 internal constant MIN_EXP = -64;
    int256 internal constant MAX_EXP = 63;

    uint256 internal constant MIN_SEGMENTS = 3;
    uint256 internal constant MAX_SEGMENTS = 32;

    uint256 internal constant WEIGHT_SUM = 255;

    uint8 internal constant BREADTH_PRECISION_DECIMALS = 2;

    // ========== ERRORS ==========

    error ZeroPrice();
    error ExponentOverflow();
    error MantissaOverflow();
    error InvalidDecimals();

    // ========== B64 POWER OF 10 HELPER ==========

    /// @notice Optimized power-of-10 calculation using binary exponentiation
    /// @dev Valid for exponent in [0, 77], reverts for exponent > 77
    /// @param exponent Exponent (0-77)
    /// @return result 10^exponent
    function _pow10(uint256 exponent) private pure returns (uint256 result) {
        if (exponent > 77) revert InvalidDecimals();

        assembly {
            result := 1
            let base := 10
            let e := exponent

            // Binary exponentiation: calculate 10^e
            for {} gt(e, 0) {} {
                // If e is odd, multiply result by base
                if and(e, 1) { result := mul(result, base) }
                // Square base for next iteration
                base := mul(base, base)
                // Divide e by 2 (right shift by 1)
                e := shr(1, e)
            }
        }
    }

    // ========== B64 ENCODING ==========

    /// @notice Encode price to B64 52/5/7 format
    /// @param price Price in native token decimals
    /// @param decimals Token decimal count (0-31)
    /// @return packed Encoded uint64
    function encodePrice(uint256 price, uint8 decimals) internal pure returns (uint64 packed) {
        if (price == 0) revert ZeroPrice();
        if (decimals > 31) revert InvalidDecimals();

        // Start with value and zero exponent
        uint256 mant = price;
        int256 exp = 0;

        // Normalize mantissa to fit in 52 bits while maximizing precision
        // Target: mantissa between MAX_MANTISSA/10 and MAX_MANTISSA

        // If too large, scale down
        while (mant > MAX_MANTISSA) {
            mant = (mant + 5) / 10; // Round half-up
            exp++;
        }

        // If too small, scale up (but don't go below MIN_EXP)
        while (mant < MAX_MANTISSA / 10 && exp > MIN_EXP) {
            mant *= 10;
            exp--;
        }

        // Check bounds
        if (exp < MIN_EXP || exp > MAX_EXP) revert ExponentOverflow();
        if (mant > MAX_MANTISSA) revert MantissaOverflow();

        // Pack: mantissa (52 bits) | decimals (5 bits) | exponent+bias (7 bits)
        uint256 expBiased = uint256(int256(exp + EXPONENT_BIAS));
        packed = uint64((mant << 12) | (uint256(decimals) << 7) | expBiased);
    }

    // ========== B64 DECODING ==========

    /// @notice Decode B64 to target decimal precision
    /// @param packed Encoded uint64
    /// @param targetDecimals Target decimal precision
    /// @return price Price in target decimals
    function decodePrice(uint64 packed, uint8 targetDecimals) internal pure returns (uint256 price) {
        if (packed == 0) revert ZeroPrice();

        // Extract components
        uint256 mant = uint256(packed >> 12);
        uint8 storedDecimals = uint8((packed >> 7) & 0x1F);
        int256 exp = int256(uint256(packed & 0x7F)) - EXPONENT_BIAS;

        if (mant == 0) revert ZeroPrice();

        // Calculate total exponent shift needed
        // value = mant × 10^exp (stored)
        // We want: value × 10^targetDecimals / 10^storedDecimals
        // = mant × 10^(exp + targetDecimals - storedDecimals)
        int256 totalShift = exp + int256(uint256(targetDecimals)) - int256(uint256(storedDecimals));

        if (totalShift < -77 || totalShift > 77) revert ExponentOverflow();

        // Apply shift using precomputed powers (no EXP opcode = gas efficient)
        if (totalShift >= 0) {
            price = mant * _pow10(uint256(totalShift));
        } else {
            // Scale down - careful division to minimize rounding
            price = mant / _pow10(uint256(-totalShift));
        }
    }

    /// @notice Decode B64 to standard 1e18 precision (for calculations)
    /// @param packed Encoded uint64
    /// @return price Price in 1e18 format
    function decodePriceTo1e18(uint64 packed) internal pure returns (uint256 price) {
        return decodePrice(packed, 18);
    }

    /// @notice Decode B64 to Chainlink standard 1e8 precision
    /// @dev For external integrations requiring 1e8 format (e.g., Chainlink compatibility)
    /// @dev Use decodePriceTo1e18() for internal calculations to maintain precision
    /// @param packed Encoded uint64
    /// @return price Price in 1e8 format
    function decodePriceTo1e8(uint64 packed) internal pure returns (uint256 price) {
        return decodePrice(packed, 8);
    }

    /// @notice Get stored decimals from packed B64 value
    /// @param packed Encoded uint64
    /// @return decimals Decimal count (0-31)
    function getDecimals(uint64 packed) internal pure returns (uint8 decimals) {
        return uint8((packed >> 7) & 0x1F);
    }

    // ========== B64 EMA UPDATES (for oracle TWAPs) ==========

    /// @notice Update EMA with new price sample
    /// @param currentEMA Current EMA value (B64 format)
    /// @param newPrice New price sample (B64 format)
    /// @param weight EMA weight in percentage (e.g., 90 for 90% weight on old value)
    /// @return newEMA Updated EMA value (B64 format)
    function updateEMA(
        uint64 currentEMA,
        uint64 newPrice,
        uint256 weight
    ) internal pure returns (uint64 newEMA) {
        if (newPrice == 0) return currentEMA;
        if (currentEMA == 0) return newPrice;
        if (weight >= 100) return currentEMA;

        // Decode both to 1e18 for computation
        uint256 ema = decodePriceTo1e18(currentEMA);
        uint256 price = decodePriceTo1e18(newPrice);

        // newEMA = (weight × ema + (100 - weight) × price) / 100
        uint256 updated = (weight * ema + (100 - weight) * price) / 100;

        // Re-encode using decimals from currentEMA
        uint8 decimals = getDecimals(currentEMA);

        // Convert back from 1e18 to original decimals
        uint256 valueInOriginalDecimals;
        if (decimals <= 18) {
            valueInOriginalDecimals = updated / _pow10(18 - decimals);
        } else {
            valueInOriginalDecimals = updated * _pow10(decimals - 18);
        }

        return encodePrice(valueInOriginalDecimals, decimals);
    }

    /// @notice Calculate volatility from price changes
    /// @param oldPrice Previous price (B64 format)
    /// @param newPrice Current price (B64 format)
    /// @return volatility Volatility in 1e6 base (1_000_000 = 1%)
    function calculateVolatility(
        uint64 oldPrice,
        uint64 newPrice
    ) internal pure returns (uint32 volatility) {
        if (oldPrice == 0 || newPrice == 0) return 10_000_000; // Default 10%

        uint256 old = decodePriceTo1e18(oldPrice);
        uint256 current = decodePriceTo1e18(newPrice);

        if (old == 0) return 10_000_000;

        // Calculate absolute percentage change in 1e6 base
        uint256 diff = old > current ? old - current : current - old;
        uint256 vol = (diff * 1_000_000) / old;

        // Cap at uint32 max
        volatility = vol > type(uint32).max ? type(uint32).max : uint32(vol);
    }

    /// @notice Update volatility EMA
    /// @param currentVol Current volatility EMA (1e6 base)
    /// @param newVol New volatility sample (1e6 base)
    /// @param weight EMA weight (e.g., 90 for 90% weight on old value)
    /// @return newVolEMA Updated volatility EMA
    function updateVolatilityEMA(
        uint32 currentVol,
        uint32 newVol,
        uint256 weight
    ) internal pure returns (uint32 newVolEMA) {
        if (currentVol == 0) return newVol;
        if (weight >= 100) return currentVol;

        uint256 updated = (weight * uint256(currentVol) + (100 - weight) * uint256(newVol)) / 100;
        newVolEMA = updated > type(uint32).max ? type(uint32).max : uint32(updated);
    }

    /// @notice Check if price is within deviation bounds (for circuit breakers)
    /// @param price1 First price (B64 format)
    /// @param price2 Second price (B64 format)
    /// @param maxDeviationBps Maximum deviation in basis points
    /// @return withinBounds True if prices are within bounds
    function checkDeviation(
        uint64 price1,
        uint64 price2,
        uint16 maxDeviationBps
    ) internal pure returns (bool withinBounds) {
        if (price1 == 0 || price2 == 0) return false;

        // Decode both to 1e18 for comparison (higher precision for extreme ratios)
        uint256 p1 = decodePriceTo1e18(price1);
        uint256 p2 = decodePriceTo1e18(price2);

        if (p1 == 0 || p2 == 0) return false;

        // Calculate deviation in bps
        uint256 diff = p1 > p2 ? p1 - p2 : p2 - p1;
        uint256 deviationBps = (diff * 10000) / (p1 > p2 ? p2 : p1);

        withinBounds = deviationBps <= maxDeviationBps;
    }

    // ========== FORMAT CONVERSIONS ==========

    /// @notice Convert b64 float to PRICE_PRECISION (1e18) format
    /// @dev Uses 1e18 for maximum precision in calculations - essential for extreme price ratios
    /// @dev Example: SHIB worth 1e-20 BTC maintains precision with 1e18 scaling
    /// @param b64Value Price in b64 float format
    /// @return price Price in 1e18 format
    function b64ToPrice(uint64 b64Value) internal pure returns (uint256 price) {
        return decodePriceTo1e18(b64Value);
    }

    /// @notice Adjust amount from one decimal precision to another
    /// @param amount Amount in source decimals
    /// @param fromDecimals Source decimal count
    /// @param toDecimals Target decimal count
    /// @return adjusted Amount in target decimals
    function adjustDecimals(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals
    ) internal pure returns (uint256 adjusted) {
        if (fromDecimals == toDecimals) {
            return amount;
        } else if (fromDecimals > toDecimals) {
            uint256 diff = fromDecimals - toDecimals;
            if (diff > 77) revert E.InvalidParameter(); // Prevent huge exponents
            return amount / (10 ** diff);
        } else {
            uint256 diff = toDecimals - fromDecimals;
            if (diff > 77) revert E.InvalidParameter();
            return amount * (10 ** diff);
        }
    }

    /// @notice Convert basis points to numerator/denominator fraction
    /// @param bps Basis points value
    /// @return numerator Fraction numerator
    /// @return denominator Fraction denominator (always BPS_PRECISION)
    function bpsToFraction(uint256 bps) internal pure returns (uint256 numerator, uint256 denominator) {
        return (bps, BPS_PRECISION);
    }

    /// @notice Convert volatility (1e6 base) to basis points (1e4 base)
    /// @param vol Volatility in 1e6 base (1_000_000 = 1%)
    /// @return bps Volatility in basis points (100 = 1%)
    function volatilityToBps(uint32 vol) internal pure returns (uint256 bps) {
        // Convert 1e6 base to 1e4 base: divide by 100
        return uint256(vol) / 100;
    }

    /// @notice Convert basis points to volatility format
    /// @param bps Basis points (100 = 1%)
    /// @return vol Volatility in 1e6 base (1_000_000 = 1%)
    function bpsToVolatility(uint256 bps) internal pure returns (uint32 vol) {
        // Convert 1e4 base to 1e6 base: multiply by 100
        uint256 v = bps * 100;
        if (v > type(uint32).max) revert E.Overflow();
        return uint32(v);
    }

    // NOTE: Custom mulDiv removed - use FPMath.fullMulDiv instead
    // NOTE: Trivial math helpers (min/max/abs/clamp) removed for conciseness
    // Use inline ternaries instead: a < b ? a : b, a > b ? a : b, etc.
    // This reduces bytecode and makes operations more explicit at call sites

    // ========== PRICE CALCULATIONS ==========

    /// @notice Calculate value from amount and price
    /// @dev value = (amount × price) / PRICE_PRECISION, with decimal adjustment
    /// @param amount Token amount in native decimals
    /// @param amountDecimals Decimal count of amount
    /// @param price1e18 Price in PRICE_PRECISION (1e18) format
    /// @param valueDecimals Desired decimal count for output value
    /// @return value Value in specified decimals
    function calculateValue(
        uint256 amount,
        uint8 amountDecimals,
        uint256 price1e18,
        uint8 valueDecimals
    ) internal pure returns (uint256 value) {
        // First calculate value in amountDecimals precision
        // value = amount * price / 1e18
        uint256 rawValue = FPMath.fullMulDiv(amount, price1e18, PRICE_PRECISION);

        // Adjust from amountDecimals to valueDecimals
        return adjustDecimals(rawValue, amountDecimals, valueDecimals);
    }

    /// @notice Calculate amount from value and price
    /// @dev amount = (value × PRICE_PRECISION) / price, with decimal adjustment
    /// @param value Value in source decimals
    /// @param valueDecimals Decimal count of value
    /// @param price1e18 Price in PRICE_PRECISION (1e18) format
    /// @param targetDecimals Desired decimal count for output amount
    /// @return amount Amount in target decimals
    function calculateAmount(
        uint256 value,
        uint8 valueDecimals,
        uint256 price1e18,
        uint8 targetDecimals
    ) internal pure returns (uint256 amount) {
        if (price1e18 == 0) revert E.InvalidPrice();

        // First adjust value to target decimals
        uint256 adjustedValue = adjustDecimals(value, valueDecimals, targetDecimals);

        // Calculate amount = adjustedValue * PRICE_PRECISION / price
        return FPMath.fullMulDiv(adjustedValue, PRICE_PRECISION, price1e18);
    }

    /// @notice Calculate token value using b64 price directly
    /// @dev Convenience function that decodes b64 and calculates value
    /// @param amount Token amount in native decimals
    /// @param amountDecimals Decimal count of amount
    /// @param b64Price Price in b64 format
    /// @param valueDecimals Desired decimal count for output
    /// @return value Calculated value
    function calculateValueB64(
        uint256 amount,
        uint8 amountDecimals,
        uint64 b64Price,
        uint8 valueDecimals
    ) internal pure returns (uint256 value) {
        uint256 price1e18 = b64ToPrice(b64Price);
        return calculateValue(amount, amountDecimals, price1e18, valueDecimals);
    }

    /// @notice Convert between two assets using their prices
    /// @dev amountOut = (amountIn × priceIn) / priceOut, with decimal adjustments
    /// @param amountIn Input amount
    /// @param priceIn Input asset price (1e18)
    /// @param decimalsIn Input asset decimals
    /// @param priceOut Output asset price (1e18)
    /// @param decimalsOut Output asset decimals
    /// @return amountOut Output amount
    function convertAssets(
        uint256 amountIn,
        uint256 priceIn,
        uint8 decimalsIn,
        uint256 priceOut,
        uint8 decimalsOut
    ) internal pure returns (uint256 amountOut) {
        if (priceOut == 0) revert E.InvalidPrice();

        // Calculate value in 1e18 terms
        uint256 value = FPMath.fullMulDiv(amountIn, priceIn, PRICE_PRECISION);

        // Adjust decimals: from decimalsIn to decimalsOut
        uint256 adjustedValue = adjustDecimals(value, decimalsIn, decimalsOut);

        // Convert value to output amount
        return FPMath.fullMulDiv(adjustedValue, PRICE_PRECISION, priceOut);
    }

    // ========== FEE CALCULATIONS ==========

    /// @notice Apply fee to amount
    /// @param amount Amount before fee
    /// @param feeBps Fee in basis points
    /// @return amountAfterFee Amount after deducting fee
    /// @return feeAmount Fee amount deducted
    function applyFee(
        uint256 amount,
        uint256 feeBps
    ) internal pure returns (uint256 amountAfterFee, uint256 feeAmount) {
        if (feeBps > BPS_PRECISION) revert E.InvalidParameter();

        feeAmount = FPMath.fullMulDiv(amount, feeBps, BPS_PRECISION);
        amountAfterFee = amount - feeAmount;
    }

    /// @notice Calculate fee amount only
    /// @param amount Amount to calculate fee on
    /// @param feeBps Fee in basis points
    /// @return feeAmount Calculated fee
    function calculateFee(uint256 amount, uint256 feeBps) internal pure returns (uint256 feeAmount) {
        if (feeBps > BPS_PRECISION) revert E.InvalidParameter();
        return FPMath.fullMulDiv(amount, feeBps, BPS_PRECISION);
    }

    /// @notice Split amount according to basis points
    /// @param amount Total amount to split
    /// @param splitBps Basis points for first portion
    /// @return portion1 First portion (splitBps of amount)
    /// @return portion2 Remaining portion
    function splitByBps(
        uint256 amount,
        uint256 splitBps
    ) internal pure returns (uint256 portion1, uint256 portion2) {
        if (splitBps > BPS_PRECISION) revert E.InvalidParameter();

        portion1 = FPMath.fullMulDiv(amount, splitBps, BPS_PRECISION);
        portion2 = amount - portion1;
    }

    // ========== PERCENTAGE CALCULATIONS ==========

    /// @notice Calculate percentage change between two values
    /// @param oldValue Original value
    /// @param newValue New value
    /// @return changeBps Change in basis points (can be negative)
    function percentageChange(
        uint256 oldValue,
        uint256 newValue
    ) internal pure returns (int256 changeBps) {
        if (oldValue == 0) return 0;

        if (newValue >= oldValue) {
            uint256 increase = newValue - oldValue;
            uint256 increaseBps = FPMath.fullMulDiv(increase, BPS_PRECISION, oldValue);
            return int256(increaseBps);
        } else {
            uint256 decrease = oldValue - newValue;
            uint256 decreaseBps = FPMath.fullMulDiv(decrease, BPS_PRECISION, oldValue);
            return -int256(decreaseBps);
        }
    }

    /// @notice Calculate absolute percentage difference between two values
    /// @param value1 First value
    /// @param value2 Second value
    /// @return diffBps Absolute difference in basis points
    function percentageDiff(uint256 value1, uint256 value2) internal pure returns (uint256 diffBps) {
        if (value1 == 0 && value2 == 0) return 0;
        if (value1 == 0 || value2 == 0) return BPS_PRECISION; // 100% difference

        uint256 diff = value1 > value2 ? value1 - value2 : value2 - value1;
        uint256 base = value1 > value2 ? value2 : value1; // Use smaller as base

        return FPMath.fullMulDiv(diff, BPS_PRECISION, base);
    }

    // ========== INTERPOLATION ==========

    /// @notice Linear interpolation between two values
    /// @param value0 Value at position 0
    /// @param value1 Value at position 1
    /// @param position Position between 0 and PRECISION (1e18 = position 1)
    /// @return interpolated Interpolated value
    function lerp(
        uint256 value0,
        uint256 value1,
        uint256 position
    ) internal pure returns (uint256 interpolated) {
        if (position > PRECISION) revert E.InvalidParameter();

        if (position == 0) return value0;
        if (position == PRECISION) return value1;

        // interpolated = value0 + (value1 - value0) * position / PRECISION
        if (value1 >= value0) {
            uint256 delta = value1 - value0;
            return value0 + FPMath.fullMulDiv(delta, position, PRECISION);
        } else {
            uint256 delta = value0 - value1;
            return value0 - FPMath.fullMulDiv(delta, position, PRECISION);
        }
    }

    /// @notice Linear interpolation with custom precision base
    /// @param value0 Value at position 0
    /// @param value1 Value at position 1
    /// @param position Position in custom base
    /// @param maxPosition Maximum position value (defines 100%)
    /// @return interpolated Interpolated value
    function lerpCustom(
        uint256 value0,
        uint256 value1,
        uint256 position,
        uint256 maxPosition
    ) internal pure returns (uint256 interpolated) {
        if (position > maxPosition) revert E.InvalidParameter();
        if (maxPosition == 0) revert E.DivisionByZero();

        if (position == 0) return value0;
        if (position == maxPosition) return value1;

        // Convert position to PRECISION base and use lerp
        uint256 normalizedPosition = FPMath.fullMulDiv(position, PRECISION, maxPosition);
        return lerp(value0, value1, normalizedPosition);
    }
}
