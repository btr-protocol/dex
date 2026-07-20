// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {ExternalOracle} from "../../src/oracles/ExternalOracle.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {Oracle} from "../../src/libraries/Oracle.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {Err} from "@btr-shared/Errors.sol";
import {MockAC} from "../fixtures/BaseTestSetup.sol";

/// @notice Admin feed management (addFeed seed + updateFeed config). The mark-update path is signature-only
///         (batchPushSigned) — covered in ExternalOracleSigned.t.sol.
contract ExternalOracleTest is Test {
  ExternalOracle ext;
  MockAC ac;
  address constant BASE = address(0xB05E);
  address constant QUOTE = address(0x9907E);
  bytes32 feedId;

  uint16 constant TAU = 100;

  function setUp() public {
    ac = new MockAC(address(this));
    address[] memory initialSigners = new address[](3);
    initialSigners[0] = address(0xA11CE);
    initialSigners[1] = address(0xB0B);
    initialSigners[2] = address(0xCA401);
    ext = new ExternalOracle(address(ac), 600, initialSigners, 2);
    vm.warp(1_700_000_000);
    ext.addFeed(
      BASE, QUOTE, M.encodeB64(3000e18, 18), 1e4, 5, ext.MAX_DEV_THRESHOLD(), 3600
    );
    feedId = keccak256(abi.encodePacked(BASE, QUOTE));
  }

  function test_addFeed_seedsMarkAndParams() public view {
    IOracle.FeedData memory f = ext.getFeed(feedId);
    assertApproxEqRel(Oracle.mark(f), 3000e18, 0.0005e18, "seed mark = 3000");
    assertEq(f.flags, 0, "flags default unpaused");
    assertEq(f.sigma, 1e4, "sigma seeded from sample");
    assertEq(f.confidence, 5, "confidence stored");
    assertEq(f.maxDeviation, ext.MAX_DEV_THRESHOLD(), "maxDeviation seeded in feed slot");
    assertEq(f.sourceTs, 0, "sourceTs 0 until first signed push");
  }

  function test_addFeed_onlyAdmin() public {
    uint16 maxDev = ext.MAX_DEV_THRESHOLD();
    vm.prank(address(0xDEAD));
    vm.expectRevert(Err.NotOwner.selector);
    ext.addFeed(BASE, QUOTE, M.encodeB64(1e18, 18), 1e4, 5, maxDev, 3600);
  }

  // ─── per-feed push deviation band: config storage (enforcement lives in the signed-path tests) ───

  address constant DA = address(0xDA5E);
  address constant DB = address(0xDB5E);
  uint16 constant DEV_BAND = 500; // 5% in bps
  uint16 constant DEV_TTL = 3600;

  function _addBandedFeed(uint16 band) internal returns (bytes32 id) {
    ext.addFeed(DA, DB, M.encodeB64(100e18, 18), 1e4, 5, band, DEV_TTL);
    id = keccak256(abi.encodePacked(DA, DB));
  }

  function test_maxDeviation_storedAtAddFeed() public {
    bytes32 id = _addBandedFeed(DEV_BAND);
    assertEq(ext.getFeed(id).maxDeviation, DEV_BAND, "maxDeviation persisted at addFeed");
  }

  /// maxDeviation == 0 is FORBIDDEN at addFeed (H-1): the pool quotes off the raw mark, so every feed
  /// must declare a per-push bound. An unbounded feed can never be created.
  function test_maxDeviation_zero_rejectedAtAddFeed() public {
    vm.expectRevert(Err.InvalidInput.selector);
    ext.addFeed(DA, DB, M.encodeB64(100e18, 18), 1e4, 5, 0, DEV_TTL);
  }

  /// updateFeed likewise rejects a zero band.
  function test_maxDeviation_zero_rejectedAtUpdateFeed() public {
    vm.expectRevert(Err.InvalidInput.selector);
    ext.updateFeed(feedId, 0, DEV_TTL);
  }

  /// updateFeed persists maxDeviation (previously dropped — only emitted).
  function test_updateFeed_persistsMaxDeviation() public {
    ext.updateFeed(feedId, 300, DEV_TTL);
    assertEq(ext.getFeed(feedId).maxDeviation, 300, "updateFeed persisted maxDeviation");
    assertEq(ext.getFeed(feedId).ttl, DEV_TTL, "updateFeed persisted ttl");
  }

  function test_updateFeed_onlyAdmin() public {
    vm.prank(address(0xDEAD));
    vm.expectRevert(Err.NotOwner.selector);
    ext.updateFeed(feedId, 300, DEV_TTL);
  }
}
