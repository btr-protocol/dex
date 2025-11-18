// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOracle} from "../interfaces/IOracle.sol";

/// @title BaseOracle
/// @notice Abstract base contract with common oracle functionality
/// @dev Provides shared constants, validation helpers, and common patterns
///      for both internal (accumulator-based) and external (multi-asset) oracles
abstract contract BaseOracle is IOracle {

    // ========== CONSTANTS ==========

    /// @notice Maximum volatility value (100% in 1e6 base)
    uint256 internal constant MAX_VOLATILITY = 100_000_000;

    /// @notice Maximum deviation threshold (6.5% in 0.0001% precision)
    /// @dev 65_000 units = 6.5% (10_000 = 1%)
    ///      Stablecoins need tight thresholds (~10-50 = 0.1-0.5%)
    ///      Volatile assets max out at 6.5% to prevent excessive slippage
    uint256 internal constant MAX_DEV_THRESHOLD = 65_000;

    /// @notice Deviation threshold precision: 10,000 base (1 unit = 0.0001%, 10_000 = 1%)
    uint256 internal constant DEV_THRESHOLD_PRECISION = 10_000;

    // ========== VALIDATION HELPERS ==========

    /// @notice Validate that a price is non-zero
    /// @param price Price to validate
    /// @return isValid True if price is valid (non-zero)
    function _validatePrice(uint64 price) internal pure returns (bool isValid) {
        return price > 0;
    }

    /// @notice Validate that volatility is within bounds
    /// @param volatility Volatility to validate (1e6 base)
    /// @return isValid True if volatility is valid
    function _validateVolatility(uint32 volatility) internal pure returns (bool isValid) {
        return volatility <= MAX_VOLATILITY;
    }

    /// @notice Validate that deviation threshold is within bounds
    /// @param maxDeviation Deviation threshold (0.0001% precision: 10_000 = 1%)
    /// @return isValid True if deviation is valid (<= 6.5%)
    function _validatemaxDeviation(uint16 maxDeviation) internal pure returns (bool isValid) {
        return maxDeviation <= MAX_DEV_THRESHOLD;
    }

    /// @notice Validate oracle data completeness
    /// @param data Oracle data to validate
    /// @return isValid True if all fields are valid
    function _validateFeedData(FeedData memory data) internal pure returns (bool isValid) {
        return _validatePrice(data.fastEMA) &&
               _validatePrice(data.slowEMA) &&
               _validateVolatility(data.fastVolEMA) &&
               _validateVolatility(data.slowVolEMA);
    }

    /// @notice Calculate absolute difference between two uint64 values
    /// @param a First value
    /// @param b Second value
    /// @return delta Absolute difference
    function _absDiff64(uint64 a, uint64 b) internal pure returns (uint64 delta) {
        return a > b ? a - b : b - a;
    }

    /// @notice Calculate absolute difference between two uint256 values
    /// @param a First value
    /// @param b Second value
    /// @return delta Absolute difference
    function _absDiff256(uint256 a, uint256 b) internal pure returns (uint256 delta) {
        return a > b ? a - b : b - a;
    }
}
