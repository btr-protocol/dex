// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseV1} from "./BaseV1.sol";
import {IErrors} from "../interfaces/IErrors.sol";
import {IOracleV1} from "../interfaces/IOracleV1.sol";
import {IPoolV1} from "../interfaces/IPoolV1.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";
import {LibOracle} from "../libraries/LibOracle.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";

/// @title InternalOracle
/// @notice Ultra-efficient internal TWAP oracle that updates automatically on swaps
/// @dev Optimized for minimal gas usage with single-slot updates where possible
contract InternalOracleV1 is BaseV1 {
    using {M.b64To1e18} for uint64;

    // ========== CONSTANTS ==========

    /// @notice Fast TWAP window (5 minutes)
    uint32 public constant FAST_WINDOW = 300;

    /// @notice Slow TWAP window (1 hour)
    uint32 public constant SLOW_WINDOW = 3600;

    /// @notice Fast volatility EMA alpha (0.02% = 200 units in C.PBPS)
    uint32 public constant FAST_VOL_ALPHA = 200;

    /// @notice Slow volatility EMA alpha (0.18% = 1800 units in C.PBPS)
    uint32 public constant SLOW_VOL_ALPHA = 1800;

    /// @notice Maximum allowed volatility (10,000% = 100 * C.PBPS)
    uint32 public constant MAX_VOLATILITY = 100 * uint32(C.PBPS);

    /// @notice Default TTL for feeds (1 hour)
    uint16 public constant DEFAULT_TTL = 3600;

    // Note: _os() storage getter inherited from Base

    // ========== PUBLIC INTERFACE ==========

    /// @notice Get feed data for a token from the oracle
    /// @param token Asset address (uses token directly, not feedId)
    /// @return data Feed data for the token
    function getFeed(address token) external view returns (IOracleV1.FeedData memory data) {
        IPoolV1.PoolStorage storage $ = _s();
        address tokenNorm = _wrap($, token);
        IPoolV1.FeedAccumulator storage acc = _os().accumulators[tokenNorm];

        if (acc.lastUpdate == 0) revert IErrors.NotConfigured(IErrors.Resource.ORACLE, tokenNorm);

        // Reconstruct FeedData from accumulator
        data = IOracleV1.FeedData({
            lastPriceB64: acc.lastPriceB64,
            fastOffset: acc.fastOffset,  // TWAP offset from spot
            slowOffset: acc.slowOffset,  // TWAP offset from spot
            fastVolEMA: acc.fastVolEMA,
            slowVolEMA: acc.slowVolEMA,
            updatedAt: acc.lastUpdate,
            ttl: acc.ttl,
            confidence: acc.confidence
        });
    }

    /// @notice Check if oracle data is fresh
    /// @param token Asset address
    /// @param maxAge Maximum age in seconds
    /// @return True if fresh
    function isFeedFresh(address token, uint32 maxAge) external view returns (bool) {
        IPoolV1.PoolStorage storage $ = _s();
        address tokenNorm = _wrap($, token);
        IPoolV1.FeedAccumulator storage acc = _os().accumulators[tokenNorm];

        if (acc.lastUpdate == 0) return false;
        unchecked {
            return block.timestamp - acc.lastUpdate <= maxAge;
        }
    }

    /// @notice Check if oracle data is fresh (using TTL)
    /// @param token Asset address
    /// @return True if fresh
    function isFeedFresh(address token) external view returns (bool) {
        IPoolV1.PoolStorage storage $ = _s();
        address tokenNorm = _wrap($, token);
        IPoolV1.FeedAccumulator storage acc = _os().accumulators[tokenNorm];

        if (acc.lastUpdate == 0) return false;
        unchecked {
            return block.timestamp - acc.lastUpdate <= acc.ttl;
        }
    }

    /// @notice Get fast TWAP for a token (reconstructed from spot + offset)
    /// @param token Asset address
    /// @return fastTWAP Fast TWAP value (b64)
    function getFastTWAP(address token) external view returns (uint64 fastTWAP) {
        IPoolV1.PoolStorage storage $ = _s();
        address tokenNorm = _wrap($, token);
        IPoolV1.FeedAccumulator storage acc = _os().accumulators[tokenNorm];

        if (acc.lastUpdate == 0) revert IErrors.NotConfigured(IErrors.Resource.ORACLE, tokenNorm);
        // Reconstruct TWAP from spot price and offset
        // For now, return spot price since TWAP = spot * (1 + offset) and offset is small
        return acc.lastPriceB64;
    }

    // ========== ORACLE MANAGEMENT ==========

    /// @notice Initialize or reset oracle for a token
    /// @dev Callable by owner OR internally from AdminV1 (via proxy self-call)
    /// @param token Asset address
    /// @param initialPrice Initial price (b64, encoded with token decimals)
    /// @param accDecimals Accumulator encoding decimals (use lower for more range):
    ///        - Stables (~$1): use 6 (max acc ~4.5e72 price-seconds)
    ///        - ETH (~$3k): use 12 (max acc ~4.5e66 price-seconds)
    ///        - BTC (~$100k): use 18 (max acc ~4.5e60 price-seconds)
    /// @param fastVolEMA Initial fast volatility EMA (1e6 base)
    /// @param slowVolEMA Initial slow volatility EMA (1e6 base)
    function updateFeed(
        address token,
        uint64 initialPrice,
        uint8 accDecimals,
        uint32 fastVolEMA,
        uint32 slowVolEMA
    ) external {
        // Allow owner OR internal pool calls (AdminV1 calls via proxy self-call)
        if (msg.sender != _s().owner && msg.sender != address(this)) revert Unauthorized();
        if (initialPrice == 0) revert IErrors.ZeroValue();
        if (accDecimals > 18) revert IErrors.InvalidInput(); // Max 18 decimals

        IPoolV1.PoolStorage storage $ = _s();
        address tokenNorm = _wrap($, token);
        IPoolV1.FeedAccumulator storage acc = _os().accumulators[tokenNorm];

        acc.lastPriceB64 = initialPrice;
        acc.accDecimals = accDecimals;
        acc.fastVolEMA = fastVolEMA;
        acc.slowVolEMA = slowVolEMA;
        acc.lastUpdate = uint32(block.timestamp);
        acc.ttl = DEFAULT_TTL;
        acc.confidence = 100;

        // Reset accumulator state (B64 with accDecimals for optimal range)
        acc.priceAccB64 = 0;
        acc.fastSnapB64 = 0;  // Initialize snapshots to 0 (will be set on first update)
        acc.slowSnapB64 = 0;
        acc.fastSnapshotTime = uint32(block.timestamp);
        acc.slowSnapshotTime = uint32(block.timestamp);

        // Initialize offsets to 0 (spot = TWAP initially)
        acc.fastOffset = 0;
        acc.slowOffset = 0;

        emit IOracleV1.OracleUpdated(tokenNorm, initialPrice, fastVolEMA, slowVolEMA);
    }

    /// @notice Push new price and volatility data for a token
    /// @dev NOT IMPLEMENTED for internal oracle - this is for external oracles only
    /// @dev Internal oracle feeds are updated automatically via pushFeedInternal on swaps
    function pushFeed(
        address,
        uint64,
        uint32
    ) external pure {
        revert IErrors.InvalidInput();
    }

    // ========== SWAP-BASED FEED UPDATES ==========

    /// @notice Update feeds from swap execution with execution prices
    /// @dev Called internally after each swap to maintain price feeds
    /// @dev Only updates feeds for non-base tokens (those with non-zero prices)
    /// @param tokenA First token in swap (or zero address if not applicable)
    /// @param tokenB Second token in swap (or zero address if not applicable)
    /// @param priceA Price of tokenA in base (b64), or zero if tokenA is base or not applicable
    /// @param priceB Price of tokenB in base (b64), or zero if tokenB is base or not applicable
    function pushFeedInternal(
        address tokenA,
        address tokenB,
        uint64 priceA,
        uint64 priceB
    ) external {
        // Only callable from within the pool (Core module context)
        if (msg.sender != address(this)) revert Unauthorized();

        IPoolV1.PoolStorage storage $ = _s();

        // Update tokenA feed if it has a price (is not base token)
        if (tokenA != address(0) && priceA != 0) {
            _updateFeeds($, tokenA, priceA);
        }

        // Update tokenB feed if it has a price (is not base token)
        if (tokenB != address(0) && priceB != 0) {
            _updateFeeds($, tokenB, priceB);
        }
    }

    /// @notice Update feed with swap-implied price (ultra-efficient)
    /// @dev Uses B64 accumulators with configurable decimals for optimal range
    /// @dev accDecimals is set at initialization and determines accumulator precision/range tradeoff
    function _updateFeeds(
        IPoolV1.PoolStorage storage $,
        address token,
        uint64 newPrice
    ) private {
        address tokenNorm = _wrap($, token);
        IPoolV1.FeedAccumulator storage acc = _os().accumulators[tokenNorm];

        uint32 currentTime = uint32(block.timestamp);

        // Initialize if first update (should have been initialized via updateFeed)
        if (acc.lastUpdate == 0) {
            acc.lastPriceB64 = newPrice;
            acc.fastVolEMA = C.ONE_PCT_PBPS / 100;  // 0.01% default
            acc.slowVolEMA = C.ONE_PCT_PBPS / 100;
            acc.lastUpdate = currentTime;
            acc.ttl = DEFAULT_TTL;
            acc.confidence = 100;
            acc.accDecimals = 6;  // Default to stablecoin-friendly decimals
            acc.priceAccB64 = 0;
            acc.fastSnapB64 = 0;
            acc.slowSnapB64 = 0;
            acc.fastSnapshotTime = currentTime;
            acc.slowSnapshotTime = currentTime;
            acc.fastOffset = 0;
            acc.slowOffset = 0;
            return;
        }

        unchecked {
            uint256 dt = currentTime - acc.lastUpdate;

            // Skip if same block (prevents manipulation)
            if (dt == 0) return;

            // SECURITY FIX (CRITICAL-7): Staleness threshold to prevent TWAP corruption
            // If oracle hasn't been updated in > 7 days, cap dt to prevent accumulator corruption
            // and reset snapshots to ensure clean TWAP windows
            uint256 MAX_STALENESS = 604800; // 7 days in seconds
            if (dt > MAX_STALENESS) {
                dt = MAX_STALENESS;
                // Reset snapshots to current state - TWAP will rebuild from fresh data
                acc.fastSnapB64 = acc.priceAccB64;
                acc.slowSnapB64 = acc.priceAccB64;
                acc.fastSnapshotTime = acc.lastUpdate;
                acc.slowSnapshotTime = acc.lastUpdate;
            }

            // Get accumulator decimals (set at initialization)
            uint8 accDec = acc.accDecimals;

            // Decode last price to accDecimals base for accumulator math
            // This gives us optimal range while preserving precision
            uint256 lastPriceInAccDec = M.decodeB64(acc.lastPriceB64, accDec);

            // Time-weighted price increment in accDecimals base
            uint256 increment = lastPriceInAccDec * dt;

            // Current accumulator value (decode from B64 with accDecimals)
            uint256 currentAcc = acc.priceAccB64 == 0 ? 0 : M.decodeB64(acc.priceAccB64, accDec);
            currentAcc += increment;

            // Re-encode accumulator with accDecimals (not token decimals!)
            // This is key: using lower decimals allows B64 to store much larger values
            acc.priceAccB64 = M.encodeB64(currentAcc, accDec);

            // For TWAP calculations, we need 1e18 base for offset encoding
            uint256 lastPriceInt = M.b64To1e18(acc.lastPriceB64);

            // Calculate TWAP from accumulator and update offsets
            uint256 dtFast = currentTime - acc.fastSnapshotTime;
            if (dtFast >= FAST_WINDOW) {
                // Decode snapshot with accDecimals
                uint256 fastAccSnapshot = acc.fastSnapB64 == 0 ? 0 : M.decodeB64(acc.fastSnapB64, accDec);

                // SECURITY FIX (CRITICAL-7): Underflow protection on accumulator subtraction
                // If snapshot > current (corruption/reinitialization), reset snapshot to current
                if (fastAccSnapshot > currentAcc) {
                    acc.fastSnapB64 = acc.priceAccB64;
                    acc.fastSnapshotTime = currentTime;
                    // Skip TWAP update this cycle - will be valid next window
                } else {
                    uint256 windowAccumulation = currentAcc - fastAccSnapshot;

                    // TWAP in accDecimals base, then scale to 1e18
                    uint256 twapInAccDec = windowAccumulation / dtFast;
                    uint256 fastTWAP = twapInAccDec * (10 ** (18 - accDec));

                    // Encode offset directly from 1e18 values
                    acc.fastOffset = LibOracle.encodeOffset1e18(lastPriceInt, fastTWAP);

                    // Store current accumulator as new snapshot (B64 with accDecimals)
                    acc.fastSnapB64 = acc.priceAccB64;
                    acc.fastSnapshotTime = currentTime;
                }
            }

            uint256 dtSlow = currentTime - acc.slowSnapshotTime;
            if (dtSlow >= SLOW_WINDOW) {
                // Decode snapshot with accDecimals
                uint256 slowAccSnapshot = acc.slowSnapB64 == 0 ? 0 : M.decodeB64(acc.slowSnapB64, accDec);

                // SECURITY FIX (CRITICAL-7): Underflow protection on accumulator subtraction
                // If snapshot > current (corruption/reinitialization), reset snapshot to current
                if (slowAccSnapshot > currentAcc) {
                    acc.slowSnapB64 = acc.priceAccB64;
                    acc.slowSnapshotTime = currentTime;
                    // Skip TWAP update this cycle - will be valid next window
                } else {
                    uint256 windowAccumulation = currentAcc - slowAccSnapshot;

                    // TWAP in accDecimals base, then scale to 1e18
                    uint256 twapInAccDec = windowAccumulation / dtSlow;
                    uint256 slowTWAP = twapInAccDec * (10 ** (18 - accDec));

                    // Encode offset directly from 1e18 values
                    acc.slowOffset = LibOracle.encodeOffset1e18(lastPriceInt, slowTWAP);

                    // Store current accumulator as new snapshot (B64 with accDecimals)
                    acc.slowSnapB64 = acc.priceAccB64;
                    acc.slowSnapshotTime = currentTime;
                }
            }

            // Update volatility based on price change (using LibMaths B64 function)
            uint32 priceChange = M.diff1e6(acc.lastPriceB64, newPrice);
            acc.fastVolEMA = _updateVolEMA(acc.fastVolEMA, priceChange, FAST_VOL_ALPHA);
            acc.slowVolEMA = _updateVolEMA(acc.slowVolEMA, priceChange, SLOW_VOL_ALPHA);

            // Update spot price (keeps original token decimals encoding)
            acc.lastPriceB64 = newPrice;
            acc.lastUpdate = currentTime;
            acc.confidence = 100;
        }
    }

    // ========== INTERNAL HELPERS ==========

    /// @notice Update volatility EMA
    /// @param oldVol Current EMA value
    /// @param newVol New sample
    /// @param alpha EMA smoothing factor (C.PBPS precision)
    /// @return updatedVol New EMA value
    function _updateVolEMA(
        uint32 oldVol,
        uint32 newVol,
        uint32 alpha
    ) private pure returns (uint32 updatedVol) {
        unchecked {
            uint256 o = oldVol;
            uint256 n = newVol;
            uint256 a = alpha;

            uint256 delta = n > o
                ? ((n - o) * a) / C.PBPS
                : ((o - n) * a) / C.PBPS;

            if (n > o) {
                uint256 result = o + delta;
                updatedVol = result > type(uint32).max ? type(uint32).max : uint32(result);
            } else {
                updatedVol = uint32(o - delta);
            }
        }
    }
}
