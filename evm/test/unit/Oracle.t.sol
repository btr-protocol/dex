// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {BaseTestSetup} from "../fixtures/BaseTestSetup.sol";
import {Oracle} from "../../src/libraries/Oracle.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Constants as C} from "../../src/libraries/Constants.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @title LibOracleTest
/// @notice Unit tests for the external-mark oracle lib: mark decode, single σ, σ-EMA fold, and
///         the synthetic base feed.
contract LibOracleTest is BaseTestSetup {
  // ─── mark ───

  function test_mark_returns_lastPrice_1e18() public view {
    IOracle.FeedData memory f = makeFeedData(M.encodeB64(3000e18, 18), VOL_1_PCT, 5);
    assertApproxEqRel(Oracle.mark(f), 3000e18, 0.0001e18, "mark = b64To1e18(lastPrice)");
  }

  // ─── getPegFeed (unit peg / base-numeraire stand-in) ───

  function test_getPegFeed_isUnitAndNeverExpires() public view {
    IOracle.FeedData memory f = Oracle.getPegFeed(M.encodeB64(SC.WAD, 18), uint32(SC.ONE_PCT_PBPS));
    assertApproxEqRel(Oracle.mark(f), SC.WAD, 0.0001e18, "peg mark = 1.0");
    assertEq(uint256(f.sigma), SC.ONE_PCT_PBPS, "peg sigma = 1%");
    assertEq(f.ttl, type(uint16).max, "peg never expires");
    assertEq(f.confidence, 0, "peg has no CI");
  }

  // ─── markMovePbps (signed-path σ floor magnitude) ───

  function test_markMovePbps_zeroOnFlat() public pure {
    assertEq(Oracle.markMovePbps(3000e18, 3000e18), 0, "no move = 0");
  }

  function test_markMovePbps_capsAtMaxSigma() public pure {
    assertEq(Oracle.markMovePbps(1e18, 1e30), C.MAX_SIGMA_PBPS, "huge move caps at MAX_SIGMA_PBPS");
  }

  function test_gate_unsigned_feed_same_block_ok() public view {
    // sourceTs==0 (MockOracle / addFeed seed / INTERNAL peg): ORA-MEV delay does not apply.
    IOracle.FeedData memory f = makeFeedData(M.encodeB64(1e18, 18), VOL_1_PCT, 0);
    assertEq(Oracle.gate(f), 1e18);
  }

  function gateExt(IOracle.FeedData memory f) external view returns (uint256) {
    return Oracle.gate(f);
  }

  function test_gate_signed_feed_same_block_cooldown() public {
    IOracle.FeedData memory f = makeFeedData(M.encodeB64(1e18, 18), VOL_1_PCT, 0);
    f.sourceTs = uint48(block.timestamp * 1000);
    f.updatedAt = uint32(block.timestamp);
    vm.expectRevert(abi.encodeWithSelector(Err.CooldownActive.selector, uint32(1)));
    this.gateExt(f);
  }
}
