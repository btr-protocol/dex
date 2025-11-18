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
    /// @dev Embeds common IOracle.FeedData and adds internal-specific accumulator fields
    /// @dev Total: 6 slots (192 bytes) - 1 slot for base FeedData + 3 for accumulators + 2 for config
    struct InternalFeedData {
        // SLOT 0: Embedded common feed data (shared with external oracles)
        IOracle.FeedData base;          // Fast/slow TWAPs, volatility EMAs, timestamp, TTL

        // SLOT 1-3: Accumulator state (internal oracle only)
        uint256 priceAccumulator;       // Σ(price × timeElapsed) - cumulative price-seconds
        uint256 fastAccumSnapshot;      // Accumulator value at last fast snapshot
        uint256 slowAccumSnapshot;      // Accumulator value at last slow snapshot

        // SLOT 4-5: Internal-specific config (30 bytes)
        uint64 currentPrice;            // Current spot price in b64 format (for accumulator)
        uint32 fastSnapshotTime;        // When fast TWAP was computed
        uint32 slowSnapshotTime;        // When slow TWAP was computed
        uint24 fastWindow;              // Fast TWAP window in seconds (max 194 days)
        uint24 slowWindow;              // Slow TWAP window in seconds (max 194 days)
        uint16 maxTWAPChange;           // Max price change per update (bps)
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
