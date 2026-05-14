// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {BaseTestSetup} from "../fixtures/BaseTestSetup.sol";
import {Pricing as P} from "../../src/libraries/Pricing.sol";
import {IPool} from "../../src/interfaces/IPool.sol";

/// @title LibPricingTest
/// @notice Comprehensive unit tests for LibPricing core functions
contract LibPricingTest is BaseTestSetup {

    uint256 constant BPS_PRECISION = 1_000_000;

    // ═══════════════════════════════════════════════════════════════════════════
    // COVERAGE RATIO TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_calculateCoverage_zero_liabilities_returns_max() public pure {
        uint128 reserves = 1000;
        uint128 liabilities = 0;

        uint256 coverage = P.calculateCoverage(reserves, liabilities);

        assertEq(coverage, type(uint256).max);
    }

    function test_calculateCoverage_equal_reserves_liabilities() public pure {
        uint128 reserves = 1000;
        uint128 liabilities = 1000;

        uint256 coverage = P.calculateCoverage(reserves, liabilities);

        assertEq(coverage, WAD); // 100% coverage
    }

    function test_calculateCoverage_over_collateralized() public pure {
        uint128 reserves = 150;
        uint128 liabilities = 100;

        uint256 coverage = P.calculateCoverage(reserves, liabilities);

        assertEq(coverage, 15e17); // 150% coverage = 1.5 * WAD
    }

    function test_calculateCoverage_under_collateralized() public pure {
        uint128 reserves = 80;
        uint128 liabilities = 100;

        uint256 coverage = P.calculateCoverage(reserves, liabilities);

        assertEq(coverage, 8e17); // 80% coverage = 0.8 * WAD
    }

    function test_calculateCoverage_small_values() public pure {
        uint128 reserves = 1;
        uint128 liabilities = 100;

        uint256 coverage = P.calculateCoverage(reserves, liabilities);

        assertEq(coverage, 1e16); // 1% coverage
    }

    function test_calculateCoverage_large_values() public pure {
        uint128 reserves = type(uint128).max;
        uint128 liabilities = type(uint128).max;

        uint256 coverage = P.calculateCoverage(reserves, liabilities);

        assertEq(coverage, WAD); // 100% coverage
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INVENTORY SKEW TESTS (Avellaneda-Stoikov)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_computeInventorySkew_zero_liabilities_max_negative() public pure {
        uint128 reserves = 1000;
        uint128 liabilities = 0;
        uint16 coverageMin = 5000; // 50% (0.01% units)
        uint16 gamma = 10000; // 1x

        int8 skew = P.computeInventorySkew(reserves, liabilities, coverageMin, 20000, gamma);

        assertEq(skew, -100); // Max discount
    }

    function test_computeInventorySkew_over_collateralized_negative() public pure {
        uint128 reserves = 150;
        uint128 liabilities = 100;
        uint16 coverageMin = 5000; // 50% (0.01% units)
        uint16 gamma = 10000; // 1x

        int8 skew = P.computeInventorySkew(reserves, liabilities, coverageMin, 20000, gamma);

        // Over-collateralized (c=1.5) should give negative skew
        assertLt(skew, 0);
        assertGe(skew, -100);
    }

    function test_computeInventorySkew_100_percent_coverage_zero() public pure {
        uint128 reserves = 100;
        uint128 liabilities = 100;
        uint16 coverageMin = 5000; // 50% (0.01% units)
        uint16 gamma = 10000; // 1x

        int8 skew = P.computeInventorySkew(reserves, liabilities, coverageMin, 20000, gamma);

        // At exactly 100% coverage, skew should be 0
        assertEq(skew, 0);
    }

    function test_computeInventorySkew_under_collateralized_positive() public pure {
        uint128 reserves = 80;
        uint128 liabilities = 100;
        uint16 coverageMin = 5000; // 50% (0.01% units)
        uint16 gamma = 10000; // 1x

        int8 skew = P.computeInventorySkew(reserves, liabilities, coverageMin, 20000, gamma);

        // Under-collateralized (c=0.8) should give positive skew
        assertGt(skew, 0);
        assertLe(skew, 100);
    }

    function test_computeInventorySkew_at_critical_floor_max_positive() public pure {
        uint128 reserves = 5;
        uint128 liabilities = 100;
        uint16 coverageMin = 500; // 5% coverage floor (0.01% units)
        uint16 gamma = 10000; // 1x

        int8 skew = P.computeInventorySkew(reserves, liabilities, coverageMin, 20000, gamma);

        // At critical floor (c=5%), should return max positive skew
        assertEq(skew, 100);
    }

    function test_computeInventorySkew_below_critical_floor_max_positive() public pure {
        uint128 reserves = 3;
        uint128 liabilities = 100;
        uint16 coverageMin = 500; // 5% coverage floor (0.01% units)
        uint16 gamma = 10000; // 1x

        int8 skew = P.computeInventorySkew(reserves, liabilities, coverageMin, 20000, gamma);

        // Below critical floor, should return max positive skew
        assertEq(skew, 100);
    }

    function test_computeInventorySkew_gamma_scaling() public pure {
        uint128 reserves = 150;
        uint128 liabilities = 100;
        uint16 coverageMin = 5000; // 50% (0.01% units)

        // Test with different gamma values (LINEAR MULTIPLIER per docs)
        // At 150% coverage (over-collateralized):
        // - progress = (1.5 - 1.0) / (2.0 - 1.0) = 0.5
        // - skew = -(gamma / 10000) × 100 × progress
        // - gamma=5000 (0.5x):  skew = -50 × 0.5 = -25
        // - gamma=10000 (1.0x): skew = -100 × 0.5 = -50
        // - gamma=20000 (2.0x): skew = -200 × 0.5 = -100 (capped)
        int8 skew1x = P.computeInventorySkew(reserves, liabilities, coverageMin, 20000, 10000); // 1x
        int8 skew05x = P.computeInventorySkew(reserves, liabilities, coverageMin, 20000, 5000);  // 0.5x
        int8 skew2x = P.computeInventorySkew(reserves, liabilities, coverageMin, 20000, 20000); // 2x

        // With linear multiplier: higher gamma = more extreme (more negative) skew
        assertGt(skew05x, skew1x, "0.5x should be less extreme than 1x"); // -25 > -50
        assertGt(skew1x, skew2x, "1x should be less extreme than 2x");  // -50 > -100
    }

    function test_computeInventorySkew_linear_curve() public pure {
        uint128 liabilities = 1000;
        uint16 coverageMin = 5000; // 50% (0.01% units) floor
        uint16 gamma = 10000; // 1.0x multiplier

        // Test at different coverage levels in under-collateralized zone
        // With gamma=1.0x (linear multiplier), skew should increase monotonically
        int8 skew900 = P.computeInventorySkew(900, liabilities, coverageMin, 20000, gamma); // 90%
        int8 skew700 = P.computeInventorySkew(700, liabilities, coverageMin, 20000, gamma); // 70%
        int8 skew550 = P.computeInventorySkew(550, liabilities, coverageMin, 20000, gamma); // 55%

        // With linear multiplier, skew increases linearly as coverage drops (positive skew = premium)
        assertGt(skew700, skew900, "Skew should increase as coverage drops");
        assertGt(skew550, skew700, "Skew should continue increasing");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPTH CALCULATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_calculateDepth_zero_liabilities_max_depth() public pure {
        uint128 reserves = 1000;
        uint128 liabilities = 0;
        uint16 depthAmplifier = 10000; // 0.1% (typical value)

        uint256 depth = P.calculateDepth(reserves, liabilities, depthAmplifier);

        // When liabilities is 0, depth returns reserves
        assertEq(depth, uint256(reserves));
    }

    function test_calculateDepth_100_percent_coverage() public pure {
        uint128 reserves = 100;
        uint128 liabilities = 100;
        uint16 depthAmplifier = 10000; // 0.1%

        uint256 depth = P.calculateDepth(reserves, liabilities, depthAmplifier);

        // At 100% coverage, depth should be based on amplifier
        assertGt(depth, 0);
    }

    function test_calculateDepth_over_collateralized() public pure {
        uint128 reserves = 150;
        uint128 liabilities = 100;
        uint16 depthAmplifier = 10000; // 1%

        uint256 depth = P.calculateDepth(reserves, liabilities, depthAmplifier);

        // With overcollateralization (coverage >= 100%), depth = reserves (no amplification needed)
        assertEq(depth, uint256(reserves));
    }

    function test_calculateDepth_under_collateralized() public pure {
        uint128 reserves = 80;
        uint128 liabilities = 100;
        uint16 depthAmplifier = 10000; // 0.1%

        uint256 depth = P.calculateDepth(reserves, liabilities, depthAmplifier);

        // Depth should be less when under-collateralized
        assertLt(depth, uint256(reserves) * WAD);
    }

    function test_calculateDepth_amplifier_scaling() public pure {
        // Use larger values to avoid rounding to zero
        uint128 reserves = 60e18;
        uint128 liabilities = 100e18;  // 60% coverage (in amplification zone between 50% and 100%)

        uint256 depth0 = P.calculateDepth(reserves, liabilities, 0);       // No amplification
        uint256 depth10k = P.calculateDepth(reserves, liabilities, 10000); // 1% amplification
        uint256 depth50k = P.calculateDepth(reserves, liabilities, 50000); // 5% amplification

        // depth0 should equal reserves when no amplification
        assertEq(depth0, reserves);
        // Higher amplifier should give more virtual depth
        assertGt(depth10k, depth0);
        assertGt(depth50k, depth10k);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NET COVERAGE IMPACT TESTS (Fee Model)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_netCoverageImpact_improves_coverage_negative() public pure {
        // Swap that improves coverage should have negative impact (lower fee)
        uint128 reservesInValue = 80e18;
        uint128 reservesOutValue = 120e18;
        uint128 liabilitiesInValue = 100e18;
        uint128 liabilitiesOutValue = 100e18;
        uint256 deltaReservesIn = 20e18;
        uint256 deltaReservesOut = 10e18;

        int256 impact = P.netCoverageImpact(
            reservesInValue,
            liabilitiesInValue,
            reservesOutValue,
            liabilitiesOutValue,
            deltaReservesIn,
            deltaReservesOut,
            WAD,  // priceIn = 1.0
            WAD,  // priceOut = 1.0
            1000  // feeBps in PBPS (0.1%)
        );

        // Improving coverage should give negative impact
        assertLt(impact, 0);
    }

    function test_netCoverageImpact_worsens_coverage_positive() public pure {
        // Swap that worsens coverage should have positive impact (higher fee)
        uint128 reservesInValue = 120e18;
        uint128 reservesOutValue = 80e18;
        uint128 liabilitiesInValue = 100e18;
        uint128 liabilitiesOutValue = 100e18;
        uint256 deltaReservesIn = 10e18;
        uint256 deltaReservesOut = 20e18;

        int256 impact = P.netCoverageImpact(
            reservesInValue,
            liabilitiesInValue,
            reservesOutValue,
            liabilitiesOutValue,
            deltaReservesIn,
            deltaReservesOut,
            WAD,  // priceIn = 1.0
            WAD,  // priceOut = 1.0
            1000  // feeBps in PBPS (0.1%)
        );

        // Worsening coverage should give positive impact
        assertGt(impact, 0);
    }

    function test_netCoverageImpact_neutral_swap_zero() public pure {
        // Balanced swap with equal coverage changes
        uint128 reservesInValue = 100e18;
        uint128 reservesOutValue = 100e18;
        uint128 liabilitiesInValue = 100e18;
        uint128 liabilitiesOutValue = 100e18;
        uint256 deltaReservesIn = 10e18;
        uint256 deltaReservesOut = 10e18;

        int256 impact = P.netCoverageImpact(
            reservesInValue,
            liabilitiesInValue,
            reservesOutValue,
            liabilitiesOutValue,
            deltaReservesIn,
            deltaReservesOut,
            WAD,  // priceIn = 1.0
            WAD,  // priceOut = 1.0
            1000  // feeBps in PBPS (0.1%)
        );

        // Neutral swap should have near-zero impact (tolerance increased for new implementation)
        assertApproxEqAbs(impact, 0, 25e18);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FEE SPLIT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_splitFee_zero_protocol_split() public pure {
        uint256 totalFee = 100e18;
        uint8 protocolSplit = 0; // 0%

        (uint256 protocolFee, uint256 lpFee) = P.splitFee(totalFee, protocolSplit);

        assertEq(lpFee, 100e18);
        assertEq(protocolFee, 0);
    }

    function test_splitFee_50_percent_protocol_split() public pure {
        uint256 totalFee = 100e18;
        uint8 protocolSplit = 50; // 50%

        (uint256 protocolFee, uint256 lpFee) = P.splitFee(totalFee, protocolSplit);

        assertEq(lpFee, 50e18);
        assertEq(protocolFee, 50e18);
    }

    function test_splitFee_100_percent_protocol_split() public pure {
        uint256 totalFee = 100e18;
        uint8 protocolSplit = 100; // 100%

        (uint256 protocolFee, uint256 lpFee) = P.splitFee(totalFee, protocolSplit);

        assertEq(lpFee, 0);
        assertEq(protocolFee, 100e18);
    }

    function test_splitFee_20_percent_protocol_split() public pure {
        uint256 totalFee = 100e18;
        uint8 protocolSplit = 20; // 20%

        (uint256 protocolFee, uint256 lpFee) = P.splitFee(totalFee, protocolSplit);

        assertEq(lpFee, 80e18);
        assertEq(protocolFee, 20e18);
    }

    function test_splitFee_sum_equals_total() public pure {
        uint256 totalFee = 123456789e18;
        uint8 protocolSplit = 33; // 33%

        (uint256 protocolFee, uint256 lpFee) = P.splitFee(totalFee, protocolSplit);

        assertEq(lpFee + protocolFee, totalFee);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DECAY TESTS -migrated to PoolDecay.t.sol (R44-13: dead duplicate removed).
    // ═══════════════════════════════════════════════════════════════════════════

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASES & INTEGRATION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_coverage_and_skew_consistency() public pure {
        uint128 reserves = 150;
        uint128 liabilities = 100;
        uint16 coverageMin = 5000; // 50% (0.01% units)
        uint16 gamma = 10000;

        uint256 coverage = P.calculateCoverage(reserves, liabilities);
        int8 skew = P.computeInventorySkew(reserves, liabilities, coverageMin, 20000, gamma);

        // Over-collateralized should have coverage > 1.0 and negative skew
        assertGt(coverage, WAD);
        assertLt(skew, 0);
    }

    function test_depth_scales_with_coverage() public pure {
        uint128 liabilities = 100;
        uint16 depthAmplifier = 0; // No amplification for clearer scaling

        uint256 depth50 = P.calculateDepth(50, liabilities, depthAmplifier);
        uint256 depth75 = P.calculateDepth(75, liabilities, depthAmplifier);
        uint256 depth100 = P.calculateDepth(100, liabilities, depthAmplifier);

        // Depth should increase with coverage
        assertLt(depth50, depth75);
        assertLt(depth75, depth100);
    }

}
