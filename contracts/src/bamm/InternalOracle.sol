// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {BAMMErrors as E} from "./BAMMEvents.sol";
import {BAMMEvents as Events} from "./BAMMEvents.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";
import {LibUtils} from "../libraries/LibUtils.sol";

/// @title InternalOracle
/// @notice Oracle management for BAMM - handles both internal and external oracles
/// @dev Uses Uniswap V3 style TWAP accumulator for time-weighted averages
abstract contract InternalOracle {

    // ========== CONSTANTS ==========

    /// @notice Maximum age for external oracle data (24 hours)
    /// @dev Staleness threshold to reject outdated external oracle readings
    uint256 internal constant MAX_ORACLE_STALENESS = 24 hours;

    // ========== STORAGE ACCESS (must be implemented by child) ==========

    /// @notice Get asset storage for given token
    function _getAsset(address token) internal view virtual returns (IBAMM.Asset storage);

    /// @notice Get all registered assets
    function _getRegisteredAssets() internal view virtual returns (address[] memory);

    /// @notice Get fast TWAP weight
    function _getFastTWAPWeight() internal view virtual returns (uint8);

    /// @notice Get slow TWAP weight
    function _getSlowTWAPWeight() internal view virtual returns (uint8);

    // ========== ORACLE UPDATES ==========

    /// @notice Internal oracle update logic (called from BAMMManagement)
    function _updateOracleInternal(address token, uint64 newPrice, uint32 newVolatility) internal virtual {
        IBAMM.Asset storage asset = _getAsset(token);
        LibUtils.requireRegistered(asset);

        // Only allow updates for assets using internal oracle
        bool hasInternalOracle = asset.mainOracle == address(this) || asset.fallbackOracle == address(this);
        if (!hasInternalOracle) revert E.InvalidParameter();

        if (newPrice == 0) revert E.InvalidPrice();
        if (newVolatility > 100_000_000) revert E.InvalidParameter();

        // Cache timestamp to avoid repeated SLOAD operations (gas optimization)
        uint256 currentTime = block.timestamp;
        uint32 currentTime32 = uint32(currentTime);

        if (asset.currentPrice == 0) {
            // First oracle update - initialize accumulator system
            asset.currentPrice = newPrice;
            asset.priceAccumulator = 0;
            asset.fastAccumSnapshot = 0;
            asset.fastSnapshotTime = currentTime32;
            asset.slowAccumSnapshot = 0;
            asset.slowSnapshotTime = currentTime32;
            asset.fastVolatility = newVolatility;
            asset.slowVolatility = newVolatility;
            asset.lastOracleUpdate = currentTime32;

            // Emit event with initial values
            emit Events.OracleUpdate(token, newPrice, newPrice,
                                    newVolatility, newVolatility, msg.sender);
        } else {
            // Check price change is within bounds (compare in 1e18 format for precision)
            uint256 oldPrice1e18 = M.decodePriceTo1e18(asset.currentPrice);
            uint256 newPrice1e18 = M.decodePriceTo1e18(newPrice);
            uint256 priceDelta = newPrice1e18 > oldPrice1e18 ? newPrice1e18 - oldPrice1e18 : oldPrice1e18 - newPrice1e18;
            uint256 maxChange = (oldPrice1e18 * asset.maxTWAPChange) / M.BPS_PRECISION;
            if (priceDelta > maxChange) revert E.PriceChangeTooLarge();

            // Update accumulator: Σ(price × timeElapsed) - Uniswap V3 pattern
            uint256 timeElapsed = currentTime - asset.lastOracleUpdate;
            uint256 newAccumulator = asset.priceAccumulator + uint256(asset.currentPrice) * timeElapsed;
            asset.priceAccumulator = newAccumulator;

            // Update current price
            asset.currentPrice = newPrice;

            // Precompute TWAPs for event emission (avoid recomputing in event)
            uint64 fastTWAP;
            uint64 slowTWAP;

            // Update fast snapshot and compute fast TWAP
            uint256 fastAge = currentTime - asset.fastSnapshotTime;
            if (fastAge >= asset.fastWindow) {
                asset.fastAccumSnapshot = newAccumulator;
                asset.fastSnapshotTime = currentTime32;
            }
            // Compute fast TWAP from current accumulator state
            uint256 fastTimeDelta = currentTime - asset.fastSnapshotTime;
            if (fastTimeDelta == 0) {
                fastTWAP = asset.currentPrice;
            } else {
                uint256 fastAccumDelta = newAccumulator - asset.fastAccumSnapshot;
                fastTWAP = uint64(fastAccumDelta / fastTimeDelta);
            }

            // Update slow snapshot and compute slow TWAP
            uint256 slowAge = currentTime - asset.slowSnapshotTime;
            if (slowAge >= asset.slowWindow) {
                asset.slowAccumSnapshot = newAccumulator;
                asset.slowSnapshotTime = currentTime32;
            }
            // Compute slow TWAP from current accumulator state
            uint256 slowTimeDelta = currentTime - asset.slowSnapshotTime;
            if (slowTimeDelta == 0) {
                slowTWAP = asset.currentPrice;
            } else {
                uint256 slowAccumDelta = newAccumulator - asset.slowAccumSnapshot;
                slowTWAP = uint64(slowAccumDelta / slowTimeDelta);
            }

            // Update volatility using EMA (appropriate for variance smoothing)
            asset.fastVolatility = M.updateVolatilityEMA(asset.fastVolatility, newVolatility, _getFastTWAPWeight());
            asset.slowVolatility = M.updateVolatilityEMA(asset.slowVolatility, newVolatility, _getSlowTWAPWeight());

            asset.lastOracleUpdate = currentTime32;

            // Emit event with precomputed TWAPs (no external calls or recomputation)
            emit Events.OracleUpdate(token, fastTWAP, slowTWAP,
                                    asset.fastVolatility, asset.slowVolatility, msg.sender);
        }
    }

    /// @notice Internal oracle config update logic (called from BAMMManagement)
    /// @dev Validates oracle addresses have code and initializes state appropriately
    function _updateOracleConfigInternal(
        address token,
        address mainOracle,
        address fallbackOracle
    ) internal virtual {
        IBAMM.Asset storage asset = _getAsset(token);
        LibUtils.requireRegistered(asset);

        // Default to internal if not specified
        if (mainOracle == address(0)) mainOracle = address(this);

        // Validate oracle addresses have code (defensive guard)
        // Note: address(this) check is redundant but harmless; external addresses need validation
        if (mainOracle != address(this) && mainOracle.code.length == 0) {
            revert E.InvalidParameter();
        }
        if (fallbackOracle != address(0) && fallbackOracle != address(this) && fallbackOracle.code.length == 0) {
            revert E.InvalidParameter();
        }

        // Early return if configuration unchanged (gas optimization)
        if (asset.mainOracle == mainOracle && asset.fallbackOracle == fallbackOracle) {
            return;
        }

        // Cache timestamp (gas optimization)
        uint32 currentTime32 = uint32(block.timestamp);

        // Re-initialize oracle data with new configuration
        // For external oracle: reading MUST succeed, use as initial price
        // For internal oracle: keep existing accumulator state (use updateOracle for data updates)
        if (mainOracle != address(this)) {
            (uint64 externalFastTWAP,, uint32 newFastVol, uint32 newSlowVol) =
                _readOracleOrRevert(mainOracle, fallbackOracle);

            // Use external TWAP as initial price, reset accumulator
            asset.currentPrice = externalFastTWAP;
            asset.priceAccumulator = 0;
            asset.fastAccumSnapshot = 0;
            asset.fastSnapshotTime = currentTime32;
            asset.slowAccumSnapshot = 0;
            asset.slowSnapshotTime = currentTime32;
            asset.fastVolatility = newFastVol;
            asset.slowVolatility = newSlowVol;
        }
        // If switching to internal oracle, keep existing accumulator/volatility

        asset.mainOracle = mainOracle;
        asset.fallbackOracle = fallbackOracle;
        asset.lastOracleUpdate = currentTime32;

        emit Events.OracleUpdated(token, mainOracle, fallbackOracle);
    }

    // ========== ORACLE HELPERS ==========

    /// @notice Get fast TWAP for asset (accumulator or external oracle)
    /// @dev For internal oracle: calculates from accumulator (Uniswap V3 style)
    /// @dev For external oracle: reads directly from external oracle
    /// @param asset Asset storage reference
    /// @return Fast TWAP in b64 format (~6 hour window)
    function _getFastTWAP(IBAMM.Asset storage asset) internal view virtual returns (uint64) {
        // External oracle: read directly
        if (asset.mainOracle != address(this) && asset.fallbackOracle != address(this)) {
            (uint64 fastTWAP,,,) = _readOracleOrRevert(asset.mainOracle, asset.fallbackOracle);
            return fastTWAP;
        }

        // Internal oracle: calculate from accumulator using helper
        return _calculateTWAPFromAccumulator(asset, asset.fastSnapshotTime, asset.fastAccumSnapshot);
    }

    /// @notice Get slow TWAP for asset (accumulator or external oracle)
    /// @dev For internal oracle: calculates from accumulator (Uniswap V3 style)
    /// @dev For external oracle: reads directly from external oracle
    /// @param asset Asset storage reference
    /// @return Slow TWAP in b64 format (~1 week window)
    function _getSlowTWAP(IBAMM.Asset storage asset) internal view virtual returns (uint64) {
        // External oracle: read directly
        if (asset.mainOracle != address(this) && asset.fallbackOracle != address(this)) {
            (, uint64 slowTWAP,,) = _readOracleOrRevert(asset.mainOracle, asset.fallbackOracle);
            return slowTWAP;
        }

        // Internal oracle: calculate from accumulator using helper
        return _calculateTWAPFromAccumulator(asset, asset.slowSnapshotTime, asset.slowAccumSnapshot);
    }

    /// @notice Calculate TWAP from accumulator snapshot (generic helper)
    /// @dev Implements Uniswap V3 style accumulator TWAP: (currentAccum - snapshotAccum) / timeDelta
    ///      Consolidates logic shared between fast and slow TWAP calculations
    /// @param asset Asset storage reference
    /// @param snapshotTime Timestamp of the snapshot
    /// @param accumSnapshot Accumulator value at snapshot time
    /// @return TWAP value in b64 format
    function _calculateTWAPFromAccumulator(
        IBAMM.Asset storage asset,
        uint32 snapshotTime,
        uint256 accumSnapshot
    ) private view returns (uint64) {
        // Calculate current accumulator value
        uint256 timeElapsed = block.timestamp - asset.lastOracleUpdate;
        uint256 currentAccum = asset.priceAccumulator + (uint256(asset.currentPrice) * timeElapsed);

        // Calculate TWAP from snapshot
        uint256 timeDelta = block.timestamp - snapshotTime;
        if (timeDelta == 0) return asset.currentPrice;

        uint256 accumDelta = currentAccum - accumSnapshot;
        return uint64(accumDelta / timeDelta);
    }

    /// @notice Read oracle data from external oracle with mandatory fallback check
    /// @dev REVERTS if both main and fallback oracles fail - no dangerous defaults!
    ///      Validates staleness, data sanity, and oracle contract existence
    /// @param mainOracle Main oracle address
    /// @param fallbackOracle Fallback oracle address (address(0) = no fallback)
    /// @return fastTWAP Initial fast TWAP
    /// @return slowTWAP Initial slow TWAP
    /// @return fastVol Initial fast volatility
    /// @return slowVol Initial slow volatility
    function _readOracleOrRevert(
        address mainOracle,
        address fallbackOracle
    ) internal view virtual returns (uint64 fastTWAP, uint64 slowTWAP, uint32 fastVol, uint32 slowVol) {
        // Validate main oracle has code (defensive guard against misconfiguration)
        if (mainOracle.code.length == 0) revert E.InvalidParameter();

        // Try main oracle
        try IOracle(mainOracle).getOracleData() returns (
            uint64 _fastTWAP,
            uint64 _slowTWAP,
            uint32 _fastVol,
            uint32 _slowVol,
            uint32 _lastUpdate
        ) {
            // Validate oracle data is not zero
            if (_fastTWAP == 0 || _slowTWAP == 0) revert E.InvalidPrice();

            // Validate volatility is within reasonable bounds
            if (_fastVol > 100_000_000 || _slowVol > 100_000_000) revert E.InvalidParameter();

            // Validate freshness: reject stale data (Chainlink-style staleness check)
            if (block.timestamp > _lastUpdate + MAX_ORACLE_STALENESS) revert E.OracleStale();

            return (_fastTWAP, _slowTWAP, _fastVol, _slowVol);
        } catch {
            // Main oracle failed - try fallback if configured
            if (fallbackOracle == address(0)) revert E.OracleStale();

            // Validate fallback oracle has code
            if (fallbackOracle.code.length == 0) revert E.InvalidParameter();

            // Try fallback oracle
            try IOracle(fallbackOracle).getOracleData() returns (
                uint64 _fastTWAP,
                uint64 _slowTWAP,
                uint32 _fastVol,
                uint32 _slowVol,
                uint32 _lastUpdate
            ) {
                // Validate fallback oracle data is not zero
                if (_fastTWAP == 0 || _slowTWAP == 0) revert E.InvalidPrice();

                // Validate volatility is within reasonable bounds
                if (_fastVol > 100_000_000 || _slowVol > 100_000_000) revert E.InvalidParameter();

                // Validate freshness: reject stale data
                if (block.timestamp > _lastUpdate + MAX_ORACLE_STALENESS) revert E.OracleStale();

                return (_fastTWAP, _slowTWAP, _fastVol, _slowVol);
            } catch {
                // Both oracles failed - REVERT (no dangerous defaults!)
                revert E.OracleStale();
            }
        }
    }
}
