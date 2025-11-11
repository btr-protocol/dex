// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IOracle
/// @notice Interface for external oracle contracts
/// @dev All prices use b64 float format (56-bit mantissa, 8-bit signed exponent)
///      Format: uint64 = (mantissa << 8) | uint8(exponent + 128)
interface IOracle {

    /// @notice Get current price and volatility data
    /// @return fastTWAP Fast TWAP in b64 format (~10min window)
    /// @return slowTWAP Slow TWAP in b64 format (~1hr window)
    /// @return fastVolatility Fast volatility (1e6 base: 1_000_000 = 1%)
    /// @return slowVolatility Slow volatility (1e6 base: 1_000_000 = 1%)
    /// @return lastUpdate Timestamp of last update
    function getOracleData() external view returns (
        uint64 fastTWAP,
        uint64 slowTWAP,
        uint32 fastVolatility,
        uint32 slowVolatility,
        uint32 lastUpdate
    );

    /// @notice Check if oracle data is fresh
    /// @param maxAge Maximum acceptable age in seconds
    /// @return isFresh True if data is fresh
    function isFresh(uint32 maxAge) external view returns (bool isFresh);

    /// @notice Get just the fast TWAP (most gas efficient)
    /// @return fastTWAP Current fast TWAP in b64 format
    function getFastPrice() external view returns (uint64 fastTWAP);
}
