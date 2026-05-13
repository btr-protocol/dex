// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {BaseTestSetup} from "../fixtures/BaseTestSetup.sol";
import {Oracle} from "../../src/libraries/Oracle.sol";
import {Maths as M} from "../../src/libraries/Maths.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @title LibOracleTest
/// @notice Comprehensive unit tests for LibOracle offset encoding/decoding and risk signals
contract LibOracleTest is BaseTestSetup {

    // ═══════════════════════════════════════════════════════════════════════════
    // EMA DECODING TESTS (Updated to use decodeB64s returning 1e18)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_decodeB64s_zero_offset() public view {
        uint64 current = M.encodeB64(100e18, 18);
        IOracle.FeedData memory feed = makeFeedData(
            current,
            0,  // zero fast offset
            0,  // zero slow offset
            VOL_1_PCT,
            VOL_1_PCT
        );

        (uint256 priceFast, uint256 priceSlow) = Oracle.decodeB64s(feed);

        // With zero offset, should equal current price
        assertEq(priceFast, 100e18);
        assertEq(priceSlow, 100e18);
    }

    function test_decodeB64s_positive_offset() public view {
        uint64 current = M.encodeB64(100e18, 18);
        IOracle.FeedData memory feed = makeFeedData(
            current,
            OFFSET_100_BPS,  // +1% fast offset
            OFFSET_500_BPS,  // +5% slow offset
            VOL_1_PCT,
            VOL_1_PCT
        );

        (uint256 priceFast, uint256 priceSlow) = Oracle.decodeB64s(feed);

        // Prices should be higher than current (100e18)
        assertGt(priceFast, 100e18);
        assertGt(priceSlow, 100e18);

        // Fast should be ~101e18, slow should be ~105e18
        assertApproxEqRel(priceFast, 101e18, 0.01e18);
        assertApproxEqRel(priceSlow, 105e18, 0.01e18);
    }

    function test_decodeB64s_negative_offset() public view {
        uint64 current = M.encodeB64(100e18, 18);
        IOracle.FeedData memory feed = makeFeedData(
            current,
            -OFFSET_100_BPS,  // -1% fast offset
            -OFFSET_500_BPS,  // -5% slow offset
            VOL_1_PCT,
            VOL_1_PCT
        );

        (uint256 priceFast, uint256 priceSlow) = Oracle.decodeB64s(feed);

        // Prices should be lower than current
        assertLt(priceFast, 100e18);
        assertLt(priceSlow, 100e18);

        // Fast should be ~99e18, slow should be ~95e18
        assertApproxEqRel(priceFast, 99e18, 0.01e18);
        assertApproxEqRel(priceSlow, 95e18, 0.01e18);
    }

    function test_decodeB64s_extreme_negative_offset_clamps() public view {
        uint64 current = M.encodeB64(100e18, 18);
        IOracle.FeedData memory feed = makeFeedData(
            current,
            type(int32).min,  // Most negative offset for fast
            -int32(uint32(Oracle.ORACLE_PBPS)),  // -100% for slow
            VOL_1_PCT,
            VOL_1_PCT
        );

        (uint256 priceFast, uint256 priceSlow) = Oracle.decodeB64s(feed);

        // Should clamp to minimum (1 wei in 1e18)
        assertEq(priceFast, 1);
        assertEq(priceSlow, 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OFFSET ENCODING TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_encodeOffset1e18_direct() public pure {
        uint256 current = 100e18;
        uint256 ema = 110e18;  // 10% higher

        int32 result = Oracle.encodeOffset1e18(current, ema);

        // Should be +10% = 1,000,000 in offset units
        assertEq(result, 1_000_000);
    }

    function test_encodeOffset1e18_negative() public pure {
        uint256 current = 100e18;
        uint256 ema = 90e18;  // 10% lower

        int32 result = Oracle.encodeOffset1e18(current, ema);

        // Should be -10% = -1,000,000 in offset units
        assertEq(result, -1_000_000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ROUNDTRIP ENCODING/DECODING TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_roundtrip_offset_encoding() public view {
        uint64 currentB64 = M.encodeB64(100e18, 18);

        // Test various offsets
        int32[5] memory offsets = [
            int32(0),
            OFFSET_100_BPS,      // +1%
            -OFFSET_100_BPS,     // -1%
            OFFSET_500_BPS,      // +5%
            -OFFSET_500_BPS      // -5%
        ];

        for (uint i = 0; i < offsets.length; i++) {
            IOracle.FeedData memory feed = makeFeedData(
                currentB64,
                offsets[i],
                0,
                VOL_1_PCT,
                VOL_1_PCT
            );

            // Decode to get fast EMA via decodeB64s
            (uint256 emaPrice,) = Oracle.decodeB64s(feed);

            // Re-encode the offset using 1e18 values
            int32 recoveredOffset = Oracle.encodeOffset1e18(100e18, emaPrice);

            // Should approximately match (small precision loss acceptable)
            assertApproxEqAbs(recoveredOffset, offsets[i], 100);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SIGMA (VOLATILITY) COMPUTATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getSigma_equal_vols() public view {
        IOracle.FeedData memory feed = makeFeedData(
            M.encodeB64(100e18, 18),
            0,
            0,
            VOL_1_PCT,      // 1% fast
            VOL_1_PCT       // 1% slow
        );

        uint32 sigma = Oracle.getSigma(feed);

        // Sigma should be average of fast and slow
        assertEq(sigma, VOL_1_PCT);
    }

    function test_getSigma_different_vols() public view {
        IOracle.FeedData memory feed = makeFeedData(
            M.encodeB64(100e18, 18),
            0,
            0,
            VOL_50_PCT,     // 50% fast
            VOL_10_PCT      // 10% slow
        );

        uint32 sigma = Oracle.getSigma(feed);

        // Sigma = (50% + 10%) / 2 = 30%
        assertEq(sigma, 300_000);
    }

    function test_getSigma_zero_volatility() public view {
        IOracle.FeedData memory feed = makeFeedData(
            M.encodeB64(100e18, 18),
            0,
            0,
            0,
            0
        );

        uint32 sigma = Oracle.getSigma(feed);

        assertEq(sigma, 0);
    }

    function test_getSigma_max_volatility() public view {
        IOracle.FeedData memory feed = makeFeedData(
            M.encodeB64(100e18, 18),
            0,
            0,
            VOL_MAX,
            VOL_MAX
        );

        uint32 sigma = Oracle.getSigma(feed);

        assertEq(sigma, VOL_MAX);
    }

    function test_getSigma_blends_timeframes() public view {
        // Fast spike: 80%, Slow baseline: 20%
        IOracle.FeedData memory feed = makeFeedData(
            M.encodeB64(100e18, 18),
            0,
            0,
            800_000,        // 80%
            200_000         // 20%
        );

        uint32 sigma = Oracle.getSigma(feed);

        // Blended = (80% + 20%) / 2 = 50%
        assertEq(sigma, 500_000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DELTA (DEVIATION) COMPUTATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    // ═══════════════════════════════════════════════════════════════════════════
    // BASE TOKEN FEED SYNTHESIS TEST
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getBaseFeed_returns_stable_feed() public {
        IOracle.FeedData memory feed = Oracle.getBaseFeed();

        // Check all fields
        assertEq(M.b64To1e18(feed.lastPriceB64), 1e18);  // Price should be 1.0
        assertEq(feed.fastOffset, 0);
        assertEq(feed.slowOffset, 0);
        assertEq(feed.fastVolEMA, 10_000);  // 0.01% baseline
        assertEq(feed.slowVolEMA, 10_000);
        assertEq(feed.updatedAt, uint32(block.timestamp));
        assertEq(feed.ttl, type(uint16).max);  // Never expires
        assertEq(feed.confidence, 100);

        // Test that decoding works correctly
        (uint256 priceFast, uint256 priceSlow) = Oracle.decodeB64s(feed);
        assertEq(priceFast, 1e18);
        assertEq(priceSlow, 1e18);
    }
}