// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {ExternalOracle} from "../../src/oracles/ExternalOracle.sol";
import {Oracle} from "../../src/libraries/Oracle.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {Err} from "@btr-shared/Errors.sol";
import {MockAC} from "../fixtures/BaseTestSetup.sol";

/// @notice Guardian fast-freeze on ExternalOracle. Root invariant: a guardian may only HALT / TIGHTEN /
///         CANCEL, never unhalt / loosen / grant — every reverse stays owner-only (onlyAdmin), and
///         AC.isGuardian is owner-set + instant-revocable (rogue-guardian bound). Money path.
contract ExternalOracleGuardianTest is Test {
  ExternalOracle ext;
  MockAC ac;
  address constant BASE = address(0xB05E);
  address constant QUOTE = address(0x9907E);
  address constant GUARDIAN = address(0x6A5D);
  address constant OUTSIDER = address(0xDEAD);
  uint16 constant TAU = 100;
  uint256 constant NXR_PK = 0xA11CE;
  uint256 constant NXR_PK2 = 0xB0B;
  uint256 constant NXR_PK3 = 0xCA401;
  bytes32 feedId;
  address nxr;
  uint16 startDev;

  function setUp() public {
    ac = new MockAC(address(this)); // this test contract = owner
    address[] memory initialSigners = new address[](3);
    initialSigners[0] = vm.addr(NXR_PK);
    initialSigners[1] = vm.addr(NXR_PK2);
    initialSigners[2] = vm.addr(NXR_PK3);
    ext = new ExternalOracle(address(ac), 600, initialSigners, 2);
    vm.warp(1_700_000_000);
    startDev = ext.MAX_DEV_THRESHOLD();
    ext.addFeed(BASE, QUOTE, M.encodeB64(3000e18, 18), 1e4, 5, startDev, 3600);
    feedId = keccak256(abi.encodePacked(BASE, QUOTE));
    nxr = vm.addr(NXR_PK);
    ac.setGuardian(GUARDIAN, true);
  }

  /// @dev External wrapper so expectRevert can observe Oracle.gate (the swap/quote safety entry).
  function gate(bytes32 id) external view returns (uint256) {
    return Oracle.gate(ext.getFeed(id));
  }

  // ─── guardian CAN halt / tighten / cancel ───

  function test_guardian_canRevokeSigner() public {
    vm.prank(GUARDIAN);
    ext.revokeSigner(nxr);
    assertFalse(ext.signers(nxr), "guardian removed leaked signer");
  }

  function test_guardian_canPauseFeed() public {
    vm.prank(GUARDIAN);
    ext.pauseFeed(feedId);
    assertFalse(ext.isFeedFresh(feedId), "paused feed reads not-fresh");
  }

  function test_guardian_canNarrowMaxDeviation() public {
    vm.prank(GUARDIAN);
    ext.narrowMaxDeviation(feedId, 500);
    assertEq(ext.getFeed(feedId).maxDeviation, 500, "guardian tightened band");
  }

  // ─── guardian CANNOT unhalt / loosen / grant (reverse powers = owner-only) ───

  function test_guardian_cannotRequestSignerGrant() public {
    vm.prank(GUARDIAN);
    vm.expectRevert(Err.NotOwner.selector);
    ext.requestSignerGrant(OUTSIDER);
  }

  function test_guardian_canCancelSignerGrant() public {
    ext.requestSignerGrant(OUTSIDER);
    vm.prank(GUARDIAN);
    ext.cancelSignerGrant();
    assertEq(ext.pendingSignerGrantOp(), 0);
  }

  function test_guardian_cannotUnpauseFeed() public {
    ext.pauseFeed(feedId); // owner pauses
    vm.prank(GUARDIAN);
    vm.expectRevert(Err.NotOwner.selector);
    ext.unpauseFeed(feedId);
  }

  function test_guardian_cannotWidenMaxDeviation() public {
    ext.narrowMaxDeviation(feedId, 1000); // owner narrows first
    vm.prank(GUARDIAN);
    vm.expectRevert(Err.InvalidInput.selector); // newDev == current → not strictly narrower
    ext.narrowMaxDeviation(feedId, 1000);
  }

  function test_guardian_cannotWidenAbove_startDev() public {
    vm.prank(GUARDIAN);
    vm.expectRevert(Err.InvalidInput.selector); // >= current
    ext.narrowMaxDeviation(feedId, startDev);
  }

  function test_narrowMaxDeviation_zeroReverts() public {
    vm.prank(GUARDIAN);
    vm.expectRevert(Err.InvalidInput.selector); // zero band = unbounded push = drain
    ext.narrowMaxDeviation(feedId, 0);
  }

  function test_outsider_cannotPause() public {
    vm.prank(OUTSIDER);
    vm.expectRevert(Err.NotAuth.selector);
    ext.pauseFeed(feedId);
  }

  // ─── fail-closed: paused feed must halt every priced/breaker path ───

  function test_pause_failsClosed_gateAndFresh() public {
    uint256 markBefore = M.b64To1e18(ext.getFeed(feedId).lastPriceB64);
    // pre-pause: gate returns the mark, feed reads fresh.
    assertEq(this.gate(feedId), markBefore, "gate ok pre-pause");
    assertTrue(ext.isFeedFresh(feedId), "fresh pre-pause");
    assertTrue(ext.isFeedFresh(feedId, 3600), "fresh(maxAge) pre-pause");

    vm.prank(GUARDIAN);
    ext.pauseFeed(feedId);

    // fail-closed even though the mark is still within ttl.
    vm.expectRevert(Err.FeedPaused.selector);
    this.gate(feedId);
    assertFalse(ext.isFeedFresh(feedId), "paused = not fresh (ttl overload)");
    assertFalse(ext.isFeedFresh(feedId, 3600), "paused = not fresh (maxAge overload)");

    // owner unpause restores pricing; stored mark unchanged (pause never zeroed the feed).
    ext.unpauseFeed(feedId);
    assertEq(this.gate(feedId), markBefore, "pricing resumes, mark unchanged");
    assertTrue(ext.isFeedFresh(feedId), "fresh again post-unpause");
  }

  // ─── owner can do everything ───

  function test_owner_fullPowers() public {
    ext.revokeSigner(nxr);
    assertFalse(ext.signers(nxr), "owner revoke");
    ext.pauseFeed(feedId);
    assertFalse(ext.isFeedFresh(feedId), "owner pause");
    ext.unpauseFeed(feedId);
    assertTrue(ext.isFeedFresh(feedId), "owner unpause");
    ext.narrowMaxDeviation(feedId, 250);
    assertEq(ext.getFeed(feedId).maxDeviation, 250, "owner narrow");
  }

  // ─── loosening asymmetry fix: widening maxDeviation / ttl is timelocked + guardian-vetoable ───

  /// @notice The bug this closes: `updateFeed` used to widen the per-push band to 20% and the ttl to
  ///         18h INSTANTLY, owner-only, unvetoable — while the tightening twins were guardian-able.
  function test_updateFeed_cannotWiden_eitherAxis() public {
    ext.narrowMaxDeviation(feedId, 200); // start from a tight band
    ext.updateFeed(feedId, 150, 1800); // tighten both axes: allowed, instant
    assertEq(ext.getFeed(feedId).maxDeviation, 150);
    assertEq(ext.getFeed(feedId).ttl, 1800);

    vm.expectRevert(Err.InvalidInput.selector);
    ext.updateFeed(feedId, 151, 1800); // band widen
    vm.expectRevert(Err.InvalidInput.selector);
    ext.updateFeed(feedId, 150, 1801); // ttl widen
    uint16 maxDev = ext.MAX_DEV_THRESHOLD();
    vm.expectRevert(Err.InvalidInput.selector);
    ext.updateFeed(feedId, maxDev, 65_534); // the old one-tx max-loosening
  }

  function test_widen_requiresTimelock_thenApplies() public {
    ext.updateFeed(feedId, 200, 1800);
    ext.requestFeedWiden(feedId, 400, 3600);

    // Not matured.
    vm.expectRevert(Err.NotReady.selector);
    ext.executeFeedWiden(feedId);
    assertEq(ext.getFeed(feedId).maxDeviation, 200, "widen leaked before eta");

    vm.warp(block.timestamp + ext.SIGNER_GOV_TIMELOCK() + 1);
    ext.executeFeedWiden(feedId);
    assertEq(ext.getFeed(feedId).maxDeviation, 400);
    assertEq(ext.getFeed(feedId).ttl, 3600);
  }

  function test_widen_guardianCanVeto() public {
    ext.updateFeed(feedId, 200, 1800);
    ext.requestFeedWiden(feedId, 400, 3600);

    vm.prank(GUARDIAN);
    ext.cancelFeedWiden(feedId);

    vm.warp(block.timestamp + ext.SIGNER_GOV_TIMELOCK() + 1);
    vm.expectRevert(Err.InvalidState.selector);
    ext.executeFeedWiden(feedId);
    assertEq(ext.getFeed(feedId).maxDeviation, 200, "vetoed widen applied anyway");
  }

  /// @notice Guardian may VETO but never DRIVE the loosening path.
  function test_widen_guardianCannotRequestOrExecute() public {
    vm.prank(GUARDIAN);
    vm.expectRevert(Err.NotOwner.selector);
    ext.requestFeedWiden(feedId, 400, 3600);

    ext.updateFeed(feedId, 200, 1800);
    ext.requestFeedWiden(feedId, 400, 3600);
    vm.warp(block.timestamp + ext.SIGNER_GOV_TIMELOCK() + 1);
    vm.prank(GUARDIAN);
    vm.expectRevert(Err.NotOwner.selector);
    ext.executeFeedWiden(feedId);
  }

  /// @notice A guardian tighten taken DURING the delay VOIDS the pending widen -- it is never
  ///         silently reverted by a stale payload. This is the whole point of the request-time snapshot.
  function test_widen_guardianNarrowDuringDelayVoidsIt() public {
    ext.updateFeed(feedId, 400, 3600);
    ext.requestFeedWiden(feedId, 400, 7200); // ttl-only loosening

    vm.prank(GUARDIAN);
    ext.narrowMaxDeviation(feedId, 100); // guardian tightens the band meanwhile

    vm.warp(block.timestamp + ext.SIGNER_GOV_TIMELOCK() + 1);
    vm.expectRevert(Err.InvalidState.selector);
    ext.executeFeedWiden(feedId);
    assertEq(ext.getFeed(feedId).maxDeviation, 100, "guardian narrow was reverted by widen");
    assertEq(ext.getFeed(feedId).ttl, 3600, "stale widen applied anyway");
  }

  function test_widen_rejectsNonLoosening_andDoubleQueue() public {
    ext.updateFeed(feedId, 200, 1800);
    vm.expectRevert(Err.InvalidInput.selector);
    ext.requestFeedWiden(feedId, 200, 1800); // no-op: use updateFeed
    vm.expectRevert(Err.InvalidInput.selector);
    ext.requestFeedWiden(feedId, 100, 900); // a tighten: use updateFeed

    ext.requestFeedWiden(feedId, 400, 1800);
    vm.expectRevert(abi.encodeWithSelector(Err.PendingTimelock.selector, uint48(block.timestamp)));
    ext.requestFeedWiden(feedId, 500, 1800); // no silent payload swap
  }

  function test_widen_stillBoundedByStructuralCaps() public {
    ext.updateFeed(feedId, 200, 1800);
    uint16 overCap = ext.MAX_DEV_THRESHOLD() + 1;
    uint16 lag = uint16(ext.maxRelayLagSecs());
    vm.expectRevert(Err.InvalidInput.selector);
    ext.requestFeedWiden(feedId, overCap, 1800);
    vm.expectRevert(Err.InvalidInput.selector);
    ext.requestFeedWiden(feedId, 400, lag); // ttl <= lag
  }

  // ─── rogue-guardian bound: instant owner revocation of the guardian role ───

  function test_guardianRevoked_losesPowers() public {
    ac.setGuardian(GUARDIAN, false);
    vm.prank(GUARDIAN);
    vm.expectRevert(Err.NotAuth.selector);
    ext.pauseFeed(feedId);
  }
}
