// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {BaseTestSetup} from "../fixtures/BaseTestSetup.sol";
import {LibOracle} from "../../src/libraries/LibOracle.sol";
import {LibMaths as M} from "../../src/libraries/LibMaths.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {Err} from "../../src/Errors.sol";

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

        (uint256 priceFast, uint256 priceSlow) = LibOracle.decodeB64s(feed);

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

        (uint256 priceFast, uint256 priceSlow) = LibOracle.decodeB64s(feed);

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

        (uint256 priceFast, uint256 priceSlow) = LibOracle.decodeB64s(feed);

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
            -int32(uint32(LibOracle.ORACLE_PBPS)),  // -100% for slow
            VOL_1_PCT,
            VOL_1_PCT
        );

        (uint256 priceFast, uint256 priceSlow) = LibOracle.decodeB64s(feed);

        // Should clamp to minimum (1 wei in 1e18)
        assertEq(priceFast, 1);
        assertEq(priceSlow, 1);
    }

    function test_getFastEMA_returns_only_fast() public view {
        uint64 current = M.encodeB64(100e18, 18);
        IOracle.FeedData memory feed = makeFeedData(
            current,
            OFFSET_100_BPS,  // +1% fast offset
            OFFSET_500_BPS,  // +5% slow offset (should be ignored)
            VOL_1_PCT,
            VOL_1_PCT
        );

        uint256 priceFast = LibOracle.getFastEMA(feed);

        // Fast should be ~101e18
        assertApproxEqRel(priceFast, 101e18, 0.01e18);
    }

    function test_getSlowPrice_returns_only_slow() public view {
        uint64 current = M.encodeB64(100e18, 18);
        IOracle.FeedData memory feed = makeFeedData(
            current,
            OFFSET_100_BPS,  // +1% fast offset (should be ignored)
            OFFSET_500_BPS,  // +5% slow offset
            VOL_1_PCT,
            VOL_1_PCT
        );

        uint256 priceSlow = LibOracle.getSlowPrice(feed);

        // Slow should be ~105e18
        assertApproxEqRel(priceSlow, 105e18, 0.01e18);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OFFSET ENCODING TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_encodeOffset_zero_current_returns_zero() public pure {
        uint64 ema = M.encodeB64(100e18, 18);

        int32 result = LibOracle.encodeOffset(0, ema);

        assertEq(result, 0);
    }

    // Skip testing zero ema as it reverts in LibMaths.decodeB64
    // This is expected behavior - B64 format cannot represent zero

    function test_encodeOffset_ema_equals_current() public pure {
        uint64 price = M.encodeB64(100e18, 18);

        int32 result = LibOracle.encodeOffset(price, price);

        // When EMA = current, offset should be 0
        assertEq(result, 0);
    }

    function test_encodeOffset_ema_higher_than_current() public pure {
        uint64 current = M.encodeB64(100e18, 18);
        uint64 ema = M.encodeB64(105e18, 18);  // 5% higher

        int32 result = LibOracle.encodeOffset(current, ema);

        // Should be +5% = 500,000 in offset units (0.0001% precision)
        assertEq(result, 500_000);
    }

    function test_encodeOffset_ema_lower_than_current() public pure {
        uint64 current = M.encodeB64(100e18, 18);
        uint64 ema = M.encodeB64(95e18, 18);  // 5% lower

        int32 result = LibOracle.encodeOffset(current, ema);

        // Should be -5% = -500,000 in offset units
        assertEq(result, -500_000);
    }

    function test_encodeOffset1e18_direct() public pure {
        uint256 current = 100e18;
        uint256 ema = 110e18;  // 10% higher

        int32 result = LibOracle.encodeOffset1e18(current, ema);

        // Should be +10% = 1,000,000 in offset units
        assertEq(result, 1_000_000);
    }

    function test_encodeOffset1e18_negative() public pure {
        uint256 current = 100e18;
        uint256 ema = 90e18;  // 10% lower

        int32 result = LibOracle.encodeOffset1e18(current, ema);

        // Should be -10% = -1,000,000 in offset units
        assertEq(result, -1_000_000);
    }

    function test_encodeOffset_large_ratio_clamps() public pure {
        uint64 current = M.encodeB64(1e18, 18);
        uint64 ema = M.encodeB64(1000000e18, 18);  // 1,000,000x larger

        int32 result = LibOracle.encodeOffset(current, ema);

        // Should clamp to int32 max
        assertEq(result, type(int32).max);
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

            // Decode to get EMA in 1e18
            uint256 emaPrice = LibOracle.getFastEMA(feed);

            // Re-encode the offset using 1e18 values
            int32 recoveredOffset = LibOracle.encodeOffset1e18(100e18, emaPrice);

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

        uint32 sigma = LibOracle.getSigma(feed);

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

        uint32 sigma = LibOracle.getSigma(feed);

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

        uint32 sigma = LibOracle.getSigma(feed);

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

        uint32 sigma = LibOracle.getSigma(feed);

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

        uint32 sigma = LibOracle.getSigma(feed);

        // Blended = (80% + 20%) / 2 = 50%
        assertEq(sigma, 500_000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DELTA (DEVIATION) COMPUTATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getDelta_zero_offsets() public view {
        IOracle.FeedData memory feed = makeFeedData(
            M.encodeB64(100e18, 18),
            0,      // fast = current
            0,      // slow = current
            VOL_1_PCT,
            VOL_1_PCT
        );

        uint32 delta = LibOracle.getDelta(feed);

        // No divergence
        assertEq(delta, 0);
    }

    function test_getDelta_fast_above_slow() public view {
        IOracle.FeedData memory feed = makeFeedData(
            M.encodeB64(100e18, 18),
            OFFSET_500_BPS,     // fast +5%
            OFFSET_100_BPS,     // slow +1%
            VOL_1_PCT,
            VOL_1_PCT
        );

        uint32 delta = LibOracle.getDelta(feed);

        // dfs = |500000 - 100000| = 400000
        // dfc = |500000| = 500000
        // Δ = max(400000, 500000) = 500000
        assertEq(delta, 500000);
    }

    function test_getDelta_fast_below_slow() public view {
        IOracle.FeedData memory feed = makeFeedData(
            M.encodeB64(100e18, 18),
            OFFSET_100_BPS,         // fast +1%
            OFFSET_500_BPS,         // slow +5%
            VOL_1_PCT,
            VOL_1_PCT
        );

        uint32 delta = LibOracle.getDelta(feed);

        // dfs = |100000 - 500000| = 400000
        // dfc = |100000| = 100000
        // Δ = max(400000, 100000) = 400000
        assertEq(delta, 400000);
    }

    function test_getDelta_fast_negative() public view {
        IOracle.FeedData memory feed = makeFeedData(
            M.encodeB64(100e18, 18),
            OFFSET_NEGATIVE_1_PCT,  // fast -1%
            OFFSET_100_BPS,         // slow +1%
            VOL_1_PCT,
            VOL_1_PCT
        );

        uint32 delta = LibOracle.getDelta(feed);

        // dfs = |-100000 - 100000| = 200000
        // dfc = |-100000| = 100000
        // Δ = max(200000, 100000) = 200000
        assertEq(delta, 200000);
    }

    function test_getDelta_conservative_aggregation() public view {
        // Test that delta takes MAX of two divergence metrics
        // Create feed where dfs is larger
        IOracle.FeedData memory feed = makeFeedData(
            M.encodeB64(100e18, 18),
            OFFSET_100_BPS,         // fast +1%
            OFFSET_NEGATIVE_1_PCT,  // slow -1%
            VOL_1_PCT,
            VOL_1_PCT
        );

        uint32 delta = LibOracle.getDelta(feed);

        // dfs = |100000 - (-100000)| = 200000
        // dfc = |100000| = 100000
        // Δ = max(200000, 100000) = 200000
        assertEq(delta, 200000);
    }

    function test_getDelta_uint32_max_clamping() public view {
        IOracle.FeedData memory feed = makeFeedData(
            M.encodeB64(100e18, 18),
            1_000_000,          // Large fast offset
            -1_000_000,         // Large negative slow offset
            VOL_1_PCT,
            VOL_1_PCT
        );

        uint32 delta = LibOracle.getDelta(feed);

        // Should handle large offsets gracefully
        assertLe(delta, type(uint32).max);
        assertGt(delta, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTEGRATION: SIGMA + DELTA TOGETHER
    // ═══════════════════════════════════════════════════════════════════════════

    function test_sigma_and_delta_independent() public view {
        // Create a feed with specific σ and Δ values
        IOracle.FeedData memory feed = makeFeedData(
            M.encodeB64(100e18, 18),
            OFFSET_500_BPS,         // +5% offset
            OFFSET_100_BPS,         // +1% offset
            VOL_50_PCT,             // 50% fast
            VOL_10_PCT              // 10% slow
        );

        uint32 sigma = LibOracle.getSigma(feed);
        uint32 delta = LibOracle.getDelta(feed);

        // Sigma = (50% + 10%) / 2 = 30%
        assertEq(sigma, 300_000);

        // Delta = max(|500000-100000|, |500000|) = 500000
        assertEq(delta, 500000);

        // They should be independent
        assertNotEq(sigma, delta);
    }

    function test_realistic_oracle_feed() public view {
        // Simulate a realistic feed: price drifted up 3%, fast vol spike to 15%, slow baseline 8%
        IOracle.FeedData memory feed = makeFeedData(
            M.encodeB64(100e18, 18),    // Current price
            30_000,                      // fast offset = +0.3%
            20_000,                      // slow offset = +0.2%
            150_000,                     // fast vol = 15%
            80_000                       // slow vol = 8%
        );

        uint32 sigma = LibOracle.getSigma(feed);
        uint32 delta = LibOracle.getDelta(feed);

        // Verify reasonable values
        assertEq(sigma, 115_000);       // (15% + 8%) / 2
        assertEq(delta, 30_000);        // max(|30000-20000|, |30000|)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BASE TOKEN FEED SYNTHESIS TEST
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getBaseFeed_returns_stable_feed() public {
        IOracle.FeedData memory feed = LibOracle.getBaseFeed();

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
        (uint256 priceFast, uint256 priceSlow) = LibOracle.decodeB64s(feed);
        assertEq(priceFast, 1e18);
        assertEq(priceSlow, 1e18);
    }
}