// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IInternalOracle} from "../interfaces/IInternalOracle.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {BaseOracle} from "../oracles/BaseOracle.sol";
import {BAMMErrors as E} from "./BAMMErrors.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";
import {LibUtils} from "../libraries/LibUtils.sol";
import {LibStorage as S} from "../libraries/LibStorage.sol";
import {BAMMStorage} from "./BAMMStorage.sol";

/// @title InternalOracle
/// @notice BAMM's internal accumulator-based oracle (Uniswap V3-style TWAP)
/// @dev Implements IInternalOracle - ONLY manages internal accumulator
/// @dev Does NOT handle external oracle reading - that's BAMM's responsibility
/// @dev Extends BaseOracle for common validation functionality
abstract contract InternalOracle is BAMMStorage, BaseOracle, IInternalOracle {

    // ========== HELPER FUNCTIONS ==========

    /// @notice Get all registered assets (returns array copy)
    function _getRegisteredAssets() internal view returns (address[] memory) {
        return _sb().registeredAssets;
    }

    /// @notice Get fast TWAP weight (hardcoded for gas efficiency)
    function _getFastTWAPWeight() internal pure returns (uint8) {
        return 128; // 50% weight (128/256)
    }

    /// @notice Get slow TWAP weight (hardcoded for gas efficiency)
    function _getSlowTWAPWeight() internal pure returns (uint8) {
        return 32; // ~12.5% weight (32/256)
    }

    // ========== ORACLE UPDATES ==========

    /// @notice Update internal oracle with new price and volatility data
    /// @dev Implements IInternalOracle.updateOracle
    /// @param feedId Oracle identifier (keccak256 of base/quote pair)
    /// @param newPrice New spot price (b64 format)
    /// @param newVolatility New volatility measurement (1e6 base: 1_000_000 = 1%)
    function updateOracle(bytes32 feedId, uint64 newPrice, uint32 newVolatility) external virtual override {
        IInternalOracle.InternalFeedData storage oracle = _getOracleEntry(feedId);
        if (oracle.base.updatedAt == 0) revert E.InvalidParameter(); // Oracle doesn't exist

        // Validate inputs
        if (!_validatePrice(newPrice)) revert E.InvalidPrice();
        if (!_validateVolatility(newVolatility)) revert E.InvalidParameter();

        // Bound volatility to [0, 100%]
        uint32 MAX_VOLATILITY = 100_000_000; // 100% in 1e6 base
        if (newVolatility > MAX_VOLATILITY) {
            revert E.VolatilityTooHigh(newVolatility, MAX_VOLATILITY);
        }

        // Cache timestamp to avoid repeated SLOAD operations (gas optimization)
        uint256 currentTime = block.timestamp;
        uint32 currentTime32 = uint32(currentTime);

        if (oracle.currentPrice == 0) {
            // First oracle update - initialize accumulator system
            oracle.currentPrice = newPrice;
            oracle.priceAccumulator = 0;
            oracle.fastAccumSnapshot = 0;
            oracle.fastSnapshotTime = currentTime32;
            oracle.slowAccumSnapshot = 0;
            oracle.slowSnapshotTime = currentTime32;
            oracle.base.fastVolEMA = newVolatility;
            oracle.base.slowVolEMA = newVolatility;
            oracle.base.updatedAt = currentTime32;

            // Emit event with initial values
            emit OracleUpdate(feedId, newPrice, newPrice, newVolatility, newVolatility, msg.sender);
        } else {
            // Check price change is within bounds (compare in 1e18 format for precision)
            uint256 oldPrice1e18 = M.decodePriceTo1e18(oracle.currentPrice);
            uint256 newPrice1e18 = M.decodePriceTo1e18(newPrice);
            uint256 priceDelta = newPrice1e18 > oldPrice1e18 ? newPrice1e18 - oldPrice1e18 : oldPrice1e18 - newPrice1e18;
            uint256 maxChange = (oldPrice1e18 * oracle.maxTWAPChange) / M.BPS_PRECISION;
            if (priceDelta > maxChange) revert E.PriceChangeTooLarge();

            // Update accumulator: Σ(price × timeElapsed) - Uniswap V3 pattern
            uint256 timeElapsed = currentTime - oracle.base.updatedAt;
            uint256 newAccumulator = oracle.priceAccumulator + uint256(oracle.currentPrice) * timeElapsed;
            oracle.priceAccumulator = newAccumulator;

            // Update current price
            oracle.currentPrice = newPrice;

            // Precompute TWAPs for event emission (avoid recomputing in event)
            uint64 fastTWAP;
            uint64 slowTWAP;

            // Update fast snapshot and compute fast TWAP
            uint256 fastAge = currentTime - oracle.fastSnapshotTime;
            if (fastAge >= oracle.fastWindow) {
                oracle.fastAccumSnapshot = newAccumulator;
                oracle.fastSnapshotTime = currentTime32;
            }
            // Compute fast TWAP from current accumulator state
            uint256 fastTimeDelta = currentTime - oracle.fastSnapshotTime;
            if (fastTimeDelta == 0) {
                fastTWAP = oracle.currentPrice;
            } else {
                uint256 fastAccumDelta = newAccumulator - oracle.fastAccumSnapshot;
                fastTWAP = uint64(fastAccumDelta / fastTimeDelta);
            }

            // Update slow snapshot and compute slow TWAP
            uint256 slowAge = currentTime - oracle.slowSnapshotTime;
            if (slowAge >= oracle.slowWindow) {
                oracle.slowAccumSnapshot = newAccumulator;
                oracle.slowSnapshotTime = currentTime32;
            }
            // Compute slow TWAP from current accumulator state
            uint256 slowTimeDelta = currentTime - oracle.slowSnapshotTime;
            if (slowTimeDelta == 0) {
                slowTWAP = oracle.currentPrice;
            } else {
                uint256 slowAccumDelta = newAccumulator - oracle.slowAccumSnapshot;
                slowTWAP = uint64(slowAccumDelta / slowTimeDelta);
            }

            // Update volatility using EMA (appropriate for variance smoothing)
            oracle.base.fastVolEMA = M.updateVolatilityEMA(oracle.base.fastVolEMA, newVolatility, _getFastTWAPWeight());
            oracle.base.slowVolEMA = M.updateVolatilityEMA(oracle.base.slowVolEMA, newVolatility, _getSlowTWAPWeight());

            oracle.base.updatedAt = currentTime32;

            // Emit event with precomputed TWAPs (no external calls or recomputation)
            emit OracleUpdate(feedId, fastTWAP, slowTWAP, oracle.base.fastVolEMA, oracle.base.slowVolEMA, msg.sender);
        }
    }

    /// @notice Reset oracle accumulator (e.g., after base/quote currency change)
    /// @dev Implements IInternalOracle.resetOracle
    /// @dev Clears accumulator state and reinitializes with new values
    /// @param feedId Oracle identifier to reset
    /// @param initialPrice Initial price (b64 format)
    /// @param fastVolEMA Initial fast vol (1e6 base)
    /// @param slowVolEMA Initial slow vol (1e6 base)
    function resetOracle(
        bytes32 feedId,
        uint64 initialPrice,
        uint32 fastVolEMA,
        uint32 slowVolEMA
    ) external virtual override {
        IInternalOracle.InternalFeedData storage oracle = _getOracleEntry(feedId);

        // Validate inputs
        if (!_validatePrice(initialPrice)) revert E.InvalidPrice();
        if (!_validateVolatility(fastVolEMA)) revert E.InvalidParameter();
        if (!_validateVolatility(slowVolEMA)) revert E.InvalidParameter();

        // Reset accumulator state to zero
        oracle.currentPrice = initialPrice;
        oracle.priceAccumulator = 0;
        oracle.fastAccumSnapshot = 0;
        oracle.fastSnapshotTime = uint32(block.timestamp);
        oracle.slowAccumSnapshot = 0;
        oracle.slowSnapshotTime = uint32(block.timestamp);
        oracle.base.fastVolEMA = fastVolEMA;
        oracle.base.slowVolEMA = slowVolEMA;
        oracle.base.updatedAt = uint32(block.timestamp);

        emit OracleReset(feedId, initialPrice, fastVolEMA, slowVolEMA);
    }

    // ========== IORACLE IMPLEMENTATION ==========

    /// @notice Get oracle data for a specific feed ID
    /// @dev Implements IOracle.getFeedData - reads from internal accumulator
    /// @param feedId Oracle identifier to query
    /// @return data Oracle data with fast/slow TWAPs, volatility, and timestamp
    function getFeedData(bytes32 feedId) external view virtual override returns (FeedData memory data) {
        IInternalOracle.InternalFeedData storage oracle = _getOracleEntry(feedId);
        if (oracle.base.updatedAt == 0) revert E.InvalidParameter();

        // Calculate TWAPs from accumulator
        uint64 fastTWAP = _calculateTWAPFromAccumulator(oracle, oracle.fastSnapshotTime, oracle.fastAccumSnapshot);
        uint64 slowTWAP = _calculateTWAPFromAccumulator(oracle, oracle.slowSnapshotTime, oracle.slowAccumSnapshot);

        return FeedData({
            fastEMA: fastTWAP,
            slowEMA: slowTWAP,
            fastVolEMA: oracle.base.fastVolEMA,
            slowVolEMA: oracle.base.slowVolEMA,
            updatedAt: oracle.base.updatedAt,
            maxDeviation: oracle.maxTWAPChange,
            ttl: 3600 // 1 hour default TTL
        });
    }

    /// @notice Check if oracle data is fresh
    /// @dev Implements IOracle.isFresh
    /// @param feedId Oracle identifier to check
    /// @param maxAge Maximum acceptable age in seconds
    /// @return isFresh True if data is fresh
    function isFresh(bytes32 feedId, uint32 maxAge) external view virtual override returns (bool) {
        IInternalOracle.InternalFeedData storage oracle = _getOracleEntry(feedId);
        if (oracle.base.updatedAt == 0) return false;
        return block.timestamp - oracle.base.updatedAt <= maxAge;
    }

    /// @notice Get just the fast TWAP (most gas efficient)
    /// @dev Implements IOracle.getFastPrice
    /// @param feedId Oracle identifier to query
    /// @return fastTWAP Current fast TWAP in b64 format
    function getFastPrice(bytes32 feedId) external view virtual override returns (uint64 fastTWAP) {
        IInternalOracle.InternalFeedData storage oracle = _getOracleEntry(feedId);
        if (oracle.base.updatedAt == 0) revert E.InvalidParameter();
        return _calculateTWAPFromAccumulator(oracle, oracle.fastSnapshotTime, oracle.fastAccumSnapshot);
    }

    // ========== INTERNAL HELPERS ==========

    /// @notice Calculate TWAP from accumulator snapshot (generic helper)
    /// @dev Implements Uniswap V3 style accumulator TWAP: (currentAccum - snapshotAccum) / timeDelta
    ///      Consolidates logic shared between fast and slow TWAP calculations
    /// @param oracle Oracle storage reference
    /// @param snapshotTime Timestamp of the snapshot
    /// @param accumSnapshot Accumulator value at snapshot time
    /// @return TWAP value in b64 format
    function _calculateTWAPFromAccumulator(
        IInternalOracle.InternalFeedData storage oracle,
        uint32 snapshotTime,
        uint256 accumSnapshot
    ) private view returns (uint64) {
        // Calculate current accumulator value
        uint256 timeElapsed = block.timestamp - oracle.base.updatedAt;
        uint256 currentAccum = oracle.priceAccumulator + (uint256(oracle.currentPrice) * timeElapsed);

        // Calculate TWAP from snapshot
        uint256 timeDelta = block.timestamp - snapshotTime;
        if (timeDelta == 0) return oracle.currentPrice;

        uint256 accumDelta = currentAccum - accumSnapshot;
        return uint64(accumDelta / timeDelta);
    }

}
