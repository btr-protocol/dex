// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOracle} from "./IOracle.sol";

/// @title IInternalOracle
/// @notice Interface for BAMM's internal accumulator-based oracle
/// @dev Extends IOracle with internal-specific update and reset methods
///      Internal oracle manages a Uniswap V3-style TWAP accumulator per asset
interface IInternalOracle is IOracle {

    // ========== EVENTS ==========

    /// @notice Emitted when internal oracle is updated
    event OracleUpdate(
        bytes32 indexed oracleId,
        uint64 fastTWAP,
        uint64 slowTWAP,
        uint32 fastVolatility,
        uint32 slowVolatility,
        address indexed updater
    );

    /// @notice Emitted when oracle is reset (e.g., quote currency change)
    event OracleReset(
        bytes32 indexed oracleId,
        uint64 newPrice,
        uint32 newFastVolatility,
        uint32 newSlowVolatility
    );

    // ========== UPDATE FUNCTIONS ==========

    /// @notice Update internal oracle with new price and volatility data
    /// @dev Only callable by authorized roles (e.g., owner)
    /// @param oracleId Oracle identifier (keccak256 of base/quote pair)
    /// @param newPrice New spot price (b64 format)
    /// @param newVolatility New volatility measurement (1e6 base: 1_000_000 = 1%)
    function updateOracle(bytes32 oracleId, uint64 newPrice, uint32 newVolatility) external;

    /// @notice Reset oracle accumulator (e.g., after base/quote currency change)
    /// @dev Clears accumulator state and reinitializes with new values
    /// @param oracleId Oracle identifier to reset
    /// @param initialPrice Initial price (b64 format)
    /// @param initialFastVol Initial fast volatility (1e6 base)
    /// @param initialSlowVol Initial slow volatility (1e6 base)
    function resetOracle(
        bytes32 oracleId,
        uint64 initialPrice,
        uint32 initialFastVol,
        uint32 initialSlowVol
    ) external;
}
