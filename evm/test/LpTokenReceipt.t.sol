// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {Admin} from "../src/Admin.sol";
import {Flash} from "../src/Flash.sol";
import {LPToken} from "../src/LPToken.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {BaseTestSetup, MockAC, MockOracle, NO_DEADLINE} from "./fixtures/BaseTestSetup.sol";

/// @notice The ERC-4626 shape the account-keyed cooldown could not survive: it accepts
///         permissionless deposits, so anyone can cause a mint into its address.
contract PooledWrapper {
  Pool immutable pool;
  MockERC20 immutable asset;

  constructor(Pool p, MockERC20 a) {
    pool = p;
    asset = a;
    a.approve(address(p), type(uint256).max);
  }

  function deposit(uint256 amount) external {
    asset.transferFrom(msg.sender, address(this), amount);
    pool.deposit(address(asset), amount);
  }

  function moveShares(LPToken lp, address to, uint256 amount) external {
    lp.transfer(to, amount);
  }
}

/// @title LpTokenReceiptTest
/// @notice Behaviour of the per-leg ERC-20 receipt: supply accounting including the unburnable dead
///         seed, the frozen-amount anti-JIT lock, the address(0) policy, and share movement being
///         reconstructible from `Transfer` alone.
contract LpTokenReceiptTest is BaseTestSetup {
  Admin admin;
  MockAC ac;
  MockOracle oracle;
  Pool pool;
  MockERC20 base; // numeraire AND wnative, so the native sentinel aliases this leg
  MockERC20 tok;
  LPToken lpTok;
  LPToken lpBase;

  address constant OWNER = address(0xA11CE);
  address constant LP = address(0x11D);
  address constant BOB = address(0xB0B);
  uint256 constant PX = 3000e18;
  uint256 constant DEAD_SEED_LP = 1e18 / 1000; // 0.001 token at the WAD index base
  bytes32 constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

  function _risk() internal pure returns (IPool.RiskConfig memory r) {
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20000;
    r.depthAmplifier = 10000;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
  }

  function _addAsset(address t) internal {
    IPool.OracleConfig memory ocfg = externalOracleCfg(oracle, t);
    vm.prank(OWNER);
    admin.addAsset(
      address(pool), t, ocfg, _risk(), DEFAULT_PRESET, 1000, 18, 1000, 100000, 10000, 10000
    );
  }

  function setUp() public override {
    ac = new MockAC(OWNER);
    admin = new Admin(address(ac));
    Flash flash = new Flash();
    PoolAux aux = new PoolAux(address(ac), address(admin), address(flash));
    Pool impl = new Pool(address(ac), address(admin), address(flash), address(aux));
    PoolFactory factory = new PoolFactory(address(impl), address(this), address(ac));

    base = new MockERC20("Wrapped Native", "WNATIVE", 18);
    tok = new MockERC20("Token", "TOK", 18);
    address[] memory toks = new address[](2);
    toks[0] = address(base);
    toks[1] = address(tok);
    IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 25, flashFeePbps: 100});
    // wnative == base: `PoolIO.wrap` maps the native sentinel onto this leg.
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, address(base), address(base), fp);
    pool = Pool(payable(factory.createPool(address(base), toks, initdata)));

    oracle = new MockOracle();
    oracle.setFeed(
      bytes32(uint256(uint160(address(base)))),
      M.encodeB64(1e18, 18),
      VOL_1_PCT,
      0,
      type(uint16).max
    );
    oracle.setFeed(
      bytes32(uint256(uint160(address(tok)))), M.encodeB64(PX, 18), VOL_1_PCT, 0, type(uint16).max
    );

    vm.prank(OWNER);
    admin.setCurve(address(pool), DEFAULT_PRESET, defaultCurveInterior(), defaultCurveWQ(), 1000, 0);
    _addAsset(address(base));
    _addAsset(address(tok));
    lpBase = LPToken(pool.lpToken(address(base)));
    lpTok = LPToken(pool.lpToken(address(tok)));

    for (uint256 i = 0; i < 3; ++i) {
      address who = [LP, BOB, address(this)][i];
      base.mint(who, 10_000_000e18);
      tok.mint(who, 10_000_000e18);
      vm.startPrank(who);
      base.approve(address(pool), type(uint256).max);
      tok.approve(address(pool), type(uint256).max);
      vm.stopPrank();
    }
    // Depth on the output leg so the cross-asset path can pay out.
    pool.deposit(address(base), 1_000_000e18);
  }

  // ── listing ──────────────────────────────────────────────────────────────

  function test_the_native_leg_maps_to_one_receipt() public view {
    assertEq(
      pool.lpToken(SC.NATIVE), address(lpBase), "native sentinel resolves to the wnative leg"
    );
    assertEq(lpBase.asset(), address(base), "one receipt per WRAPPED leg, not per alias");
    assertTrue(address(lpBase) != address(lpTok), "one receipt per leg");
  }

  function test_receipt_metadata_tracks_the_leg() public view {
    assertEq(lpTok.symbol(), "bLP-TOK");
    assertEq(lpTok.name(), "BTR LP: TOK");
    assertEq(lpTok.decimals(), 18, "receipt decimals mirror the underlying at the WAD index base");
    assertEq(lpTok.pool(), address(pool));
  }

  function test_only_the_pool_may_mint_or_burn() public {
    vm.expectRevert(Err.NotAuth.selector);
    lpTok.mint(BOB, 1e18);
    vm.expectRevert(Err.NotAuth.selector);
    lpTok.burn(LP, 1);
  }

  // ── supply ───────────────────────────────────────────────────────────────

  /// The dead seed is credited to address(0) at the first liability credit. It must be REAL supply:
  /// a raw balance write would leave `totalSupply` short by the seed, and every ERC-4626 wrapper
  /// dividing by `totalSupply` would overstate NAV per share by exactly that amount.
  function test_dead_shares_count_in_total_supply() public {
    vm.prank(LP);
    pool.deposit(address(tok), 1000e18);

    uint256 dead = lpTok.balanceOf(address(0));
    assertEq(dead, DEAD_SEED_LP, "the leg was seeded");
    assertEq(lpTok.totalSupply(), lpTok.balanceOf(LP) + dead, "supply covers the seed");
    assertEq(lpTok.totalSupply(), 1000e18, "supply equals the credited value at the WAD base");
    assertLe(
      (lpTok.totalSupply() * pool.getAsset(address(tok)).liquidityIndex) / WAD,
      pool.getAsset(address(tok)).liabilities,
      "totalSupply * index / WAD <= liabilities"
    );

    // Seeded once, not per deposit.
    skip(60);
    vm.prank(BOB);
    pool.deposit(address(tok), 500e18);
    assertEq(lpTok.balanceOf(address(0)), dead, "the seed is one-time per leg");
  }

  /// address(0) is the leg's permanent pin floor, not a burn sink. Letting a holder transfer there
  /// would raise that floor with LP money, irreversibly, and make the seed unauditable.
  function test_a_transfer_to_address_zero_is_refused() public {
    vm.prank(LP);
    pool.deposit(address(tok), 1000e18);
    skip(uint256(C.DEFAULT_FLOW_COOLDOWN) + 1);

    uint256 dead = lpTok.balanceOf(address(0));
    vm.prank(LP);
    vm.expectRevert(Err.ZeroAddr.selector);
    lpTok.transfer(address(0), 1e18);

    vm.prank(LP);
    lpTok.approve(BOB, type(uint256).max);
    vm.prank(BOB);
    vm.expectRevert(Err.ZeroAddr.selector);
    lpTok.transferFrom(LP, address(0), 1e18);

    assertEq(lpTok.balanceOf(address(0)), dead, "the dead pile cannot grow");

    // Redeeming still burns to address(0) in the ERC-20 sense: supply falls, the pile does not rise.
    uint256 supply = lpTok.totalSupply();
    vm.prank(LP);
    pool.withdraw(address(tok), 1e18, 0, NO_DEADLINE);
    assertEq(lpTok.totalSupply(), supply - 1e18, "burn reduces supply");
    assertEq(lpTok.balanceOf(address(0)), dead, "burn does not credit address(0)");
  }

  // ── the frozen-amount lock ───────────────────────────────────────────────

  function test_the_lock_blocks_a_transfer_within_the_cooldown() public {
    vm.prank(LP);
    pool.deposit(address(tok), 1000e18);
    uint256 held = lpTok.balanceOf(LP);

    vm.prank(LP);
    vm.expectRevert();
    lpTok.transfer(BOB, held);

    // Transferring out is the same exit as burning, so the lock must gate both.
    vm.prank(LP);
    vm.expectRevert();
    pool.withdraw(address(tok), held, 0, NO_DEADLINE);

    skip(uint256(C.DEFAULT_FLOW_COOLDOWN) + 1);
    vm.prank(LP);
    lpTok.transfer(BOB, held);
    assertEq(lpTok.balanceOf(BOB), held, "the window elapsed");
  }

  /// Receiving shares does NOT arm a lock: only a mint does. Otherwise a 1-wei transfer would be a
  /// targeted freeze of any address.
  function test_a_received_balance_is_not_locked() public {
    vm.prank(LP);
    pool.deposit(address(tok), 1000e18);
    skip(uint256(C.DEFAULT_FLOW_COOLDOWN) + 1);
    uint256 held = lpTok.balanceOf(LP);

    vm.prank(LP);
    lpTok.transfer(BOB, held);
    vm.prank(BOB);
    lpTok.transfer(LP, held);
    assertEq(lpTok.balanceOf(LP), held, "a transfer never stamps the recipient");
  }

  function test_the_lock_allows_an_aged_balance_while_a_fresh_mint_is_locked() public {
    vm.prank(LP);
    pool.deposit(address(tok), 1000e18);
    uint256 aged = lpTok.balanceOf(LP);
    skip(3600);

    vm.prank(LP);
    pool.deposit(address(tok), 5e18);
    uint256 fresh = lpTok.balanceOf(LP) - aged;
    (, uint224 frozen) = lpTok.locks(LP);
    assertEq(frozen, fresh, "the lock freezes the minted AMOUNT, not the account");

    vm.prank(LP);
    lpTok.transfer(BOB, aged);
    assertEq(lpTok.balanceOf(LP), fresh, "the aged parcel moves freely");

    vm.prank(LP);
    vm.expectRevert();
    lpTok.transfer(BOB, fresh);
  }

  /// The whole reason the lock is keyed to the amount rather than the account: one dust deposit per
  /// window into a pooled wrapper would otherwise freeze every other depositor's balance in it, for
  /// about $75/day, permanently, at no risk to the griefer.
  function test_a_dust_deposit_cannot_freeze_a_wrapper() public {
    PooledWrapper w = new PooledWrapper(pool, tok);
    vm.startPrank(LP);
    tok.approve(address(w), type(uint256).max);
    w.deposit(1000e18);
    vm.stopPrank();
    uint256 pooled = lpTok.balanceOf(address(w));
    skip(3600);

    // The griefer spends their own dust to cause a mint into the wrapper's address.
    vm.startPrank(BOB);
    tok.approve(address(w), type(uint256).max);
    w.deposit(1e15);
    vm.stopPrank();
    uint256 dust = lpTok.balanceOf(address(w)) - pooled;
    assertGt(dust, 0, "the griefing mint landed");

    // Every pre-existing depositor still redeems. Only the dust is held.
    w.moveShares(lpTok, LP, pooled);
    assertEq(lpTok.balanceOf(address(w)), dust, "the dust is frozen, the wrapper is not");
    vm.expectRevert();
    w.moveShares(lpTok, LP, dust);
  }

  /// swapLiability rebalances the position; the destination shares are a fresh mint and carry a
  /// fresh window, so the round trip cannot exit earlier than the original deposit could have.
  function test_swap_liability_arms_the_destination_lock() public {
    vm.prank(LP);
    pool.deposit(address(tok), 1000e18);
    skip(uint256(C.DEFAULT_FLOW_COOLDOWN) + 1);

    uint256 held = lpTok.balanceOf(LP);
    vm.prank(LP);
    uint256 out = pool.swapLiability(address(tok), address(base), held, 0, NO_DEADLINE);
    assertEq(lpTok.balanceOf(LP), 0, "the in-leg receipt is burned");
    assertEq(lpBase.balanceOf(LP), out, "the out-leg receipt is minted");

    vm.prank(LP);
    vm.expectRevert();
    pool.withdraw(address(base), out, 0, NO_DEADLINE);
  }

  // ── events ───────────────────────────────────────────────────────────────

  /// The cross-asset withdraw burns fromTk shares and pays out toTk, so no single `Withdrawn` log
  /// can carry both sides: it reports `lpAmount = 0` against the output leg by design. The receipt
  /// `Transfer` is what makes share positions reconstructible from logs, and it must be emitted on
  /// the INPUT leg's receipt only.
  function test_cross_asset_withdraw_logs_the_burn_on_the_input_receipt() public {
    vm.prank(LP);
    pool.deposit(address(tok), 1000e18);
    skip(uint256(C.DEFAULT_FLOW_COOLDOWN) + 1);
    uint256 held = lpTok.balanceOf(LP);

    vm.recordLogs();
    vm.prank(LP);
    pool.withdrawTo(address(tok), address(base), held, 0, NO_DEADLINE);
    Vm.Log[] memory logs = vm.getRecordedLogs();

    uint256 seenIn;
    uint256 seenOut;
    for (uint256 i; i < logs.length; ++i) {
      if (logs[i].topics[0] != TRANSFER_TOPIC) continue;
      if (logs[i].emitter == address(lpBase)) ++seenOut;
      if (logs[i].emitter != address(lpTok)) continue;
      ++seenIn;
      assertEq(address(uint160(uint256(logs[i].topics[1]))), LP, "burned from the holder");
      assertEq(address(uint160(uint256(logs[i].topics[2]))), address(0), "burned to address(0)");
      assertEq(abi.decode(logs[i].data, (uint256)), held, "the full fromTk share amount");
    }
    assertEq(seenIn, 1, "exactly one burn, on the input leg's receipt");
    assertEq(seenOut, 0, "no output-leg share moved");
    assertEq(lpTok.balanceOf(LP), 0, "position closed");
  }
}
