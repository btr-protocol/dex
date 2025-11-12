// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IInternalOracle} from "../interfaces/IInternalOracle.sol";
import {BaseOracle} from "../oracles/BaseOracle.sol";
import {BAMMErrors as E} from "./BAMMEvents.sol";
import {BAMMEvents as Events} from "./BAMMEvents.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";
import {LibUtils} from "../libraries/LibUtils.sol";
import {LibStorage} from "../libraries/LibStorage.sol";

/// @title InternalOracle
/// @notice BAMM's internal accumulator-based oracle (Uniswap V3-style TWAP)
/// @dev Implements IInternalOracle - ONLY manages internal accumulator
/// @dev Does NOT handle external oracle reading - that's BAMM's responsibility
/// @dev Extends BaseOracle for common validation functionality
abstract contract InternalOracle is BaseOracle, IInternalOracle {

    // ========== STORAGE ACCESS (must be implemented by child) ==========

    /// @dev Oracle data by oracleId = keccak256(abi.encodePacked(baseAsset, quoteAsset))
    /// @dev Must be implemented by child contract (returns reference to LibStorage.OracleEntry)
    function _getOracleEntry(bytes32 oracleId) internal view virtual returns (LibStorage.OracleEntry storage);

    /// @notice Get asset storage for given token
    function _getAsset(address token) internal view virtual returns (IBAMM.Asset storage);

    /// @notice Get all registered assets
    function _getRegisteredAssets() internal view virtual returns (address[] memory);

    /// @notice Get fast TWAP weight
    function _getFastTWAPWeight() internal view virtual returns (uint8);

    /// @notice Get slow TWAP weight
    function _getSlowTWAPWeight() internal view virtual returns (uint8);

    // ========== ORACLE UPDATES ==========

    /// @notice Update internal oracle with new price and volatility data
    /// @dev Implements IInternalOracle.updateOracle
    /// @param oracleId Oracle identifier (keccak256 of base/quote pair)
    /// @param newPrice New spot price (b64 format)
    /// @param newVolatility New volatility measurement (1e6 base: 1_000_000 = 1%)
    function updateOracle(bytes32 oracleId, uint64 newPrice, uint32 newVolatility) external virtual override {
        LibStorage.OracleEntry storage oracle = _getOracleEntry(oracleId);
        if (!oracle.exists) revert E.InvalidParameter();

        // Validate inputs
        if (!_validatePrice(newPrice)) revert E.InvalidPrice();
        if (!_validateVolatility(newVolatility)) revert E.InvalidParameter();

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
            oracle.fastVolatility = newVolatility;
            oracle.slowVolatility = newVolatility;
            oracle.lastOracleUpdate = currentTime32;

            // Emit event with initial values
            emit Events.OracleUpdate(oracleId, newPrice, newPrice,
                                    newVolatility, newVolatility, msg.sender);
        } else {
            // Check price change is within bounds (compare in 1e18 format for precision)
            uint256 oldPrice1e18 = M.decodePriceTo1e18(oracle.currentPrice);
            uint256 newPrice1e18 = M.decodePriceTo1e18(newPrice);
            uint256 priceDelta = newPrice1e18 > oldPrice1e18 ? newPrice1e18 - oldPrice1e18 : oldPrice1e18 - newPrice1e18;
            uint256 maxChange = (oldPrice1e18 * oracle.maxTWAPChange) / M.BPS_PRECISION;
            if (priceDelta > maxChange) revert E.PriceChangeTooLarge();

            // Update accumulator: Σ(price × timeElapsed) - Uniswap V3 pattern
            uint256 timeElapsed = currentTime - oracle.lastOracleUpdate;
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
            oracle.fastVolatility = M.updateVolatilityEMA(oracle.fastVolatility, newVolatility, _getFastTWAPWeight());
            oracle.slowVolatility = M.updateVolatilityEMA(oracle.slowVolatility, newVolatility, _getSlowTWAPWeight());

            oracle.lastOracleUpdate = currentTime32;

            // Emit event with precomputed TWAPs (no external calls or recomputation)
            emit Events.OracleUpdate(oracleId, fastTWAP, slowTWAP,
                                    oracle.fastVolatility, oracle.slowVolatility, msg.sender);
        }
    }

    /// @notice Reset oracle accumulator (e.g., after base/quote currency change)
    /// @dev Implements IInternalOracle.resetOracle
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
    ) external virtual override {
        LibStorage.OracleEntry storage oracle = _getOracleEntry(oracleId);

        // Validate inputs
        if (!_validatePrice(initialPrice)) revert E.InvalidPrice();
        if (!_validateVolatility(initialFastVol)) revert E.InvalidParameter();
        if (!_validateVolatility(initialSlowVol)) revert E.InvalidParameter();

        // Reset accumulator state to zero
        oracle.currentPrice = initialPrice;
        oracle.priceAccumulator = 0;
        oracle.fastAccumSnapshot = 0;
        oracle.fastSnapshotTime = uint32(block.timestamp);
        oracle.slowAccumSnapshot = 0;
        oracle.slowSnapshotTime = uint32(block.timestamp);
        oracle.fastVolatility = initialFastVol;
        oracle.slowVolatility = initialSlowVol;
        oracle.lastOracleUpdate = uint32(block.timestamp);
        oracle.exists = true;

        emit OracleReset(oracleId, initialPrice, initialFastVol, initialSlowVol);
    }

    // ========== IORACLE IMPLEMENTATION ==========

    /// @notice Get oracle data for a specific oracle ID
    /// @dev Implements IOracle.getOracleData - reads from internal accumulator
    /// @param oracleId Oracle identifier to query
    /// @return data Oracle data with fast/slow TWAPs, volatility, and timestamp
    function getOracleData(bytes32 oracleId) external view virtual override returns (OracleData memory data) {
        LibStorage.OracleEntry storage oracle = _getOracleEntry(oracleId);
        if (!oracle.exists) revert E.InvalidParameter();

        // Calculate TWAPs from accumulator
        uint64 fastTWAP = _calculateTWAPFromAccumulator(oracle, oracle.fastSnapshotTime, oracle.fastAccumSnapshot);
        uint64 slowTWAP = _calculateTWAPFromAccumulator(oracle, oracle.slowSnapshotTime, oracle.slowAccumSnapshot);

        return OracleData({
            fastTWAP: fastTWAP,
            slowTWAP: slowTWAP,
            fastVolatility: oracle.fastVolatility,
            slowVolatility: oracle.slowVolatility,
            lastUpdate: oracle.lastOracleUpdate
        });
    }

    /// @notice Check if oracle data is fresh
    /// @dev Implements IOracle.isFresh
    /// @param oracleId Oracle identifier to check
    /// @param maxAge Maximum acceptable age in seconds
    /// @return isFresh True if data is fresh
    function isFresh(bytes32 oracleId, uint32 maxAge) external view virtual override returns (bool) {
        LibStorage.OracleEntry storage oracle = _getOracleEntry(oracleId);
        if (!oracle.exists || oracle.lastOracleUpdate == 0) return false;
        return block.timestamp - oracle.lastOracleUpdate <= maxAge;
    }

    /// @notice Get just the fast TWAP (most gas efficient)
    /// @dev Implements IOracle.getFastPrice
    /// @param oracleId Oracle identifier to query
    /// @return fastTWAP Current fast TWAP in b64 format
    function getFastPrice(bytes32 oracleId) external view virtual override returns (uint64 fastTWAP) {
        LibStorage.OracleEntry storage oracle = _getOracleEntry(oracleId);
        if (!oracle.exists) revert E.InvalidParameter();
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
        LibStorage.OracleEntry storage oracle,
        uint32 snapshotTime,
        uint256 accumSnapshot
    ) private view returns (uint64) {
        // Calculate current accumulator value
        uint256 timeElapsed = block.timestamp - oracle.lastOracleUpdate;
        uint256 currentAccum = oracle.priceAccumulator + (uint256(oracle.currentPrice) * timeElapsed);

        // Calculate TWAP from snapshot
        uint256 timeDelta = block.timestamp - snapshotTime;
        if (timeDelta == 0) return oracle.currentPrice;

        uint256 accumDelta = currentAccum - accumSnapshot;
        return uint64(accumDelta / timeDelta);
    }

}
