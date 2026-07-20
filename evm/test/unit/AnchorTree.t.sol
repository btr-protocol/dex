// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {BaseTestSetup} from "../fixtures/BaseTestSetup.sol";
import {AnchorTree as T} from "../../src/libraries/AnchorTree.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @notice Exposes AnchorTree internals over an isolated pool-storage slot.
contract LibAnchorTreeHarness {
  bytes32 private constant POOL_STORAGE_SLOT =
    keccak256(abi.encode(uint256(keccak256("btr.storage.pool")) - 1)) & ~bytes32(uint256(0xff));

  function _s() internal pure returns (IPool.PoolStorage storage $) {
    bytes32 slot = POOL_STORAGE_SLOT;
    assembly { $.slot := slot }
  }

  function setBaseToken(address b) external {
    _s().baseToken = b;
  }

  function configureAsset(address asset, address anchor, uint8 decimals) external {
    IPool.PoolStorage storage $ = _s();
    $.assets[asset].anchor = anchor;
    $.assets[asset].decimals = decimals;
  }

  function validateAnchor(address asset, address anchor) external view returns (uint8) {
    return T.validateAnchor(_s(), asset, anchor);
  }

  function findRoutingPath(address a, address b) external view returns (IPool.RoutePath memory) {
    return T.findRoutingPath(_s(), a, b);
  }
}

/// @notice AnchorTree is a depth-1 STAR: base = depth 0, every spoke anchors directly to base
///         (depth 1). A cross-spoke swap is always spoke→base→spoke (two EDGE legs); no deeper tree
///         and no interior mid-priced legs can exist — that is what kills the route path-dependence.
contract LibAnchorTreeTest is BaseTestSetup {
  LibAnchorTreeHarness harness;

  address constant BASE = address(0x1);
  address constant SPOKE_A = address(0x2);
  address constant SPOKE_B = address(0x3);
  address constant OUTSIDER = address(0x9); // not in the tree

  function setUp() public override {
    super.setUp();
    harness = new LibAnchorTreeHarness();
    harness.setBaseToken(BASE);
    harness.configureAsset(BASE, address(0), 18);
    harness.configureAsset(SPOKE_A, BASE, 18);
    harness.configureAsset(SPOKE_B, BASE, 6);
  }

  // ── validateAnchor ──

  function test_validate_base_anchors_null() public view {
    assertEq(harness.validateAnchor(BASE, address(0)), 0, "base = depth 0");
  }

  function test_validate_spoke_anchors_base() public view {
    assertEq(harness.validateAnchor(SPOKE_A, BASE), 1, "spoke = depth 1");
  }

  function test_validate_rejects_deep_anchor() public {
    // anchoring a spoke to ANOTHER spoke (would be depth 2) must be rejected — enforces the star.
    vm.expectRevert(abi.encodeWithSelector(Err.DepthExceeded.selector, SPOKE_B, 2));
    harness.validateAnchor(SPOKE_B, SPOKE_A);
  }

  function test_validate_rejects_self_anchor() public {
    vm.expectRevert(abi.encodeWithSelector(Err.InvalidAnchor.selector, SPOKE_A, SPOKE_A));
    harness.validateAnchor(SPOKE_A, SPOKE_A);
  }

  function test_validate_rejects_null_anchor_for_nonbase() public {
    vm.expectRevert(abi.encodeWithSelector(Err.InvalidAnchor.selector, SPOKE_A, address(0)));
    harness.validateAnchor(SPOKE_A, address(0));
  }

  // ── findRoutingPath ──

  function test_route_base_to_spoke_is_direct() public view {
    IPool.RoutePath memory p = harness.findRoutingPath(BASE, SPOKE_A);
    assertEq(p.hops.length, 2, "direct = 2 nodes");
    assertEq(p.hops[0], BASE);
    assertEq(p.hops[1], SPOKE_A);
  }

  function test_route_spoke_to_base_is_direct() public view {
    IPool.RoutePath memory p = harness.findRoutingPath(SPOKE_A, BASE);
    assertEq(p.hops.length, 2, "direct = 2 nodes");
    assertEq(p.hops[0], SPOKE_A);
    assertEq(p.hops[1], BASE);
  }

  function test_route_spoke_to_spoke_via_base() public view {
    IPool.RoutePath memory p = harness.findRoutingPath(SPOKE_A, SPOKE_B);
    assertEq(p.hops.length, 3, "sibling = 3 nodes (spoke->base->spoke)");
    assertEq(p.hops[0], SPOKE_A);
    assertEq(p.hops[1], BASE, "interior node is base");
    assertEq(p.hops[2], SPOKE_B);
  }

  function test_route_rejects_asset_not_in_tree() public {
    vm.expectRevert(abi.encodeWithSelector(Err.AssetNotInTree.selector, OUTSIDER));
    harness.findRoutingPath(OUTSIDER, SPOKE_A);
  }
}
