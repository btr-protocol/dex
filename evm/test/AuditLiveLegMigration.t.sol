// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../src/interfaces/IPool.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {PoolIndexPinFixture} from "./PoolIndexPin.t.sol";
import {NO_DEADLINE} from "./fixtures/BaseTestSetup.sol";

/// @title AuditLiveLegMigrationTest
/// @notice The shape that killed the previous #73 attempt. Every leg already deployed has real LP
///         shares and `lpBalances[address(0)] == 0`, because the old impl never minted a seed. A
///         fix that gates `raiseIndex` on the dead balance therefore FREEZES the index on every
///         live leg at upgrade while `accrueLpFee` keeps booking into `liabilities`, and the freeze
///         is one-directional: decay and write-down are ungated, so a live leg can still lose value
///         and never gain. These tests pin the requirement that no such window exists.
contract AuditLiveLegMigrationTest is PoolIndexPinFixture {
  /// @dev lpBalances is PoolStorage field #7: mapping(user => mapping(token => uint256)).
  function _zeroDeadBalance(address t) internal {
    bytes32 outer = keccak256(abi.encode(address(0), uint256(7)));
    vm.store(address(pool), keccak256(abi.encode(t, outer)), bytes32(0));
  }

  /// @dev Pre-upgrade state: real shares outstanding, no dead seed anywhere.
  function _liveLeg() internal {
    vm.prank(LP);
    pool.deposit(address(tok), 10_000e18);
    _zeroDeadBalance(address(tok));
    assertEq(_dead(), 0, "emulated pre-upgrade leg");
    assertGt(pool.getLPBalance(LP, address(tok)), 0, "real LP shares outstanding");
  }

  /// Donate to a LIVE leg after upgrade: the index must rise, and the live LP must earn it.
  function test_live_leg_donate_still_credits_lps() public {
    _liveLeg();
    uint256 idx0 = _idx();
    uint256 lp = pool.getLPBalance(LP, address(tok));
    (uint256 valBefore,) = pool.previewWithdraw(address(tok), lp);

    vm.prank(ATTACKER);
    pool.donate(address(tok), 1_000e18);

    (uint256 valAfter,) = pool.previewWithdraw(address(tok), lp);
    emit log_named_uint("LP claim gained", valAfter - valBefore);
    assertGt(_idx(), idx0, "index must rise on a live leg the upgrade has not yet seeded");
    assertGt(valAfter, valBefore, "the live LP earns the donation");
  }

  /// Swap fees on a LIVE leg after upgrade: `accrueLpFee` books liabilities, the index must follow.
  function test_live_leg_swap_fees_still_reach_lp_claim() public {
    _seedLps();
    _liveLeg();
    uint256 idx0 = _idx();
    uint256 liab0 = _liab();
    uint256 lp = pool.getLPBalance(LP, address(tok));
    (uint256 valBefore,) = pool.previewWithdraw(address(tok), lp);

    _churn();

    (uint256 valAfter,) = pool.previewWithdraw(address(tok), lp);
    emit log_named_uint("fees booked into liabilities", _liab() - liab0);
    assertGt(_liab(), liab0, "precondition: fees were booked");
    assertGt(_idx(), idx0, "swap fees must move the index on an unseeded live leg");
    assertGt(valAfter, valBefore, "swap fees must reach the live LP's claim");
  }

  /// The migration itself: one donate per leg, batched into the upgrade transaction, seeds the leg
  /// and credits the existing LPs with the remainder. Nothing is stranded, nothing is frozen.
  function test_migration_donate_seeds_a_live_leg() public {
    _liveLeg();
    uint256 lp = pool.getLPBalance(LP, address(tok));
    (uint256 valBefore,) = pool.previewWithdraw(address(tok), lp);

    tok.mint(OWNER, 1e18);
    vm.startPrank(OWNER);
    tok.approve(address(pool), type(uint256).max);
    pool.donate(address(tok), 1e18); // the one-shot seeding call
    vm.stopPrank();

    assertGt(_dead(), 0, "leg is seeded");
    // Claim, not shares: the same donation raises the index afterwards, so the seed's claim ends
    // marginally above the constant it was minted at.
    assertGe(_deadClaim(), DEAD_SEED, "seed claim is the constant, taken out of the donation");
    assertLt(_deadClaim(), DEAD_SEED * 2, "and the seed is not scaled by the donation");
    (uint256 valAfter,) = pool.previewWithdraw(address(tok), lp);
    assertGt(valAfter, valBefore, "the rest of the seeding donation goes to the existing LPs");
    assertLe(
      ((lp + _dead()) * _idx()) / WAD, _liab(), "total claim never exceeds liabilities post-seed"
    );
  }

  /// Once seeded, the live leg is priced exactly like a fresh one: the ratchet has to carry a floor.
  function test_seeded_live_leg_is_no_longer_free_to_ratchet() public {
    _liveLeg();
    vm.prank(ATTACKER);
    pool.donate(address(tok), 1e18); // seeds
    uint256 idx0 = _idx();
    uint256 bal0 = tok.balanceOf(ATTACKER);

    for (uint256 i = 0; i < 40; ++i) {
      _skipCooldown();
      uint256 liab = _liab();
      if (liab == 0 || liab > 1e30) break;
      _tryDonate(ATTACKER, address(tok), liab);
    }
    uint256 grown = _idx() / idx0;
    uint256 bal1 = tok.balanceOf(ATTACKER);
    uint256 spent = bal0 > bal1 ? bal0 - bal1 : 0;
    emit log_named_uint("index multiple bought", grown);
    emit log_named_uint("net tokens spent", spent);
    assertGe(spent, (DEAD_SEED * (grown - 1)) / 2, "the ratchet must cost the floor it lifts");
  }

  /// STORAGE MIGRATION, and the reason there has to be one. `minLiquidity(128)+liquidityIndex(64)`
  /// became `minLiquidity(96)+liquidityIndex(96)`: the two keep their 192-bit boundary, so
  /// `lastUpdate` and `presetId` never move, but the index field's LOW bit slides 128 -> 96, so a
  /// word written by the old impl reads back as `oldIndex << 32`. Every share would claim 2**32x its
  /// backing until `adminRebaseIndexWidth` runs, which is why it is batched into the upgrade tx.
  function test_legacy_asset_word_requires_the_index_rebase() public {
    uint256 legacyMinLiq = 5_000e18;
    uint256 legacyIndex = 1e12;
    uint256 legacyLastUpdate = 1_700_000_000;
    uint256 legacyPreset = DEFAULT_PRESET;
    uint256 word =
      legacyMinLiq | (legacyIndex << 128) | (legacyLastUpdate << 192) | (legacyPreset << 224);
    bytes32 slot1 = bytes32(uint256(keccak256(abi.encode(address(tok), uint256(3)))) + 1);
    vm.store(address(pool), slot1, bytes32(word));

    IPool.Asset memory a = pool.getAsset(address(tok));
    assertEq(uint256(a.minLiquidity), legacyMinLiq, "minLiquidity survives the repack");
    assertEq(uint256(a.lastUpdate), legacyLastUpdate, "lastUpdate does not move");
    assertEq(uint256(a.presetId), legacyPreset, "presetId does not move");
    assertEq(uint256(a.liquidityIndex), legacyIndex << 32, "the index reads shifted until rebased");

    address[] memory legs = new address[](1);
    legs[0] = address(tok);
    vm.prank(OWNER);
    (bool ok,) =
      address(pool).call(abi.encodeWithSignature("adminRebaseIndexWidth(address[])", legs));
    assertTrue(ok, "adminRebaseIndexWidth");

    a = pool.getAsset(address(tok));
    assertEq(uint256(a.liquidityIndex), legacyIndex, "rebase restores the pre-upgrade index");
    assertEq(uint256(a.minLiquidity), legacyMinLiq, "rebase leaves the reserve floor alone");
    assertEq(uint256(a.lastUpdate), legacyLastUpdate, "rebase leaves lastUpdate alone");

    vm.prank(OWNER);
    (ok,) = address(pool).call(abi.encodeWithSignature("adminRebaseIndexWidth(address[])", legs));
    assertFalse(ok, "rebase must not be runnable twice");
  }

  /// The rebase rewrites the sole share↔value converter, so it is owner-only.
  function test_index_rebase_is_owner_only() public {
    address[] memory legs = new address[](1);
    legs[0] = address(tok);
    vm.prank(ATTACKER);
    (bool ok,) =
      address(pool).call(abi.encodeWithSignature("adminRebaseIndexWidth(address[])", legs));
    assertFalse(ok, "non-owner must not rebase the index");
  }

  /// The reserve floor is the field that shrank, so its new ceiling has to be enforced at the write
  /// rather than wrapped: a wrapped floor silently unblocks every outflow gate.
  function test_minLiquidity_above_the_new_width_is_rejected() public {
    vm.prank(OWNER);
    vm.expectRevert();
    admin.setAssetParams(
      address(pool), address(tok), uint128(type(uint96).max) + 1, 1000, 10000, 10000, 10000, 0, 0, 0
    );
  }
}
