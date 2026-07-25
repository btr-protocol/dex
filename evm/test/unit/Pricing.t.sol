// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {BaseTestSetup, MockAC, MockOracle, NO_DEADLINE} from "../fixtures/BaseTestSetup.sol";
import {Pricing as P} from "../../src/libraries/Pricing.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {MockERC20} from "../../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../../src/Pool.sol";
import {PoolAux} from "../../src/PoolAux.sol";
import {PoolFactory} from "../../src/PoolFactory.sol";
import {Admin} from "../../src/Admin.sol";
import {Flash} from "../../src/Flash.sol";
import {Constants as C} from "../../src/libraries/Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";

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
    int8 skew05x = P.computeInventorySkew(reserves, liabilities, coverageMin, 20000, 5000); // 0.5x
    int8 skew2x = P.computeInventorySkew(reserves, liabilities, coverageMin, 20000, 20000); // 2x

    // With linear multiplier: higher gamma = more extreme (more negative) skew
    assertGt(skew05x, skew1x, "0.5x should be less extreme than 1x"); // -25 > -50
    assertGt(skew1x, skew2x, "1x should be less extreme than 2x"); // -50 > -100
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
    uint128 liabilities = 100e18; // 60% coverage (in amplification zone between 50% and 100%)

    uint256 depth0 = P.calculateDepth(reserves, liabilities, 0); // No amplification
    uint256 depth10k = P.calculateDepth(reserves, liabilities, 10000); // 1% amplification
    uint256 depth50k = P.calculateDepth(reserves, liabilities, 50000); // 5% amplification

    // depth0 should equal reserves when no amplification
    assertEq(depth0, reserves);
    // Higher amplifier should give more virtual depth
    assertGt(depth10k, depth0);
    assertGt(depth50k, depth10k);
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

  // ═══════════════════════════════════════════════════════════════════════════
  // EMPTY-CURVE FALLBACK FLOOR (Item A): the no-profile mid (_skewToPrice) routes through the SAME
  // −90% offset / 5%-of-mark backstops the spline path uses, so a degenerate mark or a dispersion that
  // bypasses the admin ceiling (900000) can never zero/brick the fallback quote. buy = mid·(WAD+k)/WAD
  // ≥ mid, so flooring the mid floors both the sell and buy fallback (the presetId-0 bootstrap path).
  // ═══════════════════════════════════════════════════════════════════════════

  /// @notice At the admin ceiling (disp 900000, worst skew −100) the fallback mid floors to 10% of mark.
  function test_skewToPrice_at_ceiling_is_ten_pct_mark() public pure {
    // offset = −100·900000/100 = −900000 ⇒ mid = mark·(PBPS−900000)/PBPS = 10% mark.
    assertEq(P._skewToPrice(1e18, -100, 900_000), 1e17);
  }

  /// @notice Degenerate disp ABOVE PBPS (only reachable if the ceiling were bypassed) clamps to the
  ///         −90% offset floor ⇒ 10% of mark, never 0 — the belt-and-suspenders that keeps the empty-
  ///         curve buy quote from bricking. Without the floor, offset −2000000 ⇒ mark multiplier < 0 ⇒ 0.
  function test_skewToPrice_extreme_disp_stays_positive() public pure {
    // offset = −100·2000000/100 = −2000000; SPLINE floor caps it at −900000 ⇒ mid = 10% mark (> 0).
    uint256 px = P._skewToPrice(1e18, -100, 2_000_000);
    assertGt(px, 0);
    assertEq(px, 1e17); // 10% of 1e18 (offset floor dominates the 5%-of-mark floor here)
  }

  /// @notice Honest wide-volatile band (disp 500000 = 50% PBPS, worst skew −100): untouched by the floor,
  ///         mid = 50% mark. Confirms the guard only bites degenerate configs, not legitimate ones.
  function test_skewToPrice_honest_wide_band_unfloored() public pure {
    assertEq(P._skewToPrice(1e18, -100, 500_000), 5e17); // 50% mark, above both floors
  }
}

/// @notice Numeric PoC pinning the σ→spread claw-back magnitude — refutes audit H-2's claim that
///         "the σ-floor alone makes a stale-mark round trip spread-negative". S_vol = minFeePath +
///         σ·vega/(100·BPS): a σ-floor engaged at the push move δ widens the spread by only
///         vega·δ/1e6 — ≤ 6.55% of δ at the uint16 vega ceiling, 1% of δ at the shipped vega=10000.
///         The real defense is minFee ≥ 2θ (machine-enforced: risk fences + keeper deviation gate):
///         a flat-truth attacker enters at a mark θ stale-low and exits θ stale-high (mark walks 2θ
///         across two θ-pushes), paying spread/2 per leg ⇒ round-trip PnL ≈ 2θ − minFee, sign
///         flipping at minFee = 2θ (exact boundary 2θ/(1+θ) + O(θ²)).
contract SigmaFloorClawbackTest is BaseTestSetup {
  address internal constant OWNER = address(0xA11CE);
  address internal constant ATK = address(0xBAD);
  uint256 internal constant THETA_PBPS = 10_000; // θ = 1% per-push deviation trigger
  uint16 internal constant SHIPPED_VEGA = 10_000;

  Admin internal admin;
  PoolFactory internal factory;
  MockAC internal ac;

  function setUp() public override {
    ac = new MockAC(OWNER);
    admin = new Admin(address(ac));
    Flash flash = new Flash();
    PoolAux aux = new PoolAux(address(ac), address(admin), address(flash));
    Pool implementation = new Pool(address(ac), address(admin), address(flash), address(aux));
    factory = new PoolFactory(address(implementation), address(this), address(ac));
  }

  /// @dev Fresh 2-asset pool (base + tok, marks 1.0, 1M seed each) with per-asset `minFeePbps`.
  function _newPool(uint16 minFeePbps)
    internal
    returns (Pool pool, MockERC20 base, MockERC20 tok, MockOracle oracle)
  {
    base = new MockERC20("Base", "BASE", 18);
    tok = new MockERC20("Tok", "TOK", 18);
    address[] memory tokens = new address[](2);
    tokens[0] = address(base);
    tokens[1] = address(tok);
    bytes memory initdata = abi.encodeWithSelector(
      Pool.initialize.selector,
      address(base),
      address(base),
      IPool.FeeParams({protoShare: 25, flashFeePbps: 100})
    );
    pool = Pool(payable(factory.createPool(address(base), tokens, initdata)));

    oracle = new MockOracle();
    IPool.RiskConfig memory r;
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20000;
    r.depthAmplifier = 10000;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
    oracle.setMark(address(base), M.encodeB64(1e18, 18));
    oracle.setMark(address(tok), M.encodeB64(1e18, 18));
    vm.startPrank(OWNER);
    admin.setCurve(address(pool), DEFAULT_PRESET, defaultCurveInterior(), defaultCurveWQ(), 1000, 0);
    admin.addAsset(
      address(pool),
      address(base),
      externalOracleCfg(oracle, address(base)),
      r,
      DEFAULT_PRESET,
      minFeePbps,
      18,
      1000,
      100000,
      10000,
      SHIPPED_VEGA
    );
    admin.addAsset(
      address(pool),
      address(tok),
      externalOracleCfg(oracle, address(tok)),
      r,
      DEFAULT_PRESET,
      minFeePbps,
      18,
      1000,
      100000,
      10000,
      SHIPPED_VEGA
    );
    // addAsset defaults maxFee to 1% (ONE_PCT_PBPS) which would clamp the >2θ parametrization —
    // lift it so the spread floor (minFee), not the cap, is what the boundary test measures.
    admin.setAssetParams(
      address(pool), address(base), 0, minFeePbps, 50_000, 10000, SHIPPED_VEGA, 0, 0, 0
    );
    admin.setAssetParams(
      address(pool), address(tok), 0, minFeePbps, 50_000, 10000, SHIPPED_VEGA, 0, 0, 0
    );
    vm.stopPrank();

    for (uint256 i = 0; i < 2; i++) {
      MockERC20 t = MockERC20(tokens[i]);
      t.mint(address(this), 1_000_000e18);
      t.approve(address(pool), type(uint256).max);
      pool.deposit(tokens[i], 1_000_000e18);
    }
  }

  /// @dev σ=0 feeds (isolates the minFee term); pushes marks with full control. Advances time 1s
  ///      first — a same-timestamp overwrite is not a new push to the pool (and via_ir caches raw
  ///      block.timestamp reads across warps, hence getBlockTimestamp).
  function _push(MockOracle o, address token, uint256 px, uint32 sigma) internal {
    vm.warp(vm.getBlockTimestamp() + 1);
    o.setFeed(o.feedIdFor(token), M.encodeB64(px, 18), sigma, 0, type(uint16).max);
  }

  /// @dev Flat-truth staleness round trip: buy tok at mark (1−θ), keeper walks the mark 2θ (two
  ///      θ-pushes) to (1+θ), sell back. Returns PnL in PBPS of the base notional.
  function _roundTripPnlPbps(uint16 minFeePbps) internal returns (int256) {
    (Pool pool, MockERC20 base, MockERC20 tok, MockOracle o) = _newPool(minFeePbps);
    _push(o, address(base), 1e18, 0);
    _push(o, address(tok), 0.99e18, 0); // mark θ stale-low vs truth 1.0
    uint256 baseIn = 100e18;
    base.mint(ATK, baseIn);
    vm.startPrank(ATK);
    base.approve(address(pool), type(uint256).max);
    tok.approve(address(pool), type(uint256).max);
    uint256 tokOut = pool.swap(address(base), address(tok), baseIn, 0, ATK, NO_DEADLINE);
    vm.stopPrank();
    _push(o, address(tok), 1.01e18, 0); // mark walks +2θ; now θ stale-high vs flat truth
    vm.prank(ATK);
    uint256 baseOut = pool.swap(address(tok), address(base), tokOut, 0, ATK, NO_DEADLINE);
    return ((int256(baseOut) - int256(baseIn)) * int256(SC.PBPS)) / int256(baseIn);
  }

  /// forge-config: default.isolate = true
  function test_sigmaFloor_clawback_bounded_and_2theta_boundary() public {
    // isolate: each pool call is its own tx — otherwise the pool's tx-scoped TransientCache serves
    // leg 2 the leg-1 mark (a foundry single-tx artifact; real txs clear tstore).
    // ── Part A: σ-floor claw-back is bounded by vega·δ/1e6 — a few % of the move, not a defense.
    (Pool pool, MockERC20 base, MockERC20 tok, MockOracle o) = _newPool(1000);
    _push(o, address(base), 1e18, 0);
    _push(o, address(tok), 1e18, 0);
    uint256 s0 = pool.getSwapQuote(address(base), address(tok), 100e18).spreadPbps;
    uint256 delta = THETA_PBPS; // δ = 1% mark move, PBPS-scaled (σ units)
    _push(o, address(tok), 1.01e18, uint32(delta)); // σ-floor engaged: σ = δ
    uint256 s1 = pool.getSwapQuote(address(base), address(tok), 100e18).spreadPbps;
    uint256 claw = s1 - s0;
    assertEq(
      claw, (delta * SHIPPED_VEGA) / (100 * SC.BPS), "claw-back = vega*delta/1e6 (1% of delta)"
    );
    assertLe(
      claw,
      (delta * type(uint16).max) / (100 * SC.BPS),
      "claw-back ceiling: <=6.55% of delta at uint16 vega max"
    );

    // ── Part B: the real defense — round-trip PnL flips sign exactly at the minFee = 2θ boundary.
    int256 below = _roundTripPnlPbps(uint16((2 * THETA_PBPS * 95) / 100)); // 19_000 < 2θ
    int256 above = _roundTripPnlPbps(uint16((2 * THETA_PBPS * 105) / 100)); // 21_000 > 2θ
    assertGt(below, 0, "minFee < 2theta: 2theta staleness capture beats fees (extractive)");
    assertLt(above, 0, "minFee >= 2theta: fees dominate the 2theta staleness capture");
  }
}
