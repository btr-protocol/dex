// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {Maths as M} from "./Maths.sol";
import {Oracle} from "./Oracle.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Constants as C} from "./Constants.sol";
import {TransientCache as TCache} from "./TransientCache.sol";
import {Err} from "@btr-shared/Errors.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title PoolOracle -internal TWAP/vol-EMA accumulator update logic for Pool.
/// @notice Phase 42H.D · G1 -extracted from `Pool.sol` to isolate oracle-update math
///         for audit clarity. ! external calls; pure storage transforms over
///         `IPool.PoolStorage` references. Same delegatecall-free model as `Pricing`.
/// @dev All functions take `IPool.PoolStorage storage $` as 1st arg ⇒ same SSTORE
///      cost as inlined private helpers (Solidity inlines simple lib internals).
library PoolOracle {
    /// @notice Emitted when an accumulator update is skipped due to the per-block
    ///         rate-limit (Phase 42J.4 · F4). Observers can detect TWAP-poisoning
    ///         attempts where multiple swaps in one block try to move the TWAP.
    event TwapUpdateRateLimited(address indexed token, uint256 indexed blockNumber);

    /// @notice Fast TWAP window (sec).
    uint32 internal constant FAST_WINDOW = 300;
    /// @notice Slow TWAP window (sec).
    uint32 internal constant SLOW_WINDOW = 3600;
    /// @notice Fast vol-EMA α (PBPS-denominated).
    uint32 internal constant FAST_VOL_ALPHA = 200;
    /// @notice Slow vol-EMA α (PBPS-denominated).
    uint32 internal constant SLOW_VOL_ALPHA = 1800;
    /// @notice Default feed TTL (sec).
    uint16 internal constant DEFAULT_TTL = 3600;
    /// @notice Max staleness before accumulator reset (sec).
    uint256 internal constant MAX_STALENESS = 604800;

    /// @notice Push internal feed update for up to 2 tokens (skip on zero addr/price).
    /// @dev Hot path. Skips msg.sender guard ∵ internal-only caller.
    function pushFeedInternal(
        IPool.PoolStorage storage $,
        address tokenA,
        address tokenB,
        uint64 priceA,
        uint64 priceB
    ) internal {
        if (tokenA != address(0) && priceA != 0) updateFeeds($, tokenA, priceA);
        if (tokenB != address(0) && priceB != 0) updateFeeds($, tokenB, priceB);
    }

    /// @notice Update single-token feed (TWAP accumulator + vol-EMA + windowed offsets).
    /// @dev Phase 42J.4 · F4 -per-token per-block rate-limit. Only the first push
    ///      per block per token mutates the accumulator; subsequent in-block pushes
    ///      early-return + emit `TwapUpdateRateLimited`. Defends against TWAP
    ///      poisoning by aggregator-bundled swaps (1inch/0x/KyberSwap atomic batch).
    function updateFeeds(IPool.PoolStorage storage $, address token, uint64 newPrice) internal {
        address t = token == SC.NATIVE ? $.wnative : token;
        if ($.lastUpdateBlock[t] == block.number) {
            emit TwapUpdateRateLimited(t, block.number);
            return;
        }
        IPool.FeedAccumulator storage acc = $.accumulators[t];
        uint32 currentTime = uint32(block.timestamp);

        if (acc.lastUpdate == 0) {
            acc.lastPriceB64 = newPrice;
            acc.fastVolEMA = uint32(SC.ONE_PCT_PBPS / 100);
            acc.slowVolEMA = uint32(SC.ONE_PCT_PBPS / 100);
            acc.lastUpdate = currentTime;
            acc.ttl = DEFAULT_TTL;
            acc.confidence = 100;
            acc.accDecimals = 6;
            acc.fastSnapshotTime = currentTime;
            acc.slowSnapshotTime = currentTime;
            $.lastUpdateBlock[t] = block.number;
            return;
        }

        unchecked {
            uint256 dt = currentTime - acc.lastUpdate;
            if (dt == 0) return;

            if (dt > MAX_STALENESS) {
                dt = MAX_STALENESS;
                acc.fastSnapB64 = acc.priceAccB64;
                acc.slowSnapB64 = acc.priceAccB64;
                acc.fastSnapshotTime = acc.lastUpdate;
                acc.slowSnapshotTime = acc.lastUpdate;
            }

            uint8 accDec = acc.accDecimals;
            uint256 lastPriceInAccDec = M.decodeB64(acc.lastPriceB64, accDec);
            uint256 currentAcc = acc.priceAccB64 == 0 ? 0 : M.decodeB64(acc.priceAccB64, accDec);
            currentAcc += lastPriceInAccDec * dt;
            acc.priceAccB64 = M.encodeB64(currentAcc, accDec);

            uint256 lastPriceInt = M.b64To1e18(acc.lastPriceB64);
            rollWindow(acc, accDec, currentAcc, lastPriceInt, currentTime, true);
            rollWindow(acc, accDec, currentAcc, lastPriceInt, currentTime, false);

            uint32 priceChange = M.diff1e6(acc.lastPriceB64, newPrice);
            acc.fastVolEMA = updateVolEMA(acc.fastVolEMA, priceChange, FAST_VOL_ALPHA);
            acc.slowVolEMA = updateVolEMA(acc.slowVolEMA, priceChange, SLOW_VOL_ALPHA);

            acc.lastPriceB64 = newPrice;
            acc.lastUpdate = currentTime;
            acc.confidence = 100;
        }
        $.lastUpdateBlock[t] = block.number;
    }

    /// @notice Roll fast or slow TWAP snapshot window if elapsed ≥ window size.
    function rollWindow(
        IPool.FeedAccumulator storage acc,
        uint8 accDec,
        uint256 currentAcc,
        uint256 lastPriceInt,
        uint32 currentTime,
        bool isFast
    ) internal {
        uint32 windowSize = isFast ? FAST_WINDOW : SLOW_WINDOW;
        uint32 snapTime = isFast ? acc.fastSnapshotTime : acc.slowSnapshotTime;
        uint64 snapB64 = isFast ? acc.fastSnapB64 : acc.slowSnapB64;

        unchecked {
            uint256 dt = currentTime - snapTime;
            if (dt < windowSize) return;

            uint256 snapAcc = snapB64 == 0 ? 0 : M.decodeB64(snapB64, accDec);
            if (snapAcc > currentAcc) {
                if (isFast) { acc.fastSnapB64 = acc.priceAccB64; acc.fastSnapshotTime = currentTime; }
                else { acc.slowSnapB64 = acc.priceAccB64; acc.slowSnapshotTime = currentTime; }
                return;
            }

            uint256 twapInAccDec = (currentAcc - snapAcc) / dt;
            uint256 twap = twapInAccDec * (10 ** (18 - accDec));
            int32 offset = Oracle.encodeOffset1e18(lastPriceInt, twap);
            if (isFast) {
                acc.fastOffset = offset;
                acc.fastSnapB64 = acc.priceAccB64;
                acc.fastSnapshotTime = currentTime;
            } else {
                acc.slowOffset = offset;
                acc.slowSnapB64 = acc.priceAccB64;
                acc.slowSnapshotTime = currentTime;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // Phase 42H.D Round 2 (G1) -read-side helpers extracted from Pool.sol
    // ─────────────────────────────────────────────────────────────────

    /// @notice Internal oracle accumulator read (no offset; for fallback path).
    function readInternalOracle(
        IPool.PoolStorage storage $,
        address token,
        bool requireConfigured
    ) internal view returns (IOracle.FeedData memory data, bool isFresh) {
        IPool.FeedAccumulator storage acc = $.accumulators[token];
        if (acc.lastUpdate == 0) {
            if (requireConfigured) revert Err.NotConfigured(Err.Resource.ORACLE, token);
            return (data, false);
        }
        data = IOracle.FeedData({
            lastPriceB64: acc.lastPriceB64,
            fastOffset: 0,
            slowOffset: 0,
            fastVolEMA: acc.fastVolEMA,
            slowVolEMA: acc.slowVolEMA,
            updatedAt: acc.lastUpdate,
            ttl: acc.ttl,
            confidence: acc.confidence
        });
        if (block.timestamp < acc.lastUpdate) {
            isFresh = false;
        } else {
            unchecked { isFresh = block.timestamp - acc.lastUpdate <= acc.ttl; }
        }
    }

    /// @notice Primary→fallback oracle read with TCache + try/catch DoS-resistance.
    /// @dev Resolves `address(this)` (Pool) to the internal accumulator path.
    function readOracle(
        IPool.PoolStorage storage $,
        address self,
        address token
    ) internal returns (IOracle.FeedData memory data) {
        bool found;
        (found, data) = TCache.tryLoadOracleFeed(token);
        if (found) return data;

        IPool.OracleConfig memory cfg = $.oracleConfigs[token];
        if (cfg.primary == address(0)) revert Err.NotConfigured(Err.Resource.ORACLE, token);

        uint256 lastAge;
        uint256 lastMaxAge;
        bool isFresh;
        bool primaryFailed;

        if (cfg.primary == self) {
            (data, isFresh) = readInternalOracle($, token, true);
            if (isFresh) { TCache.cacheOracleFeed(token, data); return data; }
            unchecked { lastAge = block.timestamp - data.updatedAt; lastMaxAge = data.ttl; }
        } else {
            try IOracle(cfg.primary).getFeed(cfg.feedId) returns (IOracle.FeedData memory feedData) {
                data = feedData;
                try IOracle(cfg.primary).isFeedFresh(cfg.feedId) returns (bool fresh) {
                    if (fresh) { TCache.cacheOracleFeed(token, data); return data; }
                    unchecked { lastAge = block.timestamp - data.updatedAt; lastMaxAge = data.ttl; }
                } catch { primaryFailed = true; }
            } catch { primaryFailed = true; }
        }

        if ((cfg.modeFlags & C.MODE_ALLOW_FALLBACK) != 0 && cfg.secondary != address(0)) {
            if (cfg.secondary == self) {
                (data, isFresh) = readInternalOracle($, token, false);
                if (isFresh) { TCache.cacheOracleFeed(token, data); return data; }
                unchecked { lastAge = block.timestamp - data.updatedAt; lastMaxAge = data.ttl; }
            } else {
                try IOracle(cfg.secondary).getFeed(cfg.feedId) returns (IOracle.FeedData memory feedData) {
                    data = feedData;
                    try IOracle(cfg.secondary).isFeedFresh(cfg.feedId) returns (bool fresh) {
                        if (fresh) { TCache.cacheOracleFeed(token, data); return data; }
                        unchecked { lastAge = block.timestamp - data.updatedAt; lastMaxAge = data.ttl; }
                    } catch {}
                } catch {
                    if (primaryFailed) revert Err.NotConfigured(Err.Resource.ORACLE, token);
                }
            }
        } else if (primaryFailed) {
            revert Err.NotConfigured(Err.Resource.ORACLE, token);
        }
        revert Err.StaleData(uint32(lastAge), uint32(lastMaxAge));
    }

    /// @notice Init/reset feed accumulator (admin/owner gateway).
    function initFeed(
        IPool.PoolStorage storage $,
        address token,
        uint64 initialPrice,
        uint8 accDecimals,
        uint32 fastVolEMA,
        uint32 slowVolEMA
    ) internal {
        if (initialPrice == 0) revert Err.ZeroValue();
        if (accDecimals > 18) revert Err.InvalidInput();
        IPool.FeedAccumulator storage acc = $.accumulators[token];
        acc.lastPriceB64 = initialPrice;
        acc.accDecimals = accDecimals;
        acc.fastVolEMA = fastVolEMA;
        acc.slowVolEMA = slowVolEMA;
        acc.lastUpdate = uint32(block.timestamp);
        acc.ttl = DEFAULT_TTL;
        acc.confidence = 100;
        acc.priceAccB64 = 0;
        acc.fastSnapB64 = 0;
        acc.slowSnapB64 = 0;
        acc.fastSnapshotTime = uint32(block.timestamp);
        acc.slowSnapshotTime = uint32(block.timestamp);
        acc.fastOffset = 0;
        acc.slowOffset = 0;
    }

    /// @notice Compute fast TWAP price from accumulator + offset; returns B64.
    function computeFastTWAP(IPool.PoolStorage storage $, address token) internal view returns (uint64) {
        IPool.FeedAccumulator storage acc = $.accumulators[token];
        if (acc.lastUpdate == 0) revert Err.NotConfigured(Err.Resource.ORACLE, token);
        int32 off = acc.fastOffset;
        if (off == 0) return acc.lastPriceB64;
        uint256 spot = M.b64To1e18(acc.lastPriceB64);
        int256 mult = int256(Oracle.ORACLE_PBPS) + int256(off);
        if (mult <= 0) return M.encodeB64(1, 18);
        uint256 twap = FixedPointMathLib.fullMulDiv(spot, uint256(mult), Oracle.ORACLE_PBPS);
        return M.encodeB64(twap, 18);
    }

    /// @notice EMA update for vol field (uint32) w/ PBPS-denominated α + saturation.
    function updateVolEMA(uint32 oldVol, uint32 newVol, uint32 alpha) internal pure returns (uint32) {
        unchecked {
            uint256 o = oldVol;
            uint256 n = newVol;
            uint256 delta = n > o ? ((n - o) * alpha) / SC.PBPS : ((o - n) * alpha) / SC.PBPS;
            if (n > o) {
                uint256 r = o + delta;
                return r > type(uint32).max ? type(uint32).max : uint32(r);
            }
            return uint32(o - delta);
        }
    }
}
