// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {NUQuartic} from "../../src/libraries/NUQuartic.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @dev Production packed-layout twin of the retired QuarticProto harness: parity vs the TS-fitted
///      objects (quartic_vectors.json), Δw≥0 monotonicity, validation reverts, hot-path gas.
contract NUQuarticTest is Test {
  using NUQuartic for NUQuartic.Curve;

  struct AreaVec {
    int256 aQ;
    uint256 x1;
    uint256 x2;
  }

  uint256 internal constant XSPAN = 10000;

  NUQuartic.Curve[] internal curves;
  string[] internal names;
  NUQuartic.Curve internal cFresh;

  string internal vec;

  // DCE guards
  int256 internal sOut;
  uint256 internal sGas;

  function setUp() public {
    vec = vm.readFile("test/proto/quartic_vectors.json");
    names = vm.parseJsonKeys(vec, "$"); // every shape family — generic, no hardcoded list
    for (uint256 i = 0; i < names.length; ++i) {
      curves.push();
      this.loadCurve(i); // external call: keeps the de Boor pyramids out of setUp's stack frame
    }
  }

  /// @dev external so set() isn't inlined into the setUp loop (via_ir stack-depth limit).
  function loadCurve(uint256 i) external {
    string memory key = string.concat(".", names[i]);
    uint256[] memory interior = vm.parseJsonUintArray(vec, string.concat(key, ".interior"));
    int256[] memory wQ = vm.parseJsonIntArray(vec, string.concat(key, ".wQ"));
    curves[i].set(interior, wQ, 500, 0);
  }

  function test_headerLayout() public view {
    for (uint256 c = 0; c < names.length; ++c) {
      uint256 header = curves[c].header;
      uint256 m = header & 0xff;
      assertLe(m, NUQuartic.MAX_SEGS, "seg cap");
      uint256 prev = 0;
      for (uint256 j = 1; j <= m; ++j) {
        uint256 b = (header >> (8 + 16 * (j - 1))) & 0xffff;
        assertGt(b, prev, "boundaries increasing");
        prev = b;
      }
      assertEq(prev, XSPAN, "last boundary = xspan");
      assertEq((header >> 232) & 0xffff, 500, "dispRef");
    }
  }

  // -- parity: Sol ≡ TS on the exact fitted objects, EVERY shape family ---------------------
  function test_parity_all() public view {
    for (uint256 c = 0; c < names.length; ++c) {
      _parityEval(c);
      _parityArea(c);
    }
  }

  function _parityEval(uint256 c) internal view {
    string memory key = string.concat(".", names[c]);
    uint256[] memory xs = vm.parseJsonUintArray(vec, string.concat(key, ".xs"));
    int256[] memory yQ = vm.parseJsonIntArray(vec, string.concat(key, ".yQ"));
    uint256 header = curves[c].header;
    int256 worst = 0;
    for (uint256 i = 0; i < xs.length; ++i) {
      int256 d = curves[c].evalQ(header, xs[i]) - yQ[i];
      if (d < 0) d = -d;
      if (d > worst) worst = d;
    }
    console2.log(string.concat("parity eval ", names[c], " worst |dy| (pbps*1e9):"), worst);
    // worst ≈ few units = ~1e-9 pbps (D-scaled derivative pyramids kill the c2·h² truncation);
    // 8+ orders below the 0.5 pbps fit tolerance.
    assertLe(worst, 200, string.concat("eval parity ", names[c]));
  }

  function _parityArea(uint256 c) internal view {
    bytes memory raw = vm.parseJson(vec, string.concat(".", names[c], ".areas"));
    AreaVec[] memory av = abi.decode(raw, (AreaVec[]));
    uint256 header = curves[c].header;
    for (uint256 i = 0; i < av.length; ++i) {
      int256 d = curves[c].areaQ(header, av[i].x1, av[i].x2) - av[i].aQ;
      if (d < 0) d = -d;
      int256 mag = av[i].aQ < 0 ? -av[i].aQ : av[i].aQ;
      // 1e-6 rel + 0.1 pbps·x-unit abs floor (symmetric shapes integrate to ~0 over full domain).
      assertLe(d, mag / 1_000_000 + 100_000_000, string.concat("area parity ", names[c]));
    }
  }

  // -- structural gate: Δw≥0 ⇒ monotone, EVERY shape ---------------------------------------
  function test_monotone_all() public view {
    for (uint256 c = 0; c < names.length; ++c) {
      uint256 header = curves[c].header;
      int256 prev = curves[c].evalQ(header, 0);
      for (uint256 x = 10; x <= XSPAN; x += 10) {
        int256 y = curves[c].evalQ(header, x);
        assertGe(y, prev - 10, string.concat("nondecreasing ", names[c])); // 1e-8 pbps slack
        prev = y;
      }
    }
  }

  function test_rejects_nonMonotone() public {
    (uint256[] memory interior, int256[] memory wQ) = _vec0();
    wQ[wQ.length - 1] = wQ[0] - 1; // force a decrease at the end
    vm.expectRevert(Err.InvalidInput.selector);
    this.pushExt(interior, wQ);
  }

  function test_rejects_flat() public {
    (uint256[] memory interior, int256[] memory wQ) = _vec0();
    for (uint256 i = 0; i < wQ.length; ++i) {
      wQ[i] = wQ[0];
    }
    vm.expectRevert(Err.InvalidInput.selector);
    this.pushExt(interior, wQ);
  }

  function test_rejects_tooManySegs() public {
    uint256 n = NUQuartic.MAX_SEGS + 5; // m = n-4 = MAX_SEGS+1
    uint256[] memory interior = new uint256[](n - 5);
    int256[] memory wQ = new int256[](n);
    for (uint256 i = 0; i < n - 5; ++i) {
      interior[i] = 100 * (i + 1);
    }
    for (uint256 i = 0; i < n; ++i) {
      wQ[i] = int256(i) * 1e9;
    }
    vm.expectRevert(Err.InvalidInput.selector);
    this.pushExt(interior, wQ);
  }

  function test_rejects_outOfRangeKnot() public {
    (uint256[] memory interior, int256[] memory wQ) = _vec0();
    interior[interior.length - 1] = XSPAN; // knot must be < xspan
    vm.expectRevert(Err.InvalidInput.selector);
    this.pushExt(interior, wQ);
  }

  function _vec0() internal view returns (uint256[] memory interior, int256[] memory wQ) {
    string memory key = string.concat(".", names[0]);
    interior = vm.parseJsonUintArray(vec, string.concat(key, ".interior"));
    wQ = vm.parseJsonIntArray(vec, string.concat(key, ".wQ"));
  }

  function pushExt(uint256[] memory interior, int256[] memory wQ) external {
    cFresh.set(interior, wQ, 500, 0);
  }

  // -- gas PER PROFILE (worst-case swap primitives): eval + O(1) full-range area -------------
  function test_gas_per_profile() public {
    for (uint256 c = 0; c < names.length; ++c) {
      uint256 header = curves[c].header;
      uint256 g0 = gasleft();
      int256 r = curves[c].evalQ(header, 4990);
      uint256 gEval = g0 - gasleft();
      g0 = gasleft();
      int256 r2 = curves[c].areaQ(header, 200, 9800); // ~full-range integral (worst span)
      uint256 gArea = g0 - gasleft();
      sOut = r + r2;
      sGas = gEval + gArea;
      console2.log(string.concat("gas ", names[c], " segs:"), curves[c].header & 0xff);
      console2.log("   eval / area (header pre-loaded):", gEval, gArea);
      assertGt(sGas, 500);
    }
  }
}
