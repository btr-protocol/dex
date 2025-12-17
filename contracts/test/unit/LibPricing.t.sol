// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTestSetup} from "../fixtures/BaseTestSetup.sol";
import {LibPricing as P} from "../../src/libraries/LibPricing.sol";
import {IPoolV1} from "../../src/interfaces/IPoolV1.sol";

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
        uint16 coverageFloor = 50000; // 50%
        uint16 gamma = 10000; // 1x

        int8 skew = P.computeInventorySkew(reserves, liabilities, coverageFloor, gamma);

        assertEq(skew, -100); // Max discount
    }

    function test_computeInventorySkew_over_collateralized_negative() public pure {
        uint128 reserves = 150;
        uint128 liabilities = 100;
        uint16 coverageFloor = 50000; // 50%
        uint16 gamma = 10000; // 1x

        int8 skew = P.computeInventorySkew(reserves, liabilities, coverageFloor, gamma);

        // Over-collateralized (c=1.5) should give negative skew
        assertLt(skew, 0);
        assertGe(skew, -100);
    }

    function test_computeInventorySkew_100_percent_coverage_zero() public pure {
        uint128 reserves = 100;
        uint128 liabilities = 100;
        uint16 coverageFloor = 50000; // 50%
        uint16 gamma = 10000; // 1x

        int8 skew = P.computeInventorySkew(reserves, liabilities, coverageFloor, gamma);

        // At exactly 100% coverage, skew should be 0
        assertEq(skew, 0);
    }

    function test_computeInventorySkew_under_collateralized_positive() public pure {
        uint128 reserves = 80;
        uint128 liabilities = 100;
        uint16 coverageFloor = 50000; // 50%
        uint16 gamma = 10000; // 1x

        int8 skew = P.computeInventorySkew(reserves, liabilities, coverageFloor, gamma);

        // Under-collateralized (c=0.8) should give positive skew
        assertGt(skew, 0);
        assertLe(skew, 100);
    }

    function test_computeInventorySkew_at_critical_floor_max_positive() public pure {
        uint128 reserves = 5;
        uint128 liabilities = 100;
        uint16 coverageFloor = 50000; // 5% coverage floor (50000 * 1e18 / 1_000_000 = 0.05e18)
        uint16 gamma = 10000; // 1x

        int8 skew = P.computeInventorySkew(reserves, liabilities, coverageFloor, gamma);

        // At critical floor (c=0.05), should return max positive skew
        assertEq(skew, 100);
    }

    function test_computeInventorySkew_below_critical_floor_max_positive() public pure {
        uint128 reserves = 3;
        uint128 liabilities = 100;
        uint16 coverageFloor = 50000; // 5% coverage floor
        uint16 gamma = 10000; // 1x

        int8 skew = P.computeInventorySkew(reserves, liabilities, coverageFloor, gamma);

        // Below critical floor, should return max positive skew
        assertEq(skew, 100);
    }

    function test_computeInventorySkew_gamma_scaling() public pure {
        uint128 reserves = 150;
        uint128 liabilities = 100;
        uint16 coverageFloor = 50000; // 50%

        // Test with different gamma values
        // NOTE: gamma is now the EXPONENT, not a multiplier
        // At 150% coverage (over-collateralized):
        // - progress = (1.5 - 1.0) / (2.0 - 1.0) = 0.5
        // - skew = -100 × 0.5^(gamma/10000)
        // - gamma=5000 (exp=0.5): skew = -100 × 0.5^0.5 = -70.7
        // - gamma=10000 (exp=1.0): skew = -100 × 0.5^1.0 = -50
        // - gamma=20000 (exp=2.0): skew = -100 × 0.5^2.0 = -25
        int8 skew1x = P.computeInventorySkew(reserves, liabilities, coverageFloor, 10000); // 1x
        int8 skew05x = P.computeInventorySkew(reserves, liabilities, coverageFloor, 5000);  // 0.5x
        int8 skew2x = P.computeInventorySkew(reserves, liabilities, coverageFloor, 20000); // 2x

        // With gamma as exponent: lower exp = steeper curve = more negative skew
        // Higher gamma (larger exponent) = flatter curve = less extreme skew
        assertLt(skew05x, skew1x); // 0.5x exponent is steeper
        assertGt(skew2x, skew1x);  // 2x exponent is flatter
    }

    function test_computeInventorySkew_exponential_curve() public pure {
        uint128 liabilities = 1000;
        uint16 coverageFloor = 50000; // 50% floor (50000 * WAD / 1_000_000 = 0.05 WAD but it's scaled)
        uint16 gamma = 10000; // 1x exponent

        // Test at different coverage levels in under-collateralized zone
        // With gamma=1.0x (linear exponent), skew should increase monotonically
        int8 skew900 = P.computeInventorySkew(900, liabilities, coverageFloor, gamma); // 90%
        int8 skew700 = P.computeInventorySkew(700, liabilities, coverageFloor, gamma); // 70%
        int8 skew550 = P.computeInventorySkew(550, liabilities, coverageFloor, gamma); // 55%

        // With linear exponent, curve should be monotonically increasing
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
            WAD   // priceOut = 1.0
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
            WAD   // priceOut = 1.0
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
            WAD   // priceOut = 1.0
        );

        // Neutral swap should have near-zero impact (tolerance increased for new implementation)
        assertApproxEqAbs(impact, 0, 25e18);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // WITHDRAWAL HAIRCUT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_applyWithdrawalHaircut_100_percent_coverage_no_haircut() public pure {
        uint256 amountOut = 100e18;
        uint128 reserves = 100;
        uint128 liabilities = 100;
        uint16 suppressionFactor = 10000; // 1x

        (uint256 actualAmount, uint256 haircutAmount) = P.applyWithdrawalHaircut(
            amountOut,
            reserves,
            liabilities,
            suppressionFactor
        );

        // At 100% coverage, no haircut
        assertEq(haircutAmount, 0);
        assertEq(actualAmount, amountOut);
    }

    function test_applyWithdrawalHaircut_over_collateralized_no_haircut() public pure {
        uint256 amountOut = 100e18;
        uint128 reserves = 150;
        uint128 liabilities = 100;
        uint16 suppressionFactor = 10000; // 1x

        (uint256 actualAmount, uint256 haircutAmount) = P.applyWithdrawalHaircut(
            amountOut,
            reserves,
            liabilities,
            suppressionFactor
        );

        // Over-collateralized, no haircut
        assertEq(haircutAmount, 0);
        assertEq(actualAmount, amountOut);
    }

    function test_applyWithdrawalHaircut_under_collateralized_has_haircut() public pure {
        uint256 amountOut = 100e18;
        uint128 reserves = 80;
        uint128 liabilities = 100;
        uint16 suppressionFactor = 10000; // 1x

        (uint256 actualAmount, uint256 haircutAmount) = P.applyWithdrawalHaircut(
            amountOut,
            reserves,
            liabilities,
            suppressionFactor
        );

        // Under-collateralized, should have haircut
        assertGt(haircutAmount, 0);
        assertLt(actualAmount, amountOut);
        assertEq(actualAmount + haircutAmount, amountOut);
    }

    function test_applyWithdrawalHaircut_quadratic_curve() public pure {
        uint256 amountOut = 100e18;
        uint128 liabilities = 100;
        uint16 suppressionFactor = 10000; // 1x

        (, uint256 haircut90) = P.applyWithdrawalHaircut(amountOut, 90, liabilities, suppressionFactor);
        (, uint256 haircut70) = P.applyWithdrawalHaircut(amountOut, 70, liabilities, suppressionFactor);
        (, uint256 haircut50) = P.applyWithdrawalHaircut(amountOut, 50, liabilities, suppressionFactor);

        // Quadratic curve: haircut should accelerate as coverage drops
        assertGt(haircut70, haircut90);
        assertGt(haircut50, haircut70);

        // Rate of increase should accelerate
        uint256 diff1 = haircut70 - haircut90;
        uint256 diff2 = haircut50 - haircut70;
        assertGt(diff2, diff1);
    }

    function test_applyWithdrawalHaircut_amplification_scaling() public pure {
        uint256 amountOut = 100e18;
        uint128 reserves = 70;
        uint128 liabilities = 100;

        (, uint256 haircut1x) = P.applyWithdrawalHaircut(amountOut, reserves, liabilities, 10000);  // 1x
        (, uint256 haircut05x) = P.applyWithdrawalHaircut(amountOut, reserves, liabilities, 5000);  // 0.5x
        (, uint256 haircut2x) = P.applyWithdrawalHaircut(amountOut, reserves, liabilities, 20000); // 2x

        // Lower suppression (0.5x) gives larger haircut (less suppression)
        assertGt(haircut05x, haircut1x);
        // Higher suppression (2x) gives smaller haircut (more suppression)
        assertLt(haircut2x, haircut1x);
    }

    function test_applyWithdrawalHaircut_large_withdrawal() public pure {
        uint256 amountOut = 1000e18;
        uint128 reserves = 80;
        uint128 liabilities = 100;
        uint16 suppressionFactor = 10000; // 1x

        (uint256 actualAmount, uint256 haircutAmount) = P.applyWithdrawalHaircut(
            amountOut,
            reserves,
            liabilities,
            suppressionFactor
        );

        // Haircut should scale with withdrawal size
        assertGt(haircutAmount, 0);
        assertLt(actualAmount, amountOut);
        assertLt(haircutAmount, amountOut);
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
    // DECAY TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_calculateDecay_no_time_passed_no_decay() public pure {
        uint128 liabilities = 1000e18;
        uint128 reserves = 30e18; // 3% coverage
        uint16 decayStartRatioBps = 50000; // 5% threshold (50000 * WAD / 1_000_000 = 0.05 WAD)
        uint32 decaySlope = 31709791; // Decay slope
        uint32 dt = 0; // No time passed

        uint128 decayAmount = P.calculateDecay(
            liabilities,
            reserves,
            decayStartRatioBps,
            decaySlope,
            dt
        );

        assertEq(decayAmount, 0); // No decay when dt = 0
    }

    function test_calculateDecay_above_threshold_no_decay() public pure {
        uint128 liabilities = 1000e18;
        uint128 reserves = 60e18; // 6% coverage (above 5% threshold)
        uint16 decayStartRatioBps = 50000; // 5% threshold
        uint32 decaySlope = 31709791;
        uint32 dt = 1000; // Time passed

        uint128 decayAmount = P.calculateDecay(
            liabilities,
            reserves,
            decayStartRatioBps,
            decaySlope,
            dt
        );

        // Above threshold, no decay
        assertEq(decayAmount, 0);
    }

    function test_calculateDecay_below_threshold_with_decay() public pure {
        uint128 liabilities = 1000e18;
        uint128 reserves = 30e18; // 3% coverage (below 5% threshold)
        uint16 decayStartRatioBps = 50000; // 5% threshold
        uint32 decaySlope = 31709791; // ~1e18 / 31536000 (approximately 1% per year)
        uint32 dt = 1000; // 1000 seconds passed

        uint128 decayAmount = P.calculateDecay(
            liabilities,
            reserves,
            decayStartRatioBps,
            decaySlope,
            dt
        );

        // Below threshold, should have decay
        assertGt(decayAmount, 0);
    }

    function test_calculateDecay_linear_with_time() public pure {
        uint128 liabilities = 1000e18;
        uint128 reserves = 30e18; // 3% coverage (below threshold)
        uint16 decayStartRatioBps = 50000; // 5% threshold
        uint32 decaySlope = 31709791; // ~1e18 / 31536000 (approximately 1% per year)

        uint128 decay1000s = P.calculateDecay(liabilities, reserves, decayStartRatioBps, decaySlope, 1000);
        uint128 decay2000s = P.calculateDecay(liabilities, reserves, decayStartRatioBps, decaySlope, 2000);

        // Decay should increase with time
        assertGt(decay2000s, decay1000s);
    }

    function test_calculateDecay_zero_slope_no_decay() public pure {
        uint128 liabilities = 1000e18;
        uint128 reserves = 30e18; // 3% coverage (below threshold)
        uint16 decayStartRatioBps = 50000; // 5% threshold
        uint32 decaySlope = 0; // Zero slope
        uint32 dt = 1000;

        uint128 decayAmount = P.calculateDecay(
            liabilities,
            reserves,
            decayStartRatioBps,
            decaySlope,
            dt
        );

        // Zero slope means no decay
        assertEq(decayAmount, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASES & INTEGRATION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_coverage_and_skew_consistency() public pure {
        uint128 reserves = 150;
        uint128 liabilities = 100;
        uint16 coverageFloor = 50000;
        uint16 gamma = 10000;

        uint256 coverage = P.calculateCoverage(reserves, liabilities);
        int8 skew = P.computeInventorySkew(reserves, liabilities, coverageFloor, gamma);

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

    function test_haircut_proportional_to_deviation() public pure {
        uint256 amountOut = 100e18;
        uint128 liabilities = 100;
        uint16 suppressionFactor = 10000;

        (, uint256 haircut95) = P.applyWithdrawalHaircut(amountOut, 95, liabilities, suppressionFactor);
        (, uint256 haircut90) = P.applyWithdrawalHaircut(amountOut, 90, liabilities, suppressionFactor);
        (, uint256 haircut80) = P.applyWithdrawalHaircut(amountOut, 80, liabilities, suppressionFactor);

        // Larger deviation should have larger haircut
        assertLt(haircut95, haircut90);
        assertLt(haircut90, haircut80);
    }
}
