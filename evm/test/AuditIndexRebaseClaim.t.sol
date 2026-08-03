// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../src/interfaces/IPool.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {PoolIndexPinFixture} from "./PoolIndexPin.t.sol";
import {NO_DEADLINE} from "./fixtures/BaseTestSetup.sol";

/// @title AuditIndexRebaseClaimTest
/// @notice REVIEW ARTIFACT (delete with the migration). Pins the one property the migration exists
///         to preserve and that no existing test asserts: an LP who deposited BEFORE the repack has
///         a bit-identical claim (`shares*index/WAD`) after upgrade+rebase.
///         Also pins the negative: the 1e12 -> 1e18 `LIQUIDITY_INDEX_INIT` change must NOT be
///         applied to a live leg. It re-bases only newly-listed legs; rescaling a legacy leg's
///         index without rescaling its shares would multiply every claim by 1e6.
contract AuditIndexRebaseClaimTest is PoolIndexPinFixture {
  uint256 constant LEGACY_INDEX = 1e12; // old LIQUIDITY_INDEX_INIT
  uint256 constant LEGACY_MIN_LIQ = 0; // every live Sepolia leg: setAssetParams(..., 0, ...)
  uint256 constant LEGACY_LAST_UPDATE = 1_700_000_000;
  uint256 constant FACE = 10_000e18; // token face the legacy LP is owed

  function _assetSlot1(address t) internal pure returns (bytes32) {
    return bytes32(uint256(keccak256(abi.encode(t, uint256(3)))) + 1);
  }

  function _assetSlot0(address t) internal pure returns (bytes32) {
    return keccak256(abi.encode(t, uint256(3)));
  }

  function _lpBalSlot(address who, address t) internal pure returns (bytes32) {
    return keccak256(abi.encode(t, keccak256(abi.encode(who, uint256(7)))));
  }

  /// @dev Materialise the exact storage an OLD impl would have left: index at the 1e12 base, shares
  ///      minted against it (face*WAD/1e12 = face*1e6), liabilities = face, no dead seed.
  function _writeLegacyLeg() internal returns (uint256 legacyShares) {
    legacyShares = (FACE * WAD) / LEGACY_INDEX;
    uint256 word = LEGACY_MIN_LIQ | (LEGACY_INDEX << 128) | (LEGACY_LAST_UPDATE << 192)
      | (uint256(DEFAULT_PRESET) << 224);
    vm.store(address(pool), _assetSlot1(address(tok)), bytes32(word));
    vm.store(address(pool), _assetSlot0(address(tok)), bytes32(FACE | (FACE << 128)));
    vm.store(address(pool), _lpBalSlot(LP, address(tok)), bytes32(legacyShares));
    vm.store(address(pool), _lpBalSlot(address(0), address(tok)), bytes32(0));
  }

  function _rebase() internal returns (bool ok) {
    address[] memory legs = new address[](1);
    legs[0] = address(tok);
    vm.prank(OWNER);
    (ok,) = address(pool).call(abi.encodeWithSignature("adminRebaseIndexWidth(address[])", legs));
  }

  /// THE property. Claim before the repack == claim after upgrade+rebase, to the wei.
  function test_lp_claim_is_bit_exact_across_the_migration() public {
    uint256 shares = _writeLegacyLeg();
    // What the OLD impl reported: shares * oldIndex / WAD.
    uint256 claimPre = (shares * LEGACY_INDEX) / WAD;
    assertEq(claimPre, FACE, "sanity: the legacy LP is owed its face");

    // Post-upgrade, PRE-rebase: the field slid 128 -> 96, so the same word reads 2**32x.
    IPool.Asset memory a = pool.getAsset(address(tok));
    assertEq(uint256(a.liquidityIndex), LEGACY_INDEX << 32, "unrebased index reads shifted");
    uint256 claimUnrebased = (shares * uint256(a.liquidityIndex)) / WAD;
    assertEq(claimUnrebased, FACE * 2 ** 32, "unrebased: every share claims 2**32x its backing");
    assertGt(claimUnrebased, uint256(a.liabilities), "and the claim exceeds what the leg owes");

    assertTrue(_rebase(), "rebase");

    a = pool.getAsset(address(tok));
    uint256 claimPost = (shares * uint256(a.liquidityIndex)) / WAD;
    assertEq(claimPost, claimPre, "LP claim must be bit-exact across the migration");
    assertLe(claimPost, uint256(a.liabilities), "claim never exceeds liabilities");
  }

  /// Every other field in the repacked word survives untouched.
  function test_all_slot1_fields_are_bit_exact_after_rebase() public {
    _writeLegacyLeg();
    assertTrue(_rebase(), "rebase");
    IPool.Asset memory a = pool.getAsset(address(tok));
    assertEq(uint256(a.liquidityIndex), LEGACY_INDEX, "liquidityIndex restored");
    assertEq(uint256(a.minLiquidity), LEGACY_MIN_LIQ, "minLiquidity untouched");
    assertEq(uint256(a.lastUpdate), LEGACY_LAST_UPDATE, "lastUpdate untouched");
    assertEq(uint256(a.presetId), DEFAULT_PRESET, "presetId untouched");
  }

  /// The NEGATIVE the brief asked about: the rebase must NOT also apply 1e12 -> 1e18. A leg that
  /// was rescaled to the new base without rescaling its shares would owe 1e6x its liabilities.
  function test_rebase_must_not_rescale_to_the_new_index_base() public {
    uint256 shares = _writeLegacyLeg();
    assertTrue(_rebase(), "rebase");
    IPool.Asset memory a = pool.getAsset(address(tok));
    assertEq(uint256(a.liquidityIndex), LEGACY_INDEX, "legacy legs KEEP the 1e12 base");
    assertTrue(uint256(a.liquidityIndex) != C.LIQUIDITY_INDEX_INIT, "not rebased to WAD");
    // Had it rescaled, this is what the leg would have owed.
    assertEq(
      (shares * C.LIQUIDITY_INDEX_INIT) / WAD, FACE * 1e6, "a rescale would 1e6x every claim"
    );
  }

  /// A real withdraw against the rebased legacy leg returns the face, not 2**32x it.
  function test_legacy_lp_can_withdraw_its_face_after_rebase() public {
    _writeLegacyLeg();
    tok.mint(address(pool), FACE); // back the legacy liabilities with real reserves
    assertTrue(_rebase(), "rebase");
    uint256 shares = pool.getLPBalance(LP, address(tok));
    uint256 before = tok.balanceOf(LP);
    vm.prank(LP);
    pool.withdraw(address(tok), shares, 0, NO_DEADLINE);
    assertEq(tok.balanceOf(LP) - before, FACE, "legacy LP withdraws exactly its face");
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // THE BLOCKER. Reproduces the shape of 30 of the 33 legs actually live on Sepolia
  // (verified via eth_call against 11155111): `liquidityIndex == 0` IN STORAGE, with real
  // reserves, real liabilities and a real LP balance. The DEPLOYED impl lazy-inits a 0 index
  // to 1e12, which is why `previewWithdraw(DAI, 1e18)` returns 1e12 today and the deployer's
  // 5e28 DAI shares are worth exactly the leg's 50_000e18 liabilities.
  // This impl redefines 0 as "written down to a total loss, terminal", so the rebase must WRITE
  // the legacy base back rather than skip: nothing downstream can restore it (every index writer
  // multiplies an existing value, and `mintIndex` fails closed at 0).
  // ─────────────────────────────────────────────────────────────────────────────

  /// @dev The live shape: index 0 in storage, shares outstanding against real liabilities.
  function _writeLazyInitLeg() internal returns (uint256 shares) {
    shares = (FACE * WAD) / LEGACY_INDEX; // what the live impl minted at its lazy 1e12
    uint256 word =
      LEGACY_MIN_LIQ | (0 << 128) | (LEGACY_LAST_UPDATE << 192) | (uint256(DEFAULT_PRESET) << 224);
    vm.store(address(pool), _assetSlot1(address(tok)), bytes32(word));
    vm.store(address(pool), _assetSlot0(address(tok)), bytes32(FACE | (FACE << 128)));
    vm.store(address(pool), _lpBalSlot(LP, address(tok)), bytes32(shares));
    vm.store(address(pool), _lpBalSlot(address(0), address(tok)), bytes32(0));
    tok.mint(address(pool), FACE); // reserves really are there
  }

  /// The rebase must restore a zero-index leg to the base the deployed impl was reading for it.
  function test_BLOCKER_rebase_restores_the_lazy_init_legs() public {
    _writeLazyInitLeg();
    assertTrue(_rebase(), "rebase runs");
    assertEq(
      uint256(pool.getAsset(address(tok)).liquidityIndex),
      LEGACY_INDEX,
      "a lazy-init leg must come out of the rebase at the legacy base, not at zero"
    );
  }

  /// The property, on the shape that is actually live: claim bit-exact across the migration.
  function test_BLOCKER_lazy_init_lp_claim_is_bit_exact() public {
    uint256 shares = _writeLazyInitLeg();
    // What the DEPLOYED impl reports today, lazy-initing the stored 0.
    uint256 claimPre = (shares * LEGACY_INDEX) / WAD;
    assertEq(claimPre, FACE, "sanity: the live LP is owed its face today");

    assertTrue(_rebase(), "rebase");

    (uint256 claimPost,) = pool.previewWithdraw(address(tok), shares);
    assertEq(claimPost, claimPre, "claim must be bit-exact across the migration");
    uint256 before = tok.balanceOf(LP);
    vm.prank(LP);
    pool.withdraw(address(tok), shares, 0, NO_DEADLINE);
    assertEq(tok.balanceOf(LP) - before, FACE, "and the LP really withdraws its face");
  }

  /// ...and the leg is still live: every credit path works again.
  function test_BLOCKER_lazy_init_leg_stays_usable_after_rebase() public {
    _writeLazyInitLeg();
    assertTrue(_rebase(), "rebase");
    tok.mint(OWNER, 10e18);
    vm.startPrank(OWNER);
    tok.approve(address(pool), type(uint256).max);
    pool.deposit(address(tok), 1e18);
    pool.donate(address(tok), 1e18);
    vm.stopPrank();
    assertGt(pool.getLPBalance(OWNER, address(tok)), 0, "a post-rebase deposit mints");
    assertGt(uint256(pool.getAsset(address(tok)).liquidityIndex), 0, "leg is not terminal");
  }

  /// The negative the revival must not cross: a leg that was REALLY written down stays terminal.
  /// Both writers that can reach index 0 scale by `newLiabilities/oldLiabilities`, so a wipe leaves
  /// `liabilities == 0`, and no credit path can put liabilities back while the index is 0.
  function test_a_genuinely_wiped_leg_is_not_revived() public {
    uint256 shares = (FACE * WAD) / LEGACY_INDEX;
    uint256 word =
      LEGACY_MIN_LIQ | (0 << 128) | (LEGACY_LAST_UPDATE << 192) | (uint256(DEFAULT_PRESET) << 224);
    vm.store(address(pool), _assetSlot1(address(tok)), bytes32(word));
    vm.store(address(pool), _assetSlot0(address(tok)), bytes32(0)); // reserves 0, liabilities 0
    vm.store(address(pool), _lpBalSlot(LP, address(tok)), bytes32(shares)); // stale shares
    assertTrue(_rebase(), "rebase runs");
    assertEq(
      uint256(pool.getAsset(address(tok)).liquidityIndex),
      0,
      "a wiped leg must stay terminal: reviving it would arm stale shares against new money"
    );
  }

  /// Sequence violation: the rebase is the ONLY thing standing between the upgrade and a 2**32x
  /// over-claim, and an unrebased leg is actively drainable by its own LP.
  function test_unrebased_leg_lets_an_lp_overdraw() public {
    _writeLegacyLeg();
    tok.mint(address(pool), FACE * 16); // pretend the leg is well funded
    uint256 shares = pool.getLPBalance(LP, address(tok));
    // No rebase. The withdraw-side guard is `withdrawValue > liabilities`, so the over-claim is
    // caught HERE by the liabilities check rather than paying out - but the leg is bricked for
    // its LP either way, and any leg whose liabilities were inflated is drainable.
    vm.prank(LP);
    vm.expectRevert();
    pool.withdraw(address(tok), shares, 0, NO_DEADLINE);
  }
}
