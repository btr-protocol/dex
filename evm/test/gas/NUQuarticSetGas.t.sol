// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

// PROTOTYPE (unstaged) — NUQuartic.set gas vs segment count, for the log-normal-plateau
// minimal-knot spec (owner 2026-07-22). Measures the cold first-set (zero -> nonzero slots)
// and the same-slot re-set (keeper update path; slots warm+dirty in-test, so the prod
// nonzero->nonzero cost is reconstructed analytically in the report: 5000/slot cold reset).
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {NUQuartic} from "../../src/libraries/NUQuartic.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";

contract NUQuarticSetGasTest is Test {
  NUQuartic.Curve internal curve;

  function _mk(uint256 m) internal pure returns (uint256[] memory interior, int256[] memory wQ) {
    interior = new uint256[](m - 1);
    for (uint256 i = 0; i < m - 1; ++i) {
      interior[i] = (SC.BPS * (i + 1)) / m;
    }
    wQ = new int256[](m + 4);
    for (uint256 i = 0; i < m + 4; ++i) {
      wQ[i] = int256(i) * 1e9; // strictly nondecreasing, non-flat
    }
  }

  function _probe(uint256 m) internal {
    (uint256[] memory interior, int256[] memory wQ) = _mk(m);
    uint256 g0 = gasleft();
    NUQuartic.set(curve, interior, wQ, 1000, 0);
    uint256 gCold = g0 - gasleft(); // zero -> nonzero: 22.1k/slot storage component
    g0 = gasleft();
    NUQuartic.set(curve, interior, wQ, 1000, 0);
    uint256 gWarmSame = g0 - gasleft(); // warm+dirty same-value: ~100/slot => ~pure compute+mem
    console2.log("m", m);
    console2.log("  cold first-set", gCold);
    console2.log("  warm re-set   ", gWarmSame);
  }

  function test_gas_set_by_segments() public {
    _probe(2);
    _probe(3);
    _probe(4);
    _probe(5);
    _probe(6);
    _probe(10);
    _probe(14);
  }

  // Real minimal-knot log-normal-plateau presets (out/lognormal_fit.json): proves the actual
  // knotsB + wQ vectors pass _validate and cost what the synthetic per-m probe claims.
  function _probeReal(
    string memory name,
    uint256[] memory interior,
    int256[] memory wQ,
    uint16 dispRef,
    uint8 flags
  ) internal {
    uint256 g0 = gasleft();
    NUQuartic.set(curve, interior, wQ, dispRef, flags);
    uint256 gCold = g0 - gasleft();
    g0 = gasleft();
    NUQuartic.set(curve, interior, wQ, dispRef, flags);
    uint256 gWarm = g0 - gasleft();
    console2.log(name);
    console2.log("  cold first-set", gCold);
    console2.log("  warm re-set   ", gWarm);
  }

  /// @notice Cost of the presets THIS CHAIN WILL ACTUALLY INSTALL, read from the shipped params
  ///         file. Never hand-copy vectors here: a stale literal reports gas for a curve nobody
  ///         deploys (this test previously measured the retired LN split-family presets).
  ///         Source: research/stable-core/emit_prod_params.py -> deployments/sepolia-risk-params.json.
  function test_gas_set_shipped_presets() public {
    string memory raw = vm.readFile("deployments/sepolia-risk-params.json");
    uint256 n = vm.parseJsonUint(raw, ".presetCount");
    for (uint256 i; i < n; ++i) {
      string memory base = string.concat(".presets[", vm.toString(i), "]");
      _probeReal(
        string.concat(
          "preset ",
          vm.toString(vm.parseJsonUint(raw, string.concat(base, ".id"))),
          " (central-normal plateau m=3, W=",
          vm.toString(vm.parseJsonUint(raw, string.concat(base, ".W"))),
          ")"
        ),
        vm.parseJsonUintArray(raw, string.concat(base, ".interiorB")),
        vm.parseJsonIntArray(raw, string.concat(base, ".wQ")),
        uint16(vm.parseJsonUint(raw, string.concat(base, ".dispRef"))),
        uint8(vm.parseJsonUint(raw, string.concat(base, ".flags")))
      );
    }
  }
}
