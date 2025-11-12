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

    /// @notice Maximum price deviation per update (100% in basis points)
    uint256 internal constant MAX_DEVIATION_BPS = 10_000;

    /// @notice Basis points precision (100% = 10000 bps)
    uint256 internal constant BPS_PRECISION = 10_000;

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

    /// @notice Validate that deviation is within bounds
    /// @param deviationBps Deviation in basis points
    /// @return isValid True if deviation is valid
    function _validateDeviation(uint16 deviationBps) internal pure returns (bool isValid) {
        return deviationBps <= MAX_DEVIATION_BPS;
    }

    /// @notice Validate oracle data completeness
    /// @param data Oracle data to validate
    /// @return isValid True if all fields are valid
    function _validateOracleData(OracleData memory data) internal pure returns (bool isValid) {
        return _validatePrice(data.fastTWAP) &&
               _validatePrice(data.slowTWAP) &&
               _validateVolatility(data.fastVolatility) &&
               _validateVolatility(data.slowVolatility);
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
