// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPriceOracle
/// @notice Interface for price and volatility oracles (both internal and external)
/// @dev Supports both pool-internal oracles and external keeper-fed oracles
interface IPriceOracle {
    /// @notice Oracle data structure
    /// @dev All EMAs use exponential moving averages for smoothing
    struct OracleData {
        uint64 fastTWAP;      // Fast price EMA (shorter window, e.g., 10min)
        uint64 slowTWAP;      // Slow price EMA (longer window, e.g., 1hr)
        uint32 fastVolatility;    // Fast volatility EMA (base 1e6: 1_000_000 = 1%)
        uint32 slowVolatility;    // Slow volatility EMA (base 1e6: 1_000_000 = 1%)
        uint32 lastUpdate;        // Timestamp of last update
    }

    /// @notice Get current oracle data for an asset
    /// @param asset Asset address to query
    /// @return data Oracle data with fast/slow EMAs, volatility, and timestamp
    function getOracleData(address asset) external view returns (OracleData memory data);

    /// @notice Update oracle with new price and volatility data
    /// @dev Only callable by authorized keepers
    /// @param asset Asset address to update
    /// @param newPrice New spot price (B64 encoded - decodes to 1e18 precision internally)
    /// @param newVolatility New volatility measurement (base 1e6: 1_000_000 = 1%)
    function updateOracle(address asset, uint64 newPrice, uint32 newVolatility) external;

    /// @notice Check if oracle data is fresh
    /// @param asset Asset address to check
    /// @param maxAge Maximum acceptable age in seconds
    /// @return isFresh True if data is fresh
    function isFresh(address asset, uint256 maxAge) external view returns (bool isFresh);

    /// @notice Emitted when oracle is updated
    event OracleUpdated(
        address indexed asset,
        uint64 fastTWAP,
        uint64 slowTWAP,
        uint32 fastVolatility,
        uint32 slowVolatility,
        uint32 timestamp
    );
}
