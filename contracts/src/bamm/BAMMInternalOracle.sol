// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IInternalOracle} from "../interfaces/IInternalOracle.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {LibStorage as S} from "../libraries/LibStorage.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";
import {LibOracle} from "../libraries/LibOracle.sol";
import {LibDiamondStorage} from "../libraries/LibDiamondStorage.sol";
import {BAMMErrors as E} from "./BAMMErrors.sol";

/// @title BAMMInternalOracle
/// @notice Oracle facet - manages internal accumulator-based oracles
/// @dev Implements Uniswap V3-style TWAP accumulator with offset-based EMA encoding
/// @dev Single-slot updates via IOracle.FeedData struct
contract BAMMInternalOracle {

    // ========== CONSTANTS ==========

    /// @notice Default EMA volatility update rate (alpha in 1e6 base)
    /// @dev 200 = 0.02% alpha (fast EMA updates quickly)
    /// @dev 1800 = 0.18% alpha (slow EMA moves glacially)
    uint32 internal constant DEFAULT_FAST_VOL_ALPHA = 200;
    uint32 internal constant DEFAULT_SLOW_VOL_ALPHA = 1800;

    // ========== MODIFIERS ==========

    modifier onlyOwner() {
        LibDiamondStorage.DiamondStorage storage d = LibDiamondStorage.ds();
        if (msg.sender != d.owner) revert E.Unauthorized();
        _;
    }

    // ========== ACCUMULATOR UPDATE ==========

    /// @notice Update accumulator with new spot price
    /// @dev Computes TWAPs and updates offsets (✅ single SSTORE via FeedData struct)
    /// @param token Token address
    /// @param spotPrice New spot price (b64 format)
    /// @param spotVol New volatility measurement (1e6 base: 1_000_000 = 1%)
    /// @param confidence Oracle confidence (0-100)
    function updateAccumulator(
        address token,
        uint64 spotPrice,
        uint32 spotVol,
        uint16 confidence
    ) external onlyOwner {
        if (spotPrice == 0) revert E.InvalidPrice();
        if (spotVol > 100_000_000) revert E.InvalidVolatility();  // Max 10,000%
        if (confidence > 100) revert E.InvalidConfidence();

        IBAMM.BAMMStorage storage $ = S.bamm();
        bytes32 feedId = S.computeOracleId(token, $.baseToken);
        IInternalOracle.InternalFeedData storage feed = $.internalFeeds[feedId];

        uint256 now = block.timestamp;

        // First update: initialize
        if (feed.base.updatedAt == 0) {
            feed.base.currentPrice = spotPrice;
            feed.base.fastOffset = 0;      // EMAs start at current price
            feed.base.slowOffset = 0;
            feed.base.fastVolEMA = spotVol;
            feed.base.slowVolEMA = spotVol;
            feed.base.updatedAt = uint32(now);
            feed.base.confidence = confidence;
            feed.base.ttl = 3600;  // Default 1 hour

            feed.priceAccumulator = 0;
            feed.fastAccumSnapshot = 0;
            feed.slowAccumSnapshot = 0;
            feed.fastSnapshotTime = uint32(now);
            feed.slowSnapshotTime = uint32(now);
            feed.fastWindow = 300;   // 5 minutes
            feed.slowWindow = 3600;  // 1 hour

            emit IBAMM.OracleFeedUpdated(feedId, feed.base, msg.sender);
            return;
        }

        // Update accumulator with time elapsed
        uint256 dt = now - feed.base.updatedAt;
        if (dt == 0) return;

        feed.priceAccumulator += uint256(feed.base.currentPrice) * dt;
        uint256 accum = feed.priceAccumulator;

        // Compute Fast TWAP if window elapsed
        uint256 dtFast = now - feed.fastSnapshotTime;
        if (dtFast >= feed.fastWindow && dtFast > 0) {
            uint64 fastTWAP = uint64((accum - feed.fastAccumSnapshot) / dtFast);
            // ✅ ENCODE as offset from NEW spot price
            feed.base.fastOffset = LibOracle.encodeOffset(spotPrice, fastTWAP);
            feed.fastAccumSnapshot = accum;
            feed.fastSnapshotTime = uint32(now);
        } else {
            // Re-encode existing fast EMA relative to new current price
            uint64 oldFastEMA = LibOracle.decodeFastEMA(feed.base.currentPrice, feed.base.fastOffset);
            feed.base.fastOffset = LibOracle.encodeOffset(spotPrice, oldFastEMA);
        }

        // Compute Slow TWAP if window elapsed
        uint256 dtSlow = now - feed.slowSnapshotTime;
        if (dtSlow >= feed.slowWindow && dtSlow > 0) {
            uint64 slowTWAP = uint64((accum - feed.slowAccumSnapshot) / dtSlow);
            // ✅ ENCODE as offset from NEW spot price
            feed.base.slowOffset = LibOracle.encodeOffset(spotPrice, slowTWAP);
            feed.slowAccumSnapshot = accum;
            feed.slowSnapshotTime = uint32(now);
        } else {
            // Re-encode existing slow EMA relative to new current price
            uint64 oldSlowEMA = LibOracle.decodeSlowEMA(feed.base.currentPrice, feed.base.slowOffset);
            feed.base.slowOffset = LibOracle.encodeOffset(spotPrice, oldSlowEMA);
        }

        // ✅ UPDATE CURRENT PRICE (all offsets now relative to this)
        feed.base.currentPrice = spotPrice;
        feed.base.updatedAt = uint32(now);
        feed.base.confidence = confidence;

        // Update volatility EMAs
        feed.base.fastVolEMA = _updateVolEMA(feed.base.fastVolEMA, spotVol, DEFAULT_FAST_VOL_ALPHA);
        feed.base.slowVolEMA = _updateVolEMA(feed.base.slowVolEMA, spotVol, DEFAULT_SLOW_VOL_ALPHA);

        // ✅ SINGLE SSTORE: all fields packed in one slot
        emit IBAMM.OracleFeedUpdated(feedId, feed.base, msg.sender);
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Get oracle feed data (single-slot read)
    /// @dev Returns the compact FeedData struct
    function getFeedData(address token) external view returns (IOracle.FeedData memory data) {
        IBAMM.BAMMStorage storage $ = S.bamm();
        bytes32 feedId = S.computeOracleId(token, $.baseToken);
        IInternalOracle.InternalFeedData storage feed = $.internalFeeds[feedId];

        // ✅ SINGLE SLOAD
        return feed.base;
    }

    /// @notice Get oracle data with decoded prices
    /// @dev Decodes offsets to get fast/slow EMAs
    function getOracleDataWithPrices(address token)
        external
        view
        returns (IOracle.FeedData memory feed, uint256 priceFast, uint256 priceSlow)
    {
        IBAMM.BAMMStorage storage $ = S.bamm();
        bytes32 feedId = S.computeOracleId(token, $.baseToken);
        IInternalOracle.InternalFeedData storage f = $.internalFeeds[feedId];

        feed = f.base;
        (priceFast, priceSlow) = LibOracle.decodePrices(feed);
    }

    // ========== INTERNAL HELPERS ==========

    /// @notice Update volatility EMA using exponential smoothing
    /// @dev newVol = oldVol * (1 - alpha) + newVol * alpha
    /// @param oldVol Previous volatility (1e6 base)
    /// @param newVol Current volatility measurement (1e6 base)
    /// @param alpha EMA smoothing factor (1e6 base: 200 = 0.02%)
    /// @return updatedVol Updated volatility EMA
    function _updateVolEMA(uint32 oldVol, uint32 newVol, uint32 alpha)
        internal
        pure
        returns (uint32 updatedVol)
    {
        // newVol = oldVol + (newVol - oldVol) * alpha / 1e6
        uint256 oldVol256 = uint256(oldVol);
        uint256 newVol256 = uint256(newVol);
        uint256 alpha256 = uint256(alpha);

        uint256 delta = newVol256 > oldVol256
            ? (newVol256 - oldVol256) * alpha256 / 1_000_000
            : (oldVol256 - newVol256) * alpha256 / 1_000_000;

        if (newVol256 > oldVol256) {
            updatedVol = uint32(oldVol256 + delta);
            // Clamp to uint32 max
            if (updatedVol < uint32(oldVol256)) updatedVol = type(uint32).max;
        } else {
            updatedVol = uint32(oldVol256 - delta);
        }
    }
}
