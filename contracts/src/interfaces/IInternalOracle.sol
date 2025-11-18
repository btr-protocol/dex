// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOracle} from "./IOracle.sol";

/// @title IInternalOracle
/// @notice Interface for BAMM's internal accumulator-based oracle
/// @dev Extends IOracle with internal-specific update and reset methods
///      Internal oracle manages a Uniswap V3-style TWAP accumulator per asset
interface IInternalOracle is IOracle {

    // ========== TYPES ==========

    /// @notice Internal oracle feed data with accumulator state
    /// @dev Embeds common IOracle.FeedData (single slot) + accumulator fields (3 slots)
    /// @dev Total: 4 slots (128 bytes) - highly optimized for EVM storage
    struct InternalFeedData {
        // SLOT 0: Single-slot feed data (shared with external oracles)
        IOracle.FeedData base;          // currentPrice, fastOffset, slowOffset, vols, timestamp, ttl, confidence

        // SLOT 1-3: Accumulator state (internal oracle only)
        uint256 priceAccumulator;       // Σ(price × timeElapsed) - cumulative price-seconds
        uint256 fastAccumSnapshot;      // Accumulator value at last fast TWAP snapshot
        uint256 slowAccumSnapshot;      // Accumulator value at last slow TWAP snapshot

        // SLOT 4: Internal-specific config (packed)
        uint32 fastSnapshotTime;        // When fast TWAP was last computed
        uint32 slowSnapshotTime;        // When slow TWAP was last computed
        uint24 fastWindow;              // Fast TWAP window in seconds (e.g., 300 = 5 min)
        uint24 slowWindow;              // Slow TWAP window in seconds (e.g., 3600 = 1 hr)
    }

    // ========== EVENTS ==========

    /// @notice Emitted when internal oracle is updated
    event OracleUpdate(
        bytes32 indexed feedId,
        uint64 fastTWAP,
        uint64 slowTWAP,
        uint32 fastVolEMA,
        uint32 slowVolEMA,
        address indexed updater
    );

    /// @notice Emitted when oracle is reset (e.g., quote currency change)
    event OracleReset(
        bytes32 indexed feedId,
        uint64 newPrice,
        uint32 newfastVolEMA,
        uint32 newslowVolEMA
    );

    // ========== UPDATE FUNCTIONS ==========

    /// @notice Update internal oracle with new price and volatility data
    /// @dev Only callable by authorized roles (e.g., owner)
    /// @param feedId Oracle identifier (keccak256 of base/quote pair)
    /// @param newPrice New spot price (b64 format)
    /// @param newVolatility New volatility measurement (1e6 base: 1_000_000 = 1%)
    function updateOracle(bytes32 feedId, uint64 newPrice, uint32 newVolatility) external;

    /// @notice Reset oracle accumulator (e.g., after base/quote currency change)
    /// @dev Clears accumulator state and reinitializes with new values
    /// @param feedId Oracle identifier to reset
    /// @param initialPrice Initial price (b64 format)
    /// @param fastVolEMA Initial fast volatility (1e6 base)
    /// @param slowVolEMA Initial slow volatility (1e6 base)
    function resetOracle(
        bytes32 feedId,
        uint64 initialPrice,
        uint32 fastVolEMA,
        uint32 slowVolEMA
    ) external;
}
