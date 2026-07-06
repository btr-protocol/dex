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

/// @title ExternalOracleTest
/// @notice Verifies the external-mark model: fresh mark = quote source, on-chain rate-clamped
///         time-decayed EMA = servable reference, and per-push confidence (1σ CI) storage.
contract ExternalOracleTest is Test {
    ExternalOracle ext;
    MockAC ac;
    address constant BASE  = address(0xB05E);
    address constant QUOTE = address(0x9907E);
    bytes32 feedId;

    uint32 constant TAU = 100;

    function setUp() public {
        ac = new MockAC(address(this));                       // owner = this
        ext = new ExternalOracle(address(ac), address(this)); // this = granted oracle
        vm.warp(1_700_000_000);
        // addFeed(base, quote, price, sigma, confidence, tau, maxDeviation, ttl)
        ext.addFeed(BASE, QUOTE, M.encodeB64(3000e18, 18), 1e4, 5, TAU, 0, 3600);
        feedId = keccak256(abi.encodePacked(BASE, QUOTE));
    }

    function test_addFeed_seedsLastEqualsEma() public view {
        IOracle.FeedData memory f = ext.getFeed(feedId);
        assertEq(f.lastPriceB64, f.emaPriceB64, "seed: lastPrice == ema");
        assertApproxEqRel(Oracle.mark(f), 3000e18, 0.0005e18, "seed mark = 3000");
        assertEq(f.tau, TAU, "tau stored");
        assertEq(f.confidence, 5, "confidence stored (not hardcoded 100)");
    }

    function test_pushFeed_commitsFreshMark_decaysEma() public {
        // Full decay step (Δt == τ ⇒ α=1). Mark 3030 within band ⇒ ema tracks it.
        vm.warp(block.timestamp + TAU);
        ext.pushFeed(feedId, M.encodeB64(3030e18, 18), 1e4, 5);
        IOracle.FeedData memory f = ext.getFeed(feedId);
        assertApproxEqRel(M.b64To1e18(f.lastPriceB64), 3030e18, 0.001e18, "lastPrice = fresh mark");
        assertApproxEqRel(M.b64To1e18(f.emaPriceB64), 3030e18, 0.01e18, "ema decayed toward mark");
        assertEq(f.updatedAt, uint32(block.timestamp), "updatedAt stamped");
        // Locks the manual slot codec in _pushInternal: config fields must survive a push in place.
        assertEq(f.ttl, 3600, "ttl preserved across push");
        assertEq(f.tau, TAU, "tau preserved across push");
    }

    /// A single manipulated push (5x) cannot move the EMA past ema+band (rate clamp), but the fresh
    /// mark still commits (quote source). band = ema·K·CI = 3000·8·(5bps)/BPS = 12.
    function test_pushFeed_emaClampBoundsManipulation() public {
        vm.warp(block.timestamp + TAU);
        uint256 emaBefore = 3000e18;
        ext.pushFeed(feedId, M.encodeB64(15000e18, 18), 1e4, 5);
        IOracle.FeedData memory f = ext.getFeed(feedId);
        uint256 band = (emaBefore * C.K_BAND * 5) / SC.BPS; // 12e18
        assertApproxEqRel(M.b64To1e18(f.emaPriceB64), emaBefore + band, 0.01e18, "ema displaced <= band");
        assertApproxEqRel(M.b64To1e18(f.lastPriceB64), 15000e18, 0.001e18, "mark still commits raw");
    }

    /// Same-block push: Δt==0 ⇒ ema frozen; the fresh mark still overwrites lastPrice.
    function test_pushFeed_sameBlockFreezesEma() public {
        uint64 emaSeed = ext.getFeed(feedId).emaPriceB64;
        ext.pushFeed(feedId, M.encodeB64(3100e18, 18), 1e4, 5); // same block as addFeed
        IOracle.FeedData memory f = ext.getFeed(feedId);
        assertEq(f.emaPriceB64, emaSeed, "same-block ema frozen");
        assertApproxEqRel(M.b64To1e18(f.lastPriceB64), 3100e18, 0.001e18, "mark updated same block");
    }

    function test_batchPush_updatesFeeds() public {
        vm.warp(block.timestamp + TAU);
        bytes32[] memory ids = new bytes32[](1);
        uint64[] memory prices = new uint64[](1);
        uint32[] memory sigmas = new uint32[](1);
        uint16[] memory confs = new uint16[](1);
        ids[0] = feedId; prices[0] = M.encodeB64(3050e18, 18); sigmas[0] = 2e4; confs[0] = 7;
        ext.batchPush(ids, prices, sigmas, confs);
        IOracle.FeedData memory f = ext.getFeed(feedId);
        assertApproxEqRel(M.b64To1e18(f.lastPriceB64), 3050e18, 0.001e18, "batch mark");
        assertEq(f.sigma, 2e4, "batch sigma");
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
}
