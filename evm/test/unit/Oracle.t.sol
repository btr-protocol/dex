// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {BaseTestSetup} from "../fixtures/BaseTestSetup.sol";
import {Oracle} from "../../src/libraries/Oracle.sol";
import {Maths as M} from "../../src/libraries/Maths.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";

/// @title LibOracleTest
/// @notice Unit tests for the external-mark oracle lib: mark decode, single σ, σ-EMA fold, and
///         the synthetic base feed.
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

    // ─── getPegFeed (unit peg / base-numeraire stand-in) ───

    function test_getPegFeed_isUnitAndNeverExpires() public view {
        IOracle.FeedData memory f = Oracle.getPegFeed(M.encodeB64(SC.WAD, 18), uint32(SC.ONE_PCT_PBPS));
        assertApproxEqRel(Oracle.mark(f), SC.WAD, 0.0001e18, "peg mark = 1.0");
        assertEq(uint256(f.sigmaEma), SC.ONE_PCT_PBPS, "peg sigmaEma = 1%");
        assertEq(f.ttl, type(uint16).max, "peg never expires");
        assertEq(f.confidence, 0, "peg has no CI");
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
