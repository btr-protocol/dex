// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {PoolAdmin} from "../../src/libraries/PoolAdmin.sol";
import {NUQuartic} from "../../src/libraries/NUQuartic.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @notice Mock IOracle that returns a canned FeedData (or reverts) on getFeed.
contract MockOracle {
  bool public shouldRevert;

  function setRevert(bool v) external {
    shouldRevert = v;
  }

  function getFeed(bytes32) external view returns (IOracle.FeedData memory d) {
    if (shouldRevert) revert("mock-oracle-revert");
    d.lastPriceB64 = 1;
  }
}

/// @notice Harness exposing PoolAdmin internals over a slot-0 PoolStorage instance.
contract PoolAdminHarness {
  IPool.PoolStorage internal $;

  function setBaseToken(address t) external {
    $.baseToken = t;
  }

  function getAsset(address t) external view returns (IPool.Asset memory) {
    return $.assets[t];
  }

  function getOracleConfig(address t) external view returns (IPool.OracleConfig memory) {
    return $.oracleConfigs[t];
  }

  function getRiskConfig(address t) external view returns (IPool.RiskConfig memory) {
    return $.riskConfigs[t];
  }

  function getPresetId(address t) external view returns (uint16) {
    return $.assets[t].presetId;
  }

  function callSetCurve(
    uint16 id,
    uint256[] memory interior,
    int256[] memory wQ,
    uint16 dispRef,
    uint8 flags
  ) external {
    NUQuartic.set($.curves[id], interior, wQ, dispRef, flags);
  }

  function callValidatePresetAssign(address t, uint16 presetId, uint32 maxDispersion)
    external
    view
  {
    PoolAdmin.validatePresetAssign($, t, presetId, maxDispersion);
  }

  function callValidateInternalMode(address t, IPool.OracleConfig memory cfg) external view {
    PoolAdmin.validateInternalMode($, t, cfg);
  }

  function seedPeg(address t) external {
    $.assets[t].pegB64 = 1; // nonzero peg so INTERNAL passes the pegB64 gate
    $.assets[t].reservationPrice = 1; // abs depeg band present
  }

  function setKappa(address t, uint16 kappa) external {
    $.riskConfigs[t].kappaCovBps = kappa;
  }

  function callValidateOracleConfig(IPool.OracleConfig memory cfg) external view {
    PoolAdmin.validateOracleConfig(cfg);
  }

  function callInitAsset(
    address t,
    uint8 decimals,
    uint16 minFeePbps,
    uint32 minDispersion,
    uint32 maxDispersion,
    uint16 gamma,
    uint16 vega
  ) external {
    PoolAdmin.initAsset($, t, decimals, minFeePbps, minDispersion, maxDispersion, gamma, vega);
  }

  function callSetupOracleAndConfig(
    address t,
    IPool.OracleConfig memory oracleCfg,
    IPool.RiskConfig memory riskCfg,
    uint16 presetId
  ) external {
    PoolAdmin.setupOracleAndConfig($, t, oracleCfg, riskCfg, presetId);
  }
}

/// @title PoolAdminTest
/// @notice Phase 42H.D · Round 3 (G8) -direct unit tests for PoolAdmin library.
///         Covers validatePresetAssign edge cases, validateOracleConfig boundaries,
///         initAsset full path (base vs non-base, default fallbacks), and
///         setupOracleAndConfig integration (self-oracle seeding + non-self skip).
contract PoolAdminTest is Test {
  PoolAdminHarness h;
  MockOracle mock;
  address constant BASE = address(0xBA5E);
  address constant TKA = address(0xA1);

  function setUp() public {
    h = new PoolAdminHarness();
    mock = new MockOracle();
    h.setBaseToken(BASE);
    vm.warp(1_700_000_000);
  }

  function _curveArgs() internal pure returns (uint256[] memory interior, int256[] memory wQ) {
    interior = new uint256[](4);
    (interior[0], interior[1], interior[2], interior[3]) = (2000, 4000, 6000, 8000);
    wQ = new int256[](9);
    for (uint256 i = 0; i < 9; ++i) {
      wQ[i] = -500e9 + int256(i) * 125e9;
    }
  }

  // ─── validatePresetAssign ───

  function test_presetAssign_zeroIsNoShape() public view {
    h.callValidatePresetAssign(TKA, 0, 0); // explicit fallback: always valid
  }

  function test_presetAssign_unknownPresetReverts() public {
    vm.expectRevert(abi.encodeWithSelector(Err.NotConfigured.selector, Err.Resource.ASSET, TKA));
    h.callValidatePresetAssign(TKA, 9, 0);
  }

  function test_presetAssign_installedPresetPasses() public {
    (uint256[] memory interior, int256[] memory wQ) = _curveArgs();
    h.callSetCurve(1, interior, wQ, 1000, 0);
    h.callValidatePresetAssign(TKA, 1, 0);
  }

  function test_presetAssign_wallFlagRequiresKappa() public {
    (uint256[] memory interior, int256[] memory wQ) = _curveArgs();
    h.callSetCurve(2, interior, wQ, 1000, NUQuartic.FLAG_REQUIRES_WALL);
    vm.expectRevert(Err.BadConfig.selector); // unwalled asset (kappa 0) may not price on a hyper tier
    h.callValidatePresetAssign(TKA, 2, 0);
    h.setKappa(TKA, 500);
    h.callValidatePresetAssign(TKA, 2, 0); // walled: passes
  }

  function test_internalMode_baseRejected() public {
    // Base is the numeraire: INTERNAL mode would no-op its depeg breaker on every base hop.
    h.seedPeg(BASE);
    IPool.OracleConfig memory cfg;
    cfg.primary = address(mock);
    cfg.feedId = bytes32(uint256(1));
    cfg.mode = 1; // INTERNAL
    cfg.refFeedId = bytes32(uint256(2));
    cfg.refBandBps = 10;
    vm.expectRevert(Err.BadConfig.selector);
    h.callValidateInternalMode(BASE, cfg);
    // Same config on a NON-base asset is accepted.
    h.seedPeg(TKA);
    h.callValidateInternalMode(TKA, cfg);
  }

  function test_presetAssign_minOffsetBoundAtMaxDispersion() public {
    // wQ[0] = −990000 pbps (−99%) at dispRef 1000: multiplier goes non-positive once
    // maxDispersion pushes the scaled offset past −100% ⇒ BadConfig.
    (uint256[] memory interior, int256[] memory wQ) = _curveArgs();
    for (uint256 i = 0; i < 9; ++i) {
      wQ[i] = -990_000e9 + int256(i) * 1e9;
    }
    h.callSetCurve(3, interior, wQ, 1000, 0);
    h.callValidatePresetAssign(TKA, 3, 1000); // −99% at dispRef: still positive
    vm.expectRevert(Err.BadConfig.selector);
    h.callValidatePresetAssign(TKA, 3, 2000); // −198% ⇒ multiplier ≤ 0
  }

  // ─── validateOracleConfig ───

  function test_validateOracle_revertsOnZeroPrimary() public {
    IPool.OracleConfig memory cfg;
    cfg.primary = address(0);
    vm.expectRevert(Err.InvalidInput.selector);
    h.callValidateOracleConfig(cfg);
  }

  function test_validateOracle_selfPrimaryRejected() public {
    IPool.OracleConfig memory cfg;
    cfg.primary = address(h); // self
    vm.expectRevert(Err.InvalidInput.selector);
    h.callValidateOracleConfig(cfg);
  }

  function test_validateOracle_externalPrimaryReachable() public view {
    IPool.OracleConfig memory cfg;
    cfg.primary = address(mock);
    h.callValidateOracleConfig(cfg);
  }

  function test_validateOracle_externalPrimaryReverts() public {
    mock.setRevert(true);
    IPool.OracleConfig memory cfg;
    cfg.primary = address(mock);
    vm.expectRevert(Err.InvalidInput.selector);
    h.callValidateOracleConfig(cfg);
  }

  // ─── Layer-3 (Ostium hardening): armed ref band requires an explicit, reachable refPrimary ───

  function _refBandCfg() internal view returns (IPool.OracleConfig memory cfg) {
    cfg.primary = address(mock);
    cfg.refFeedId = bytes32(uint256(1));
    cfg.refBandBps = 100;
  }

  function test_validateOracle_refBandWithoutRefPrimaryRejected() public {
    IPool.OracleConfig memory cfg = _refBandCfg();
    vm.expectRevert(Err.InvalidInput.selector); // refPrimary == 0 with an armed band
    h.callValidateOracleConfig(cfg);
  }

  function test_validateOracle_refBandWithoutRefFeedIdRejected() public {
    IPool.OracleConfig memory cfg = _refBandCfg();
    cfg.refFeedId = bytes32(0);
    cfg.refPrimary = address(mock);
    vm.expectRevert(Err.InvalidInput.selector);
    h.callValidateOracleConfig(cfg);
  }

  function test_validateOracle_refBandWithIndependentRefPrimaryPasses() public {
    IPool.OracleConfig memory cfg = _refBandCfg();
    cfg.refPrimary = address(new MockOracle());
    h.callValidateOracleConfig(cfg);
  }

  function test_validateOracle_refBandWithSamePrimaryRejected() public {
    IPool.OracleConfig memory cfg = _refBandCfg();
    cfg.refPrimary = cfg.primary;
    vm.expectRevert(Err.InvalidInput.selector);
    h.callValidateOracleConfig(cfg);
  }

  function test_validateOracle_unreachableRefPrimaryRejected() public {
    MockOracle dead = new MockOracle();
    dead.setRevert(true);
    IPool.OracleConfig memory cfg = _refBandCfg();
    cfg.refPrimary = address(dead);
    vm.expectRevert(Err.InvalidInput.selector);
    h.callValidateOracleConfig(cfg);
  }

  function test_validateOracle_disarmedBandSkipsRefChecks() public view {
    IPool.OracleConfig memory cfg;
    cfg.primary = address(mock);
    cfg.refFeedId = bytes32(uint256(1)); // id set but band 0 → no ref validation
    h.callValidateOracleConfig(cfg);
  }

  // ─── initAsset ───

  function test_initAsset_baseTokenHasNoAnchor() public {
    h.callInitAsset(BASE, 18, 30, 0, 0, 0, 0);
    IPool.Asset memory a = h.getAsset(BASE);
    assertEq(a.decimals, 18);
    assertEq(a.minFeePbps, 30);
    assertEq(a.maxFeePbps, 10000);
    assertEq(a.anchor, address(0), "base has no anchor");
    // Defaults applied on zero inputs.
    assertEq(a.minDispersion, 1000);
    assertEq(a.maxDispersion, 100000);
    assertEq(a.gamma, 10000);
    assertEq(a.vega, 10000);
    assertEq(a.haircutSuppressor, 10000);
  }

  function test_initAsset_nonBaseAnchorsToBase() public {
    h.callInitAsset(TKA, 6, 25, 500, 50000, 8000, 9000);
    IPool.Asset memory a = h.getAsset(TKA);
    assertEq(a.decimals, 6);
    assertEq(a.minFeePbps, 25);
    assertEq(a.anchor, BASE, "non-base anchors to baseToken");
    assertEq(a.minDispersion, 500);
    assertEq(a.maxDispersion, 50000);
    assertEq(a.gamma, 8000);
    assertEq(a.vega, 9000);
  }

  // ─── setupOracleAndConfig ───

  function test_setupOracleAndConfig_writesAllSlots() public {
    IPool.OracleConfig memory oc;
    oc.primary = address(mock);
    oc.feedId = bytes32(uint256(1));
    IPool.RiskConfig memory rc;
    rc.decayStartRatioBps = 5000;
    h.callSetupOracleAndConfig(TKA, oc, rc, 1);

    assertEq(h.getOracleConfig(TKA).primary, address(mock));
    assertEq(h.getRiskConfig(TKA).decayStartRatioBps, 5000);
    assertEq(h.getPresetId(TKA), 1);
  }

  // ─── R44-7 (Pass-44B): minDispersion ≤ maxDispersion ───

  /// @notice initAsset must revert BadConfig when minDispersion > maxDispersion.
  function test_R44_7_initAsset_reverts_when_min_gt_max() public {
    vm.expectRevert(Err.BadConfig.selector);
    h.callInitAsset(TKA, 6, 25, 50000, 1000, 8000, 9000);
  }

  /// @notice Boundary: min == max is allowed (degenerate but well-formed: pinned dispersion).
  function test_R44_7_initAsset_allows_min_eq_max() public {
    h.callInitAsset(TKA, 6, 25, 5000, 5000, 8000, 9000);
    IPool.Asset memory a = h.getAsset(TKA);
    assertEq(a.minDispersion, 5000);
    assertEq(a.maxDispersion, 5000);
  }

  /// @notice Default substitution: 0 inputs resolve to (1000, 100000) which is ordered.
  function test_R44_7_initAsset_defaults_remain_ordered() public {
    h.callInitAsset(TKA, 6, 25, 0, 0, 0, 0);
    IPool.Asset memory a = h.getAsset(TKA);
    assertEq(a.minDispersion, 1000);
    assertEq(a.maxDispersion, 100000);
    assertLe(a.minDispersion, a.maxDispersion);
  }

  /// @notice Zero minDispersion + small maxDispersion: substitution resolves min→1000 which would
  ///         exceed max=500 → must revert. Guards "0 means default" abuse where user passes
  ///         min=0 maliciously expecting their explicit max to win.
  function test_R44_7_initAsset_reverts_when_min_default_exceeds_max() public {
    vm.expectRevert(Err.BadConfig.selector);
    h.callInitAsset(TKA, 6, 25, 0, 500, 8000, 9000); // min defaulted=1000 > 500
  }

  /// @notice Explicit ordering preserved end-to-end.
  function test_R44_7_initAsset_explicit_values_persist() public {
    h.callInitAsset(TKA, 6, 25, 2500, 75000, 8000, 9000);
    IPool.Asset memory a = h.getAsset(TKA);
    assertEq(a.minDispersion, 2500);
    assertEq(a.maxDispersion, 75000);
  }
}
