// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IOracle
/// @notice Shared interface for all oracle types (internal and external)
/// @dev This interface allows BAMM to uniformly read from any oracle type
///      All prices use b64 float format (56-bit mantissa, 8-bit signed exponent)
///      Format: uint64 = (mantissa << 8) | uint8(exponent + 128)
///      All volatility uses 1e6 base (1_000_000 = 1%)
interface IOracle {

    // ========== TYPES ==========

    /// @notice Oracle data structure
    /// @dev For internal oracles: Prices use accumulator pattern, volatility uses EMA
    /// @dev For external oracles: Both prices and volatility can use any methodology
    struct OracleData {
        uint64 fastTWAP;          // Fast price (shorter window, e.g., ~6 hours)
        uint64 slowTWAP;          // Slow price (longer window, e.g., ~1 week)
        uint32 fastVolatility;    // Fast volatility (1e6 base: 1_000_000 = 1%)
        uint32 slowVolatility;    // Slow volatility (1e6 base: 1_000_000 = 1%)
        uint32 lastUpdate;        // Timestamp of last update
    }

    // ========== VIEW FUNCTIONS ==========
    // These functions MUST be implemented by both internal and external oracles

    /// @notice Get oracle data for a specific oracle ID
    /// @dev Oracle ID = keccak256(abi.encodePacked(baseAsset, quoteAsset))
    /// @param oracleId Oracle identifier (base/quote pair hash)
    /// @return data Oracle data with fast/slow TWAPs, volatility, and timestamp
    function getOracleData(bytes32 oracleId) external view returns (OracleData memory data);

    /// @notice Check if oracle data is fresh
    /// @param oracleId Oracle identifier to check
    /// @param maxAge Maximum acceptable age in seconds
    /// @return isFresh True if data is fresh
    function isFresh(bytes32 oracleId, uint32 maxAge) external view returns (bool isFresh);

    /// @notice Get just the fast TWAP (most gas efficient)
    /// @param oracleId Oracle identifier to query
    /// @return fastTWAP Current fast TWAP in b64 format
    function getFastPrice(bytes32 oracleId) external view returns (uint64 fastTWAP);
}
