// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Base} from "./Base.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Err} from "@btr-shared/Errors.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IPool} from "../interfaces/IPool.sol";
import {Maths as M} from "../libraries/Maths.sol";
import {Oracle} from "../libraries/Oracle.sol";
import {Constants as C} from "../libraries/Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title InternalOracle
/// @notice Internal TWAP oracle, swap-driven updates, single-slot accumulators
contract InternalOracle is Base {
    using {M.b64To1e18} for uint64;

    constructor(address ac_) Base(ac_) {}

    uint32 public constant FAST_WINDOW = 300;          // 5min
    uint32 public constant SLOW_WINDOW = 3600;         // 1h
    uint32 public constant FAST_VOL_ALPHA = 200;       // 0.02% PBPS
    uint32 public constant SLOW_VOL_ALPHA = 1800;      // 0.18% PBPS
    uint32 public constant MAX_VOLATILITY = 100 * uint32(SC.PBPS);
    uint16 public constant DEFAULT_TTL = 3600;
    uint256 private constant MAX_STALENESS = 604800;   // 7 days


    function getFeed(address token) external view returns (IOracle.FeedData memory data) {
        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        IPool.FeedAccumulator storage acc = _os().accumulators[t];
        if (acc.lastUpdate == 0) revert Err.NotConfigured(Err.Resource.ORACLE, t);

        data = IOracle.FeedData({
            lastPriceB64: acc.lastPriceB64,
            fastOffset: acc.fastOffset,
            slowOffset: acc.slowOffset,
            fastVolEMA: acc.fastVolEMA,
            slowVolEMA: acc.slowVolEMA,
            updatedAt: acc.lastUpdate,
            ttl: acc.ttl,
            confidence: acc.confidence
        });
    }

    function isFeedFresh(address token, uint32 maxAge) external view returns (bool) {
        IPool.PoolStorage storage $ = _s();
        IPool.FeedAccumulator storage acc = _os().accumulators[_wrap($, token)];
        if (acc.lastUpdate == 0) return false;
        unchecked { return block.timestamp - acc.lastUpdate <= maxAge; }
    }

    function isFeedFresh(address token) external view returns (bool) {
        IPool.PoolStorage storage $ = _s();
        IPool.FeedAccumulator storage acc = _os().accumulators[_wrap($, token)];
        if (acc.lastUpdate == 0) return false;
        unchecked { return block.timestamp - acc.lastUpdate <= acc.ttl; }
    }

    /// @notice Time-weighted average price over fast window (5min).
    /// @dev R2-A1-1 fix: symmetric to Oracle._applyOffset / encodeOffset1e18.
    ///      Encoding: offset = (twap*ORACLE_PBPS/spot) - ORACLE_PBPS  (Oracle.encodeOffset1e18)
    ///      Decoding: twap   = spot*(ORACLE_PBPS+offset)/ORACLE_PBPS  (Oracle._applyOffset)
    ///      Degenerate (multiplier ≤ 0): clamp to 1 wei (matches _applyOffset). Reverts if feed not configured.
    function getFastTWAP(address token) external view returns (uint64 fastTWAP) {
        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        IPool.FeedAccumulator storage acc = _os().accumulators[t];
        if (acc.lastUpdate == 0) revert Err.NotConfigured(Err.Resource.ORACLE, t);

        int32 off = acc.fastOffset;
        if (off == 0) return acc.lastPriceB64;
        uint256 spot = M.b64To1e18(acc.lastPriceB64);
        int256 mult = int256(Oracle.ORACLE_PBPS) + int256(off);
        if (mult <= 0) return M.encodeB64(1, 18); // degenerate: clamp to 1 wei (matches _applyOffset)
        // Phase 42D R3-A4-1: fullMulDiv hardens against theoretical b64-extreme overflow
        // (spot up to ~4.5e76 × mult up to ~2.16e9 > uint256.max). Realistic spot ≤ 1e30 → safe.
        uint256 twap = FixedPointMathLib.fullMulDiv(spot, uint256(mult), Oracle.ORACLE_PBPS);
        return M.encodeB64(twap, 18);
    }


    /// @notice Init/reset feed. accDecimals: 6=stables, 12=ETH, 18=BTC.
    function updateFeed(
        address token,
        uint64 initialPrice,
        uint8 accDecimals,
        uint32 fastVolEMA,
        uint32 slowVolEMA
    ) external {
        if (msg.sender != _owner() && msg.sender != address(this)) revert Ownable.Unauthorized();
        if (initialPrice == 0) revert Err.ZeroValue();
        if (accDecimals > 18) revert Err.InvalidInput();

        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        IPool.FeedAccumulator storage acc = _os().accumulators[t];

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

        emit IOracle.OracleUpdated(t, initialPrice, fastVolEMA, slowVolEMA);
    }

    /// @dev Disabled — internal oracle updates via pushFeedInternal on swaps
    function pushFeed(address, uint64, uint32) external pure {
        revert Err.InvalidInput();
    }


    /// @notice Push prices from swap exec. Called only by self.
    /// @dev Phase 42H.B.2: kept for module-routed calls (Pool no longer self-calls; it inherits
    ///      and uses _pushFeedInternal directly). Still registered as a selector on PoolProxy
    ///      until 42H.B.3 promotes modules out of the Diamond.
    function pushFeedInternal(
        address tokenA,
        address tokenB,
        uint64 priceA,
        uint64 priceB
    ) external {
        if (msg.sender != address(this)) revert Ownable.Unauthorized();
        _pushFeedInternal(tokenA, tokenB, priceA, priceB);
    }

    /// @dev Inlined hot path for inheriting modules (Pool). Skips msg.sender guard ∵ caller
    ///      is in-contract code, ! external entrypoint.
    function _pushFeedInternal(
        address tokenA,
        address tokenB,
        uint64 priceA,
        uint64 priceB
    ) internal {
        IPool.PoolStorage storage $ = _s();
        if (tokenA != address(0) && priceA != 0) _updateFeeds($, tokenA, priceA);
        if (tokenB != address(0) && priceB != 0) _updateFeeds($, tokenB, priceB);
    }

    function _updateFeeds(IPool.PoolStorage storage $, address token, uint64 newPrice) private {
        address t = _wrap($, token);
        IPool.FeedAccumulator storage acc = _os().accumulators[t];
        uint32 currentTime = uint32(block.timestamp);

        // First update: init w/ defaults
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
            return;
        }

        unchecked {
            uint256 dt = currentTime - acc.lastUpdate;
            // Phase 42D A3-5 DISCARD (by-design): first-swap-wins within a block.
            // Manipulation guard against last-swap-wins; front-runner cannot "pin" oracle
            // any worse than first-swapper. Acceptable trade-off — multi-block TWAP smooths.
            // F-A4-R14-1 (R14 INFO, DISCARDED): `lastPriceInAccDec * dt` and accumulator add
            // are unchecked. Realistic decoded prices (≤ ~1e30 even for extreme b64 mantissas
            // with accDec ≤ 18) × MAX_STALENESS (6.048e5) ≤ ~6e35 << uint256.max (~1.16e77).
            // Pathological b64 inputs would require accDec at the upper bound AND mantissa near
            // uint64.max — neither reachable through the validated push paths. Wrapping the
            // mul in checked arith would burn gas on every swap with no realistic safety gain.
            if (dt == 0) return; // same block — manipulation guard

            // Stale > 7d → cap dt + reset snapshots so TWAP rebuilds clean
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

            _rollWindow(acc, accDec, currentAcc, lastPriceInt, currentTime, true);
            _rollWindow(acc, accDec, currentAcc, lastPriceInt, currentTime, false);

            uint32 priceChange = M.diff1e6(acc.lastPriceB64, newPrice);
            acc.fastVolEMA = _updateVolEMA(acc.fastVolEMA, priceChange, FAST_VOL_ALPHA);
            acc.slowVolEMA = _updateVolEMA(acc.slowVolEMA, priceChange, SLOW_VOL_ALPHA);

            acc.lastPriceB64 = newPrice;
            acc.lastUpdate = currentTime;
            acc.confidence = 100;
        }
    }

    /// @dev Roll fast or slow TWAP window. Underflow-safe (resets on snapshot > current).
    function _rollWindow(
        IPool.FeedAccumulator storage acc,
        uint8 accDec,
        uint256 currentAcc,
        uint256 lastPriceInt,
        uint32 currentTime,
        bool isFast
    ) private {
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

    function _updateVolEMA(uint32 oldVol, uint32 newVol, uint32 alpha) private pure returns (uint32) {
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
