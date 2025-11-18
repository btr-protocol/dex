// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title BAMM Custom Errors
/// @notice Centralized error definitions for gas efficiency
library BAMMErrors {
    // Common errors
    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error InvalidParameter();
    error Overflow();
    error AlreadyInitialized();
    error NotInitialized();
    error Locked();
    error Expired();
    error Paused();
    error DivisionByZero();

    // Asset errors
    error AssetFrozen();
    error AssetNotFound();
    error AssetAlreadyExists();
    error InsufficientReserves();
    error BelowMinimumLiquidity();

    // Oracle errors
    error InvalidPrice();
    error PriceChangeTooLarge();
    error OracleStale();
    error OracleInvalid();
    error CircuitBreakerTimestampSkew();
    error PriceTooLarge();

    // LP errors
    error InsufficientBalance();
    error SlippageExceeded();

    // Role errors
    error PendingAcceptance();
    error NoAcceptance();
    error InvalidRole();

    // Blacklist errors
    error Blacklisted();

    // Circuit breaker errors
    error ReservePriceViolation();           // Circuit Breaker #1: Price below reserve floor
    error DeviationCircuitBreakerTriggered(); // Circuit Breaker #2: Relative return divergence exceeded

    // Hook errors
    error InvalidHookContract(address hook, string missingFunction);

    // Flash loan errors
    error FlashLoanCallbackFailed();
    error PoolPaused();
    error InsufficientReservesForFlash(uint128 reserves, uint128 minLiquidity);
    error OracleStaleForFlash();

    // Migration errors
    error MigrationIncomplete(address token);
    error ConversionRateOutOfBounds(uint256 rate);
    error ReinitDataMismatch(uint256 expected, uint256 actual);
    error MissingReinitToken(address token);
    error ConversionOverflow(address token, uint256 value);

    // Fee parameter errors
    error InvalidFeeParams(string reason);

    // Liquidity profile errors
    error NormalizedWeightZero(uint256 index);
    error WeightSumMismatch(uint256 actual, uint256 expected);
    error OffsetsNotMonotonic(uint256 index, int8 left, int8 right);
    error OffsetOutOfBounds();

    // Volatility errors
    error VolatilityTooHigh(uint32 actual, uint32 max);

    // Liability swap errors
    error LiabilitySwapDisabled();
    error BelowMinimum();
    error InsufficientLiquidity();
}
