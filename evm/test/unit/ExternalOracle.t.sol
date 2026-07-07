// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {ExternalOracle} from "../../src/oracles/ExternalOracle.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {Oracle} from "../../src/libraries/Oracle.sol";
import {Maths as M} from "../../src/libraries/Maths.sol";
import {Constants as C} from "../../src/libraries/Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Err} from "@btr-shared/Errors.sol";
import {MockAC} from "../fixtures/BaseTestSetup.sol";

contract ExternalOracleTest is Test {
    ExternalOracle ext;
    MockAC ac;
    address constant BASE = address(0xB05E);
    address constant QUOTE = address(0x9907E);
    bytes32 feedId;

    uint16 constant TAU = 100;

    function setUp() public {
        ac = new MockAC(address(this));
        ext = new ExternalOracle(address(ac), address(this));
        vm.warp(1_700_000_000);
        ext.addFeed(BASE, QUOTE, M.encodeB64(3000e18, 18), 1e4, 5, TAU, TAU, 0, 3600);
        feedId = keccak256(abi.encodePacked(BASE, QUOTE));
    }

    function test_addFeed_seedsLastEqualsEma() public view {
        IOracle.FeedData memory f = ext.getFeed(feedId);
        assertEq(f.lastPriceB64, f.emaPriceB64, "seed: lastPrice == ema");
        assertApproxEqRel(Oracle.mark(f), 3000e18, 0.0005e18, "seed mark = 3000");
        assertEq(f.tau, TAU, "tau stored");
        assertEq(f.tauSigma, TAU, "tauSigma stored");
        assertEq(f.sigmaEma, 1e4, "sigmaEma seeded from sample");
        assertEq(f.confidence, 5, "confidence stored");
    }

    function test_pushFeed_commitsFreshMark_decaysEma() public {
        vm.warp(block.timestamp + TAU);
        ext.pushFeed(feedId, M.encodeB64(3030e18, 18), 1e4, 5);
        IOracle.FeedData memory f = ext.getFeed(feedId);
        assertApproxEqRel(M.b64To1e18(f.lastPriceB64), 3030e18, 0.001e18, "lastPrice = fresh mark");
        assertApproxEqRel(M.b64To1e18(f.emaPriceB64), 3030e18, 0.01e18, "ema decayed toward mark");
        assertEq(f.updatedAt, uint32(block.timestamp), "updatedAt stamped");
        assertEq(f.ttl, 3600, "ttl preserved across push");
        assertEq(f.tau, TAU, "tau preserved across push");
        assertEq(f.tauSigma, TAU, "tauSigma preserved across push");
    }

    function test_pushFeed_emaClampBoundsManipulation() public {
        vm.warp(block.timestamp + TAU);
        uint256 emaBefore = 3000e18;
        ext.pushFeed(feedId, M.encodeB64(15000e18, 18), 1e4, 5);
        IOracle.FeedData memory f = ext.getFeed(feedId);
        uint256 band = (emaBefore * C.K_BAND * 5) / SC.BPS;
        assertApproxEqRel(M.b64To1e18(f.emaPriceB64), emaBefore + band, 0.01e18, "ema displaced <= band");
        assertApproxEqRel(M.b64To1e18(f.lastPriceB64), 15000e18, 0.001e18, "mark still commits raw");
    }

    function test_pushFeed_sameBlockFreezesEmaAndSigmaEma() public {
        uint64 emaSeed = ext.getFeed(feedId).emaPriceB64;
        uint32 sigmaSeed = ext.getFeed(feedId).sigmaEma;
        ext.pushFeed(feedId, M.encodeB64(3100e18, 18), 500, 5);
        IOracle.FeedData memory f = ext.getFeed(feedId);
        assertEq(f.emaPriceB64, emaSeed, "same-block ema frozen");
        assertEq(f.sigmaEma, sigmaSeed, "same-block sigmaEma frozen");
        assertApproxEqRel(M.b64To1e18(f.lastPriceB64), 3100e18, 0.001e18, "mark updated same block");
    }

    /// σ sample=0 cannot collapse sigmaEma when mark moves — evidence floor ratchets from |Δmark|.
    function test_sigmaEma_evidenceFloor_blocksZeroSampleOnMove() public {
        vm.warp(block.timestamp + TAU);
        ext.pushFeed(feedId, M.encodeB64(3300e18, 18), 0, 5); // +10% move, sample 0
        IOracle.FeedData memory f = ext.getFeed(feedId);
        assertGt(f.sigmaEma, 1e4, "sigmaEma must ratchet above seed on mark move");
        assertEq(f.sigmaEma, 2e4, "clamped up one full band from 1% seed");
    }

    function test_batchPush_updatesFeeds() public {
        vm.warp(block.timestamp + TAU);
        bytes32[] memory ids = new bytes32[](1);
        uint64[] memory prices = new uint64[](1);
        uint32[] memory sigmas = new uint32[](1);
        uint16[] memory confs = new uint16[](1);
        ids[0] = feedId;
        prices[0] = M.encodeB64(3050e18, 18);
        sigmas[0] = 2e4;
        confs[0] = 7;
        ext.batchPush(ids, prices, sigmas, confs);
        IOracle.FeedData memory f = ext.getFeed(feedId);
        assertApproxEqRel(M.b64To1e18(f.lastPriceB64), 3050e18, 0.001e18, "batch mark");
        assertEq(f.sigmaEma, 2e4, "batch sigmaEma toward sample");
        assertEq(f.confidence, 7, "batch confidence");
    }

    function test_getEma_returnsReference() public view {
        assertEq(ext.getEma(feedId), ext.getFeed(feedId).emaPriceB64, "getEma = emaPriceB64");
    }

    function test_pushFeed_rejectsZeroPrice() public {
        vm.expectRevert(Err.ZeroValue.selector);
        ext.pushFeed(feedId, 0, 1e4, 5);
    }

    function test_pushFeed_rejectsExcessiveSigma() public {
        uint32 badSigma = ext.MAX_VOLATILITY() + 1;
        vm.expectRevert();
        ext.pushFeed(feedId, M.encodeB64(3000e18, 18), badSigma, 5);
    }

    function test_pushFeed_onlyOracle() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(Err.NotAuth.selector);
        ext.pushFeed(feedId, M.encodeB64(3000e18, 18), 1e4, 5);
    }

    function test_grantOracle_allowsSafeAsPusher() public {
        address safe = address(0x5AFE);
        ext.grantOracle(safe);
        assertTrue(ext.isOracle(safe), "multisig address can be oracle pusher");
    }

    // ─── BUG#1 (D1): opt-in per-feed push deviation clamp ───

    address constant DA = address(0xDA5E);
    address constant DB = address(0xDB5E);
    uint16 constant DEV_BAND = 500; // 5% in bps
    uint16 constant DEV_TTL = 3600;

    /// Add a fresh feed at price 100 with a per-push band; returns its id.
    function _addBandedFeed(uint16 band) internal returns (bytes32 id) {
        ext.addFeed(DA, DB, M.encodeB64(100e18, 18), 1e4, 5, TAU, TAU, band, DEV_TTL);
        id = keccak256(abi.encodePacked(DA, DB));
    }

    function test_maxDeviation_storedAtAddFeed() public {
        bytes32 id = _addBandedFeed(DEV_BAND);
        assertEq(ext.maxDeviations(id), DEV_BAND, "maxDeviation persisted at addFeed");
    }

    /// A push within the band on a fresh, in-heartbeat feed commits normally (fast/light unslowed).
    function test_maxDeviation_withinBand_pushSucceeds() public {
        bytes32 id = _addBandedFeed(DEV_BAND);
        skip(10); // dt=10 < ttl → in-band regime
        ext.pushFeed(id, M.encodeB64(104e18, 18), 1e4, 5); // +4% < 5%
        assertApproxEqRel(Oracle.mark(ext.getFeed(id)), 104e18, 0.001e18, "in-band mark committed");
    }

    /// A push beyond the band WITHIN the heartbeat is rejected (fail-closed): last good mark survives.
    function test_maxDeviation_outOfBand_withinHeartbeat_reverts() public {
        bytes32 id = _addBandedFeed(DEV_BAND);
        skip(10); // dt=10 < ttl → clamp active
        vm.expectRevert(abi.encodeWithSelector(Err.ThresholdViolation.selector, uint256(1000), uint256(DEV_BAND)));
        ext.pushFeed(id, M.encodeB64(110e18, 18), 1e4, 5); // +10% > 5%
        assertApproxEqRel(Oracle.mark(ext.getFeed(id)), 100e18, 0.001e18, "mark unchanged after reject");
    }

    /// After the heartbeat elapses (feed stale ⇒ pool halts) a scheduled re-sync may jump the mark.
    function test_maxDeviation_resyncAfterHeartbeat_succeeds() public {
        bytes32 id = _addBandedFeed(DEV_BAND);
        skip(uint256(DEV_TTL) + 1); // dt > ttl → re-sync exempt from the clamp
        ext.pushFeed(id, M.encodeB64(300e18, 18), 1e4, 5); // +200% jump allowed on re-sync
        assertApproxEqRel(Oracle.mark(ext.getFeed(id)), 300e18, 0.001e18, "re-sync jump committed");
    }

    /// maxDeviation==0 keeps the compromise-resistant clamp OFF (owner's fast/light opt-out).
    function test_maxDeviation_zero_disablesClamp() public {
        bytes32 id = _addBandedFeed(0);
        skip(10);
        ext.pushFeed(id, M.encodeB64(500e18, 18), 1e4, 5); // +400% instant, no clamp
        assertApproxEqRel(Oracle.mark(ext.getFeed(id)), 500e18, 0.001e18, "unclamped push committed");
    }

    /// updateFeed now persists maxDeviation (previously dropped — only emitted).
    function test_updateFeed_persistsMaxDeviation_thenEnforced() public {
        ext.updateFeed(feedId, 300, DEV_TTL); // 3% band on the 3000 seed feed
        assertEq(ext.maxDeviations(feedId), 300, "updateFeed persisted maxDeviation");
        skip(10);
        vm.expectRevert(); // +10% (3300 vs 3000) > 3%
        ext.pushFeed(feedId, M.encodeB64(3300e18, 18), 1e4, 5);
    }
}
