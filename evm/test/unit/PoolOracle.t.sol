// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {PoolOracle} from "../../src/libraries/PoolOracle.sol";
import {Maths as M} from "../../src/libraries/Maths.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";

/// @notice Harness exposing PoolOracle internals over a slot-0 PoolStorage instance.
contract PoolOracleHarness {
    IPool.PoolStorage internal $;

    function setWnative(address w) external { $.wnative = w; }

    function pushFeedInternal(address a, address b, uint64 pa, uint64 pb) external {
        PoolOracle.pushFeedInternal($, a, b, pa, pb);
    }

    function updateFeeds(address t, uint64 p) external {
        PoolOracle.updateFeeds($, t, p);
    }

    function setAccDecimals(address t, uint8 dec) external {
        $.accumulators[t].accDecimals = dec;
    }

    function getAcc(address t) external view returns (IPool.FeedAccumulator memory) {
        return $.accumulators[t];
    }

    function setLastUpdate(address t, uint32 ts) external {
        $.accumulators[t].lastUpdate = ts;
    }

    function callUpdateVolEMA(uint32 oldVol, uint32 newVol, uint32 alpha) external pure returns (uint32) {
        return PoolOracle.updateVolEMA(oldVol, newVol, alpha);
    }
}

/// @title PoolOracleTest
/// @notice Phase 42H.D Round 2 (G7) — direct unit tests for PoolOracle library.
///         Covers: pushFeedInternal, updateFeeds, rollWindow, updateVolEMA across
///         edge cases (stale feeds, zero dt, MAX_STALENESS rollover, vol EMA boundary,
///         accDecimals 6/12/18).
contract PoolOracleTest is Test {
    PoolOracleHarness h;
    address constant TKA = address(0xA1);
    address constant TKB = address(0xB2);
    address constant WNATIVE = address(0xC3);

    function setUp() public {
        h = new PoolOracleHarness();
        h.setWnative(WNATIVE);
        vm.warp(1_700_000_000);
    }

    // ─── pushFeedInternal ───

    function test_pushFeedInternal_initializesBothFeeds() public {
        uint64 priceA = M.encodeB64(1e18, 6);
        uint64 priceB = M.encodeB64(2e18, 6);
        h.pushFeedInternal(TKA, TKB, priceA, priceB);

        IPool.FeedAccumulator memory a = h.getAcc(TKA);
        IPool.FeedAccumulator memory b = h.getAcc(TKB);
        assertEq(a.lastPriceB64, priceA);
        assertEq(b.lastPriceB64, priceB);
        assertEq(a.lastUpdate, uint32(block.timestamp));
        assertEq(b.lastUpdate, uint32(block.timestamp));
        assertEq(a.accDecimals, 6);
        assertEq(a.confidence, 100);
        assertEq(a.ttl, PoolOracle.DEFAULT_TTL);
    }

    function test_pushFeedInternal_skipsZeroAddrAndZeroPrice() public {
        uint64 priceA = M.encodeB64(1e18, 6);
        h.pushFeedInternal(address(0), TKB, priceA, 0);
        h.pushFeedInternal(TKA, TKB, 0, priceA);

        IPool.FeedAccumulator memory a = h.getAcc(TKA);
        IPool.FeedAccumulator memory b = h.getAcc(TKB);
        assertEq(a.lastUpdate, 0);
        assertEq(b.lastPriceB64, priceA);
    }

    // ─── updateFeeds: init + zero-dt ───

    function test_updateFeeds_firstCallInitializesAccumulator() public {
        uint64 p = M.encodeB64(1500e18, 6);
        h.updateFeeds(TKA, p);
        IPool.FeedAccumulator memory a = h.getAcc(TKA);
        assertEq(a.lastPriceB64, p);
        assertEq(a.fastVolEMA, uint32(SC.ONE_PCT_PBPS / 100));
        assertEq(a.slowVolEMA, uint32(SC.ONE_PCT_PBPS / 100));
        assertEq(a.fastSnapshotTime, uint32(block.timestamp));
        assertEq(a.slowSnapshotTime, uint32(block.timestamp));
    }

    function test_updateFeeds_zeroTimeDeltaIsNoOp() public {
        uint64 p1 = M.encodeB64(1000e18, 6);
        uint64 p2 = M.encodeB64(2000e18, 6);
        h.updateFeeds(TKA, p1);
        // No time advance → dt == 0 → early return; lastPriceB64 unchanged.
        h.updateFeeds(TKA, p2);
        IPool.FeedAccumulator memory a = h.getAcc(TKA);
        assertEq(a.lastPriceB64, p1, "zero-dt update must be no-op");
    }

    // ─── NATIVE → wnative remap ───

    function test_updateFeeds_remapsNATIVEtoWnative() public {
        uint64 p = M.encodeB64(1e18, 6);
        h.updateFeeds(SC.NATIVE, p);
        IPool.FeedAccumulator memory wn = h.getAcc(WNATIVE);
        IPool.FeedAccumulator memory nat = h.getAcc(SC.NATIVE);
        assertEq(wn.lastPriceB64, p);
        assertEq(nat.lastUpdate, 0, "raw NATIVE slot must remain empty");
    }

    // ─── MAX_STALENESS rollover ───

    function test_updateFeeds_clampsStalenessToMaxAndResetsSnapshots() public {
        uint64 p1 = M.encodeB64(1000e18, 6);
        uint64 p2 = M.encodeB64(1100e18, 6);
        h.updateFeeds(TKA, p1);

        // Jump > MAX_STALENESS (1 week + 1d)
        vm.warp(block.timestamp + PoolOracle.MAX_STALENESS + 1 days);
        h.updateFeeds(TKA, p2);

        IPool.FeedAccumulator memory a = h.getAcc(TKA);
        // After clamp, snapshots reset; new lastPrice/lastUpdate written.
        assertEq(a.lastPriceB64, p2);
        assertEq(a.lastUpdate, uint32(block.timestamp));
        assertGt(a.priceAccB64, 0);
    }

    // ─── rollWindow boundary (FAST_WINDOW elapsed) ───

    function test_rollWindow_fastSnapshotRollsOnceWindowElapsed() public {
        uint64 p1 = M.encodeB64(100e18, 6);
        uint64 p2 = M.encodeB64(110e18, 6);
        h.updateFeeds(TKA, p1);

        IPool.FeedAccumulator memory before = h.getAcc(TKA);
        uint32 beforeSnapTime = before.fastSnapshotTime;

        vm.warp(block.timestamp + PoolOracle.FAST_WINDOW + 10);
        h.updateFeeds(TKA, p2);

        IPool.FeedAccumulator memory aft = h.getAcc(TKA);
        assertGt(aft.fastSnapshotTime, beforeSnapTime, "fast snapshot must roll");
        assertEq(aft.fastSnapshotTime, uint32(block.timestamp));
    }

    function test_rollWindow_doesNotRollBeforeWindowElapsed() public {
        uint64 p1 = M.encodeB64(100e18, 6);
        uint64 p2 = M.encodeB64(101e18, 6);
        vm.warp(1_700_000_000);
        h.updateFeeds(TKA, p1);
        IPool.FeedAccumulator memory before = h.getAcc(TKA);

        vm.warp(1_700_000_000 + 60);  // far below FAST_WINDOW (300)
        h.updateFeeds(TKA, p2);

        IPool.FeedAccumulator memory aft = h.getAcc(TKA);
        assertEq(uint256(aft.fastSnapshotTime), uint256(before.fastSnapshotTime), "fast snapshot must NOT roll < window");
    }

    function test_rollWindow_slowWindowRollsIndependently() public {
        uint64 p1 = M.encodeB64(100e18, 6);
        uint64 p2 = M.encodeB64(105e18, 6);
        h.updateFeeds(TKA, p1);

        vm.warp(block.timestamp + PoolOracle.SLOW_WINDOW + 1);
        h.updateFeeds(TKA, p2);

        IPool.FeedAccumulator memory a = h.getAcc(TKA);
        assertEq(a.slowSnapshotTime, uint32(block.timestamp), "slow snap rolled");
        assertEq(a.fastSnapshotTime, uint32(block.timestamp), "fast also rolled (slow > fast)");
    }

    // ─── accDecimals variants ───

    function test_updateFeeds_accDecimals12_accumulates() public {
        uint64 p1 = M.encodeB64(1500e18, 12);
        uint64 p2 = M.encodeB64(1600e18, 12);
        h.updateFeeds(TKA, p1);
        h.setAccDecimals(TKA, 12);
        vm.warp(block.timestamp + 60);
        h.updateFeeds(TKA, p2);
        IPool.FeedAccumulator memory a = h.getAcc(TKA);
        assertEq(a.accDecimals, 12);
        assertGt(a.priceAccB64, 0);
    }

    function test_updateFeeds_accDecimals18_accumulates() public {
        uint64 p1 = M.encodeB64(50_000e18, 18);
        uint64 p2 = M.encodeB64(51_000e18, 18);
        h.updateFeeds(TKA, p1);
        h.setAccDecimals(TKA, 18);
        vm.warp(block.timestamp + 30);
        h.updateFeeds(TKA, p2);
        IPool.FeedAccumulator memory a = h.getAcc(TKA);
        assertEq(a.accDecimals, 18);
        assertGt(a.priceAccB64, 0);
    }

    // ─── updateVolEMA ───

    function test_updateVolEMA_unchangedWhenInputEqualsOld() public view {
        uint32 r = h.callUpdateVolEMA(500, 500, 200);
        assertEq(r, 500);
    }

    function test_updateVolEMA_increasesTowardLargerInput() public view {
        uint32 r = h.callUpdateVolEMA(100, 1000, uint32(SC.PBPS / 2));
        assertGt(r, 100);
        assertLe(r, 1000);
    }

    function test_updateVolEMA_decreasesTowardSmallerInput() public view {
        uint32 r = h.callUpdateVolEMA(1000, 100, uint32(SC.PBPS / 2));
        assertLt(r, 1000);
        assertGe(r, 100);
    }

    function test_updateVolEMA_saturatesAtUint32Max() public view {
        uint32 r = h.callUpdateVolEMA(type(uint32).max - 10, type(uint32).max, uint32(SC.PBPS));
        assertEq(r, type(uint32).max);
    }

    function test_updateVolEMA_alphaZeroIsNoOp() public view {
        uint32 r = h.callUpdateVolEMA(777, 9999, 0);
        assertEq(r, 777);
    }
}
