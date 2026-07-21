// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ChapelEnableSwaps} from "../../script/ChapelEnableSwaps.s.sol";
import {PoolAdminHarness} from "./PoolAdmin.t.sol";
import {NUQuartic} from "../../src/libraries/NUQuartic.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @dev Exposes the deploy script's internal preset getters + baked asset->preset map for testing.
contract ChapelPresetsExposer is ChapelEnableSwaps {
  function preset(uint16 id)
    external
    pure
    returns (uint256[] memory interior, int256[] memory wQ, uint16 dispRef, uint8 flags)
  {
    return _preset(id);
  }

  /// @dev Asserts the §3/§4 asset->preset map exactly (reverts on any mismatch); addresses owned here.
  function checkMap() external pure {
    // stable pool
    require(_presetFor(USDC, true) == 10, "USDC stable");
    require(_presetFor(USDT, true) == 11, "USDT stable"); // hyper, walled
    require(_presetFor(USD1, true) == 10, "USD1");
    require(_presetFor(USDE, true) == 12, "USDE");
    require(_presetFor(FDUSD, true) == 10, "FDUSD");
    // volatile pool (no hyper)
    require(_presetFor(USDC, false) == 20, "USDC vol");
    require(_presetFor(USDT, false) == 20, "USDT vol");
    require(_presetFor(BTCB, false) == 21, "BTCB");
    require(_presetFor(ETH, false) == 21, "ETH");
    require(_presetFor(WBNB, false) == 21, "WBNB");
    require(_presetFor(CAKE, false) == 22, "CAKE");
    require(_presetFor(XAUT, false) == 23, "XAUT");
  }
}

/// @notice Verifies the fitted Chapel presets install (NUQuartic.set) and pass validatePresetAssign
///         at each asset's binding (largest) maxDispersion, and that hyper (11) is wall-gated.
contract ChapelPresetsTest is Test {
  ChapelPresetsExposer exposer;
  PoolAdminHarness h;

  address constant ASSET = address(0xA55E7); // representative asset (identity only matters for kappa)

  function setUp() public {
    exposer = new ChapelPresetsExposer();
    h = new PoolAdminHarness();
    h.setBaseToken(address(0xBA5E)); // ensure ASSET != base (base forbids kappa wall)
  }

  struct Case {
    uint16 id;
    uint32 maxDisp; // binding = largest maxDisp assigned to the preset
    bool wall; // FLAG_REQUIRES_WALL expected
  }

  function _cases() internal pure returns (Case[7] memory c) {
    // maxDisp = largest among assets on the preset (RISK_PARAMS_TESTNET.md §3/§4)
    c[0] = Case(10, 8000, false); // plateau W1: USDC 2000 / USD1 5000 / FDUSD 8000
    c[1] = Case(11, 6000, true); // hyper W0.5: USDT 6000 (walled)
    c[2] = Case(12, 5000, false); // plateau W2: USDE 5000
    c[3] = Case(20, 500_000, false); // plateau W1 vol: USDC/USDT 500000
    c[4] = Case(21, 500_000, false); // lepto W5: BTCB/ETH/WBNB 500000
    c[5] = Case(22, 500_000, false); // platy W5: CAKE 500000
    c[6] = Case(23, 500_000, false); // meso W2: XAUT 500000
  }

  /// @dev setCurve (NUQuartic._validate: monotone Δw≥0, non-flat, segs≤14) + validatePresetAssign
  ///      (min-offset > 0 at binding maxDisp) must pass for every preset; logs the min-offset margin.
  function test_presets_install_validate_and_margin() public {
    Case[7] memory cs = _cases();
    for (uint256 i = 0; i < cs.length; i++) {
      Case memory c = cs[i];
      (uint256[] memory interior, int256[] memory wQ, uint16 dispRef, uint8 flags) =
        exposer.preset(c.id);

      // shape sanity: quartic clamped spline lengths (interior = wQ-5; segs = wQ-4 ≤ 14)
      assertEq(interior.length, wQ.length - 5, "interior len");
      assertLe(wQ.length - 4, NUQuartic.MAX_SEGS, "segs<=14");
      assertEq(flags, c.wall ? NUQuartic.FLAG_REQUIRES_WALL : uint8(0), "flags");
      // edge reconciliation: |wQ[last]| ≈ |wQ[0]| ≈ dispRef*Q
      assertEq(wQ[0], -int256(uint256(dispRef)) * NUQuartic.Q, "wQ[0]=-dispRef*Q");

      // install (reverts on non-monotone / flat / segs>14 / dispRef==0)
      h.callSetCurve(c.id, interior, wQ, dispRef, flags);

      // wall-gated presets need kappa>0 on the asset before assignment
      h.setKappa(ASSET, c.wall ? 100 : 0);
      h.callValidatePresetAssign(ASSET, c.id, c.maxDisp); // reverts if min-offset ≤ 0

      // report min-offset margin (PBPS units): PBPS + wQ[0]*maxDisp/(dispRef*Q), same as on-chain check
      int256 margin = int256(SC.PBPS) + (wQ[0] * int256(uint256(c.maxDisp)))
        / (int256(uint256(dispRef)) * NUQuartic.Q);
      assertGt(margin, 0, "min-offset margin > 0");
      console2.log("preset", c.id);
      console2.log("  maxDisp", c.maxDisp);
      console2.log("  minOffsetMarginPbps", margin);
    }
  }

  /// @dev hyper (11) carries FLAG_REQUIRES_WALL: assignment to a kappa=0 asset MUST revert BadConfig,
  ///      and succeed once walled (kappa=100). Confirms it is only safe on the walled USDT spoke.
  function test_hyper_preset_requires_wall() public {
    (uint256[] memory interior, int256[] memory wQ, uint16 dispRef, uint8 flags) =
      exposer.preset(11);
    assertEq(flags, NUQuartic.FLAG_REQUIRES_WALL, "hyper flags");
    h.callSetCurve(11, interior, wQ, dispRef, flags);

    h.setKappa(ASSET, 0);
    vm.expectRevert(Err.BadConfig.selector);
    h.callValidatePresetAssign(ASSET, 11, 6000);

    h.setKappa(ASSET, 100);
    h.callValidatePresetAssign(ASSET, 11, 6000); // now passes
  }

  /// @dev The baked per-asset preset map matches RISK_PARAMS_TESTNET.md §3/§4 exactly.
  function test_asset_preset_map() public view {
    exposer.checkMap();
  }
}
