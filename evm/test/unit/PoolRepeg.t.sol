// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {Pricing} from "../../src/libraries/Pricing.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";

/// @title PoolRepegTest
/// @notice Validates the coverage-convergence (re-peg) premium — the vol-independent term that
///         drives coverage to 1, ported from the sim proof. Confirms: (1) an under-covered asset
///         gets a positive premium far larger than the ~3-6bps dispersion-scaled skew; (2) the
///         convex (1/c−1) form exceeds the linear (1−c) spring and diverges toward the floor
///         (the Wombat-grade no-drain wall); (3) over-covered gets a symmetric discount;
///         (4) the premCap clamp binds.
contract PoolRepegTest is Test {
    uint256 constant WAD = 1e18;

    function _c(uint256 pct) internal pure returns (uint256) {
        return (pct * WAD) / 100; // coverage as WAD from a percent
    }

    // premCapBps is uint16 (PBPS units) → max 65535 = 6.55%. CAP = a non-binding large cap.
    uint16 constant CAP = type(uint16).max;

    /// Under-covered → positive premium; magnitude materially exceeds the skew's ~3-6bps (30-60 PBPS).
    function test_premium_material_and_signed() public pure {
        // c=0.7, kappa=0.1x (1000 bps), linear, uncapped: 0.1·(1−0.7)=0.03 → 30000 PBPS = 3%
        int256 lin = Pricing.covPremiumBps(_c(70), 1000, CAP, false);
        assertGt(lin, 0, "under-covered must be a premium");
        assertApproxEqAbs(uint256(lin), 30_000, 500, "linear premium ~3%");
        assertGt(uint256(lin), 6000, "premium >> skew's few bps");
    }

    /// Convex exceeds linear at the same coverage (ratio 1/c), the no-drain-wall steepening.
    function test_convex_wall_exceeds_linear() public pure {
        int256 lin = Pricing.covPremiumBps(_c(70), 1000, CAP, false); // 30000
        int256 cvx = Pricing.covPremiumBps(_c(70), 1000, CAP, true); // 0.1·(1/0.7−1)=0.0429 → 42857
        assertGt(cvx, lin, "convex > linear at c=0.7");
        assertApproxEqAbs(uint256(cvx), 42_857, 500, "convex premium ~4.29%");
        // steeper toward the floor: ratio convex/linear = 1/c grows as c falls
        int256 cvxLow = Pricing.covPremiumBps(_c(52), 200, CAP, true);
        int256 linLow = Pricing.covPremiumBps(_c(52), 200, CAP, false);
        assertGt(cvxLow * 100, linLow * 180, "convex diverges vs linear near the floor (>1.8x)");
    }

    /// Over-covered → symmetric discount (negative premium).
    function test_over_covered_discount() public pure {
        int256 off = Pricing.covPremiumBps(_c(130), 1000, CAP, false);
        assertLt(off, 0, "over-covered must be a discount");
    }

    /// The premCap clamp binds (stabilizing actuator saturation + bounds the convex quote).
    function test_prem_cap_binds() public pure {
        int256 capped = Pricing.covPremiumBps(_c(60), 10000, 500, true); // huge raw premium, cap 500 PBPS
        assertEq(capped, int256(500), "premium clamped to premCap");
    }

    /// At the peg, no premium; kappa=0 disables entirely.
    function test_peg_and_disabled() public pure {
        assertEq(Pricing.covPremiumBps(WAD, 5000, CAP, true), 0, "no premium at c=1");
        assertEq(Pricing.covPremiumBps(_c(70), 0, CAP, true), 0, "kappa=0 disabled");
    }
}
