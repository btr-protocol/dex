// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Base} from "./Base.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Err} from "@btr-peripheral/Errors.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IPool} from "../interfaces/IPool.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";
import {LibOracle} from "../libraries/LibOracle.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";

/// @title InternalOracle
/// @notice Internal TWAP oracle, swap-driven updates, single-slot accumulators
contract InternalOracle is Base {
    using {M.b64To1e18} for uint64;

    uint32 public constant FAST_WINDOW = 300;          // 5min
    uint32 public constant SLOW_WINDOW = 3600;         // 1h
    uint32 public constant FAST_VOL_ALPHA = 200;       // 0.02% PBPS
    uint32 public constant SLOW_VOL_ALPHA = 1800;      // 0.18% PBPS
    uint32 public constant MAX_VOLATILITY = 100 * uint32(C.PBPS);
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

    /// @dev Returns spot (not real TWAP). NB: dependents should use getFeed.fastOffset for true TWAP.
    function getFastTWAP(address token) external view returns (uint64 fastTWAP) {
        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        IPool.FeedAccumulator storage acc = _os().accumulators[t];
        if (acc.lastUpdate == 0) revert Err.NotConfigured(Err.Resource.ORACLE, t);
        return acc.lastPriceB64;
    }


    /// @notice Init/reset feed. accDecimals: 6=stables, 12=ETH, 18=BTC.
    function updateFeed(
        address token,
        uint64 initialPrice,
        uint8 accDecimals,
        uint32 fastVolEMA,
        uint32 slowVolEMA
    ) external {
        if (msg.sender != _s().owner && msg.sender != address(this)) revert Ownable.Unauthorized();
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
    function pushFeedInternal(
        address tokenA,
        address tokenB,
        uint64 priceA,
        uint64 priceB
    ) external {
        if (msg.sender != address(this)) revert Ownable.Unauthorized();
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
            acc.fastVolEMA = uint32(C.ONE_PCT_PBPS / 100);
            acc.slowVolEMA = uint32(C.ONE_PCT_PBPS / 100);
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
            int32 offset = LibOracle.encodeOffset1e18(lastPriceInt, twap);
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
            uint256 delta = n > o ? ((n - o) * alpha) / C.PBPS : ((o - n) * alpha) / C.PBPS;
            if (n > o) {
                uint256 r = o + delta;
                return r > type(uint32).max ? type(uint32).max : uint32(r);
            }
            return uint32(o - delta);
        }
    }
}
