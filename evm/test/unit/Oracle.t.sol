// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {BaseTestSetup} from "../fixtures/BaseTestSetup.sol";
import {Oracle} from "../../src/libraries/Oracle.sol";
import {Maths as M} from "../../src/libraries/Maths.sol";
import {Constants as C} from "../../src/libraries/Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";

/// @title LibOracleTest
/// @notice Unit tests for the external-mark oracle lib: mark decode, single σ, on-chain EMA
///         recurrence (rate clamp + time decay), and the synthetic base feed.
contract LibOracleTest is BaseTestSetup {
    // ─── mark / getSigma ───

    function test_mark_returns_lastPrice_1e18() public view {
        IOracle.FeedData memory f = makeFeedData(M.encodeB64(3000e18, 18), VOL_1_PCT, 5);
        assertApproxEqRel(Oracle.mark(f), 3000e18, 0.0001e18, "mark = b64To1e18(lastPrice)");
    }

    function test_getSigma_passthrough() public view {
        IOracle.FeedData memory f = makeFeedData(M.encodeB64(1e18, 18), 300_000, 0);
        assertEq(Oracle.getSigma(f), 300_000, "sigma is a single passthrough field");
    }

    // ─── getBaseFeed ───

    function test_getBaseFeed_isUnitAndNeverExpires() public view {
        IOracle.FeedData memory f = Oracle.getBaseFeed();
        assertApproxEqRel(Oracle.mark(f), SC.WAD, 0.0001e18, "base mark = 1.0");
        assertEq(f.lastPriceB64, f.emaPriceB64, "base ema == mark");
        assertEq(uint256(f.sigmaEma), SC.ONE_PCT_PBPS, "base sigmaEma = 1%");
        assertEq(f.ttl, type(uint16).max, "base never expires");
        assertEq(f.confidence, 0, "base has no CI");
    }

    // ─── updateEma: freeze / jump / clamp / decay ───

    /// Same block (Δt==0) ⇒ α=0 ⇒ the EMA is frozen regardless of the mark.
    function test_updateEma_sameBlockFrozen() public pure {
        uint64 ema = M.encodeB64(100e18, 18);
        uint64 got = Oracle.updateEma(ema, M.encodeB64(200e18, 18), 0, 100, 500);
        assertApproxEqRel(M.b64To1e18(got), 100e18, 0.0001e18, "dt=0 freezes the EMA");
    }

    /// τ==0 ⇒ α=1 ⇒ the EMA jumps straight to the (clamped) mark.
    function test_updateEma_tauZeroJumpsToClampedMark() public pure {
        uint64 got = Oracle.updateEma(M.encodeB64(100e18, 18), M.encodeB64(101e18, 18), 10, 0, 500);
        assertApproxEqRel(M.b64To1e18(got), 101e18, 0.001e18, "tau=0 tracks the mark within band");
    }

    /// A single manipulated push (10x mark) displaces the EMA by AT MOST α·band. Here band = ema·K·CI:
    /// 100·8·(100bps)/BPS = 8, α=1 ⇒ new EMA = 108, NOT 1000. This is the LVR/manipulation guard.
    function test_updateEma_clampBoundsSinglePush() public pure {
        uint256 conf = 100; // 1% CI
        uint64 ema = M.encodeB64(100e18, 18);
        uint64 got = Oracle.updateEma(ema, M.encodeB64(1000e18, 18), 100, 100, uint16(conf));
        uint256 band = (100e18 * C.K_BAND * conf) / SC.BPS; // = 8e18
        assertApproxEqRel(M.b64To1e18(got), 100e18 + band, 0.001e18, "displaced by exactly alpha*band");
        assertLe(M.b64To1e18(got), 100e18 + band + 1e15, "never exceeds ema+band");
    }

    /// A huge claimed confidence cannot widen the band past MAX_BAND_BPS (20%): displacement ≤ 20.
    function test_updateEma_bandCappedByMaxBand() public pure {
        uint64 got = Oracle.updateEma(M.encodeB64(100e18, 18), M.encodeB64(1000e18, 18), 100, 100, type(uint16).max);
        uint256 cap = (100e18 * C.MAX_BAND_BPS) / SC.BPS; // = 20e18
        assertApproxEqRel(M.b64To1e18(got), 100e18 + cap, 0.001e18, "band capped at MAX_BAND_BPS");
    }

    /// Partial time decay: dt/τ = 0.5, mark within band ⇒ EMA moves half-way toward the mark.
    function test_updateEma_partialDecay() public pure {
        uint64 got = Oracle.updateEma(M.encodeB64(100e18, 18), M.encodeB64(105e18, 18), 50, 100, 1000);
        assertApproxEqRel(M.b64To1e18(got), 102.5e18, 0.002e18, "alpha=0.5 half-step to mark");
    }

    /// conf==0 must NOT zero the rate-clamp band: band=0 would clamp every mark back to the current
    /// ema forever (isFeedFresh stays true), permanently freezing the servable EMA — a no-brick
    /// violation. With the confidence floor the ema still converges (K_BAND bps/push) toward the mark.
    function test_updateEma_zeroConfidenceStillConverges() public pure {
        uint64 ema = M.encodeB64(100e18, 18);
        uint64 target = M.encodeB64(110e18, 18);
        // First push must MOVE (pre-fix: band=0 ⇒ frozen at 100 forever).
        uint64 first = Oracle.updateEma(ema, target, 100, 100, 0); // α=1, conf=0
        assertGt(M.b64To1e18(first), 100e18, "conf=0 must not freeze the EMA");
        // And keep converging: band/push = K_BAND bps ⇒ +10% needs ~120 pushes; 500 is ample.
        for (uint256 i; i < 500; ++i) {
            ema = Oracle.updateEma(ema, target, 100, 100, 0);
        }
        assertApproxEqRel(M.b64To1e18(ema), 110e18, 0.001e18, "conf=0 EMA converges to the mark");
    }

    function test_updateSigmaEma_zeroSampleRatchetsOnMarkMove() public pure {
        uint32 got = Oracle.updateSigmaEma(1e4, 0, 3000e18, 3300e18, 100, 100);
        assertGt(got, 1e4, "evidence floor lifts sigmaEma above sample=0");
    }

    function test_updateSigmaEma_sameBlockFrozen() public pure {
        uint32 got = Oracle.updateSigmaEma(1e4, 2e4, 3000e18, 3100e18, 0, 100);
        assertEq(got, 1e4, "dt=0 freezes sigmaEma");
    }
}
