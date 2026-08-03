// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {Admin} from "../src/Admin.sol";
import {Flash} from "../src/Flash.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {BaseTestSetup, MockAC, MockOracle, NO_DEADLINE} from "./fixtures/BaseTestSetup.sol";

/// @title PoolIndexPinFixture
/// @dev Two-leg pool, one honest LP, one attacker. `tok` is the victim leg and is deliberately left
///      virgin (listed, never credited) so the pre-first-credit window is reachable in every test.
///      Every read of `liquidityIndex` widens to uint256 and every ceiling is expressed as a
///      MULTIPLE of the leg's own starting index, so the suite compiles and means the same thing
///      against both the unfixed (uint64 field, 1e12 base) and fixed (uint96, WAD base) source.
abstract contract PoolIndexPinFixture is BaseTestSetup {
  Admin admin;
  MockAC ac;
  MockOracle oracle;
  Pool pool;
  MockERC20 base; // numeraire, 18d
  MockERC20 tok; // spoke, 18d, mark 3000

  address constant OWNER = address(0xA11CE);
  address constant ATTACKER = address(0xBAD);
  address constant LP = address(0x11D);
  uint256 constant PX = 3000e18;

  /// @dev Dead seed for an 18-decimal leg: 10**decimals / DEAD_SHARE_SEED_DIV.
  uint256 constant DEAD_SEED = 1e18 / 1000;

  /// @dev Emitted by the fixed source only; declared here so the suite compiles against both.
  event DeadSharesSeeded(address indexed token, uint256 value, uint256 lpAmount);

  function _risk() internal pure returns (IPool.RiskConfig memory r) {
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20000;
    r.decaySlope = 0;
    r.depthAmplifier = 10000;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
  }

  function _feedId(address token) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(token)));
  }

  function _addAsset(address t, uint8 dec) internal {
    // Built BEFORE the prank: externalOracleCfg deploys a mirror oracle, which would eat it.
    IPool.OracleConfig memory ocfg = externalOracleCfg(oracle, t);
    vm.prank(OWNER);
    admin.addAsset(
      address(pool), t, ocfg, _risk(), DEFAULT_PRESET, 1000, dec, 1000, 100000, 10000, 10000
    );
  }

  function setUp() public override {
    ac = new MockAC(OWNER);
    admin = new Admin(address(ac));
    Flash flashSingleton = new Flash();
    PoolAux poolAux = new PoolAux(address(ac), address(admin), address(flashSingleton));
    Pool poolImpl = new Pool(address(ac), address(admin), address(flashSingleton), address(poolAux));
    PoolFactory factory = new PoolFactory(address(poolImpl), address(this), address(ac));
    base = new MockERC20("Base", "BASE", 18);
    tok = new MockERC20("Tok", "TOK", 18);
    address[] memory toks = new address[](2);
    toks[0] = address(base);
    toks[1] = address(tok);
    IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 25, flashFeePbps: 100});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
    pool = Pool(payable(factory.createPool(address(base), toks, initdata)));

    oracle = new MockOracle();
    oracle.setFeed(_feedId(address(base)), M.encodeB64(1e18, 18), VOL_1_PCT, 0, type(uint16).max);
    oracle.setFeed(_feedId(address(tok)), M.encodeB64(PX, 18), VOL_1_PCT, 0, type(uint16).max);

    vm.prank(OWNER);
    admin.setCurve(address(pool), DEFAULT_PRESET, defaultCurveInterior(), defaultCurveWQ(), 1000, 0);
    _addAsset(address(base), 18);
    _addAsset(address(tok), 18);

    for (uint256 i = 0; i < 3; ++i) {
      address who = [ATTACKER, LP, address(this)][i];
      base.mint(who, 100_000_000e18);
      tok.mint(who, 1_000_000_000e18);
      vm.startPrank(who);
      base.approve(address(pool), type(uint256).max);
      tok.approve(address(pool), type(uint256).max);
      vm.stopPrank();
    }
  }

  function _idx() internal view returns (uint256) {
    return uint256(pool.getAsset(address(tok)).liquidityIndex);
  }

  function _liab() internal view returns (uint256) {
    return uint256(pool.getAsset(address(tok)).liabilities);
  }

  function _dead() internal view returns (uint256) {
    return pool.getLPBalance(address(0), address(tok));
  }

  /// @dev `deadShares * index / WAD`: the claim the unburnable shares hold on this leg.
  function _deadClaim() internal view returns (uint256) {
    return (_dead() * _idx()) / WAD;
  }

  /// @dev Call that must not abort the test when the fix rejects it. The unfixed source lets these
  ///      through; the assertion afterwards is what separates the two.
  function _tryDonate(address who, address t, uint256 amt) internal returns (bool ok) {
    vm.prank(who);
    (ok,) = address(pool).call(abi.encodeWithSignature("donate(address,uint256)", t, amt));
  }

  function _skipCooldown() internal {
    vm.warp(vm.getBlockTimestamp() + C.DEFAULT_FLOW_COOLDOWN + 1);
  }

  /// @dev Honest liquidity on both legs, deposited AFTER whatever the attacker did.
  function _seedLps() internal {
    vm.startPrank(LP);
    pool.deposit(address(base), 30_000_000e18);
    pool.deposit(address(tok), 10_000e18);
    vm.stopPrank();
  }

  /// @dev Round trip enough size to book a real LP fee on both legs.
  function _churn() internal {
    vm.startPrank(address(this));
    for (uint256 i = 0; i < 5; ++i) {
      pool.swap(address(base), address(tok), 300_000e18, 0, address(this), NO_DEADLINE);
      pool.swap(address(tok), address(base), 100e18, 0, address(this), NO_DEADLINE);
    }
    vm.stopPrank();
  }
}

/// @title PoolIndexPinTest
/// @notice #73. `raiseIndex` is a ratio off `liabilities`, so a leg whose liabilities can sit at
///         dust is pinnable: `donate` is permissionless and a leg listed with no liquidity holds no
///         shares, so two dust donates used to walk the index onto its ceiling for ~$0. Past the
///         clamp the index is flat forever while `accrueLpFee` keeps crediting `liabilities`: 100%
///         of the leg's fee stream becomes unclaimable. Value is destroyed, not captured.
///         The defence is a permanent unburnable seed at every liability-credit site, whose claim
///         tracks the index exactly, times the headroom a widened index field buys.
contract PoolIndexPinTest is PoolIndexPinFixture {
  /// The measured attack, verbatim: `donate(1)` lands with `liabBefore == 0` so the raise no-ops and
  /// leaves `liabilities = 1`; the next donate computes `INIT * 18446746 / 1` and clamps. Total
  /// outlay 18.4M wei of an 18-decimal token, about $0. That must not move the index at all.
  function test_two_donates_cannot_pin_a_virgin_leg() public {
    uint256 idx0 = _idx();
    uint256 bal0 = tok.balanceOf(ATTACKER);
    _tryDonate(ATTACKER, address(tok), 1);
    _tryDonate(ATTACKER, address(tok), 18_446_745);

    emit log_named_uint("attacker outlay (wei)", bal0 - tok.balanceOf(ATTACKER));
    emit log_named_uint("index multiple", _idx() / idx0);
    assertEq(_idx(), idx0, "18.4M wei of dust must not move a virgin leg's index");
  }

  /// The gate at the door: a credit too small to carry the seed cannot open the leg at all.
  function test_dust_donate_is_rejected() public {
    vm.prank(ATTACKER);
    vm.expectRevert();
    pool.donate(address(tok), 1);
    assertEq(_liab(), 0, "a 1-wei donate must not credit liabilities");
  }

  /// The first credit must sink an unburnable seed, and a FULL LP exit must leave it behind. Without
  /// that floor `liabilities` returns to 0 and the raise denominator re-arms at dust every round.
  function test_first_credit_leaves_an_unburnable_floor() public {
    vm.prank(LP);
    pool.deposit(address(tok), 10_000e18);
    assertGt(_dead(), 0, "first credit seeds address(0)");

    _skipCooldown();
    uint256 lp = pool.getLPBalance(LP, address(tok));
    vm.prank(LP);
    pool.withdraw(address(tok), lp, 0, NO_DEADLINE);

    assertEq(pool.getLPBalance(LP, address(tok)), 0, "LP fully exited");
    assertGe(_liab(), DEAD_SEED, "liabilities floored by the dead claim after a full exit");
    assertGe(_deadClaim(), DEAD_SEED, "dead claim survives the exit");
  }

  /// The seed is minted OUT of the opening credit, never added to it: the same shares are minted,
  /// one slice is simply unredeemable, so `S*index/WAD <= liabilities` holds from the first block.
  function test_seed_is_split_out_of_the_first_credit_not_added() public {
    vm.prank(LP);
    pool.deposit(address(tok), 10_000e18);
    uint256 supply = pool.getLPBalance(LP, address(tok)) + _dead();
    assertEq(_liab(), 10_000e18, "liabilities are the deposit, not deposit + seed");
    assertLe((supply * _idx()) / WAD, _liab(), "total claim never exceeds liabilities");
  }

  /// The attempt-1 killer, run far past the 25 rounds that broke it. `deposit -> donate -> withdraw`
  /// doubled the index while the exit reset `liabilities` to dust and re-armed the denominator. With
  /// a floor that tracks the index exactly, every round costs the liability growth it buys.
  function test_deposit_donate_withdraw_ratchet_is_not_free() public {
    // Open honestly: at HEAD this seeds nothing, which is exactly what makes the ratchet free.
    vm.prank(ATTACKER);
    pool.deposit(address(tok), 1_000e18);

    uint256 idx0 = _idx();
    uint256 bal0 = tok.balanceOf(ATTACKER);
    for (uint256 i = 0; i < 40; ++i) {
      _skipCooldown();
      uint256 liab = _liab();
      if (liab == 0 || liab > 1e30) break;
      _tryDonate(ATTACKER, address(tok), liab); // double the index
      uint256 lp = pool.getLPBalance(ATTACKER, address(tok));
      if (lp == 0) continue;
      vm.prank(ATTACKER);
      pool.withdraw(address(tok), lp, 0, NO_DEADLINE);
    }
    uint256 bal1 = tok.balanceOf(ATTACKER);
    uint256 spent = bal0 > bal1 ? bal0 - bal1 : 0; // 0 = the ratchet ran at net zero or a profit
    uint256 grown = _idx() / idx0;

    emit log_named_uint("index multiple bought", grown);
    emit log_named_uint("net tokens spent", spent);
    // Every unit of index growth has to be carried by the dead floor, which is unrecoverable.
    assertGe(spent, DEAD_SEED * (grown - 1) / 2, "the ratchet must cost the floor it lifts");
  }

  /// Residual damage model: a pin is still reachable, but only by a payer, and what strands is the
  /// payer's own money. The floor on that cost is the dead shares' terminal claim.
  function test_pinning_costs_headroom_times_the_seed() public {
    vm.prank(ATTACKER);
    pool.deposit(address(tok), 1_000e18);
    uint256 idx0 = _idx();
    uint256 bal0 = tok.balanceOf(ATTACKER);

    for (uint256 i = 0; i < 200; ++i) {
      _skipCooldown();
      uint256 liab = _liab();
      if (liab == 0 || liab > type(uint128).max / 4) break;
      if (!_tryDonate(ATTACKER, address(tok), liab)) break;
      if (_idx() == idx0) break; // clamped: the index stopped moving
      idx0 = _idx();
      uint256 lp = pool.getLPBalance(ATTACKER, address(tok));
      if (lp != 0) {
        vm.prank(ATTACKER);
        pool.withdraw(address(tok), lp, 0, NO_DEADLINE);
      }
    }
    uint256 bal1 = tok.balanceOf(ATTACKER);
    uint256 spent = bal0 > bal1 ? bal0 - bal1 : 0;
    emit log_named_uint("spend to walk the index as far as it goes", spent);
    emit log_named_uint("final index", _idx());
    assertGe(spent, 1e6 * DEAD_SEED, "walking the index must cost real money");
  }

  /// `swapLiability` is the other mint site. A leg first opened through it must be seeded too, else
  /// the ratchet enters by the side door.
  function test_swapLiability_into_a_virgin_leg_seeds_it() public {
    vm.prank(LP);
    pool.deposit(address(base), 30_000_000e18);
    vm.prank(LP);
    pool.deposit(address(tok), 10_000e18); // reserves on the out leg to re-denominate into
    _skipCooldown();

    vm.prank(LP);
    pool.swapLiability(address(base), address(tok), 1_000e18, 0, NO_DEADLINE);
    assertGt(_dead(), 0, "swapLiability into an unseeded leg must seed it");
  }

  /// The seed must NOT alias `minLiquidity`: that is the keeper reserve floor everywhere else, and
  /// an admin raising it would silently raise the first depositor's burn to five figures.
  function test_seed_does_not_track_minLiquidity() public {
    vm.prank(OWNER);
    admin.setAssetParams(address(pool), address(tok), 5_000e18, 1000, 10000, 10000, 10000, 0, 0, 0);
    vm.prank(LP);
    pool.deposit(address(tok), 10_000e18);
    assertEq(_deadClaim(), DEAD_SEED, "burn is the dedicated seed, not the reserve floor");
  }

  /// The burn must be explicit in the return value and in its own event: emitting it as
  /// `Deposited(address(0), ...)` made every log replayer book a deposit that never happened.
  function test_first_deposit_reports_the_burn() public {
    vm.expectEmit(true, false, false, true, address(pool));
    emit DeadSharesSeeded(address(tok), DEAD_SEED, DEAD_SEED);
    vm.prank(LP);
    (bool ok, bytes memory ret) =
      address(pool).call(abi.encodeWithSignature("deposit(address,uint256)", address(tok), 1e18));
    assertTrue(ok, "deposit");
    assertEq(ret.length, 96, "DepositResult must carry deadLp as a third word");
    (,, uint256 deadLp) = abi.decode(ret, (uint256, uint256, uint256));
    assertEq(deadLp, DEAD_SEED, "reported burn matches the seeded shares");
    assertEq(deadLp, _dead(), "reported burn matches the dead balance");
  }

  /// Donating to a leg nobody has opened STRANDS the gift: the raise no-ops, so everything above the
  /// seed backs no share and is inherited by nobody. Documented at `donate`, asserted here.
  function test_pre_open_donation_is_stranded_not_inherited() public {
    vm.prank(ATTACKER);
    pool.donate(address(tok), 1_000e18);
    _seedLps();
    uint256 supply = pool.getLPBalance(LP, address(tok)) + _dead();
    uint256 stranded = _liab() - (supply * _idx()) / WAD;
    emit log_named_uint("stranded", stranded);
    assertGt(stranded, 990e18, "pre-open donation is stranded, never inherited by the first LP");
  }

  /// Post-fix the fee stream must still reach LP claim: the defence must not have frozen the index.
  function test_opened_leg_accrues_fees_control() public {
    _seedLps();
    uint256 idxBefore = _idx();
    uint256 liabBefore = _liab();
    uint256 lp = pool.getLPBalance(LP, address(tok));
    (uint256 valBefore,) = pool.previewWithdraw(address(tok), lp);

    _churn();

    (uint256 valAfter,) = pool.previewWithdraw(address(tok), lp);
    assertGt(_liab(), liabBefore, "precondition: fees were booked");
    assertGt(_idx(), idxBefore, "liquidityIndex must rise when an LP fee is booked");
    assertGt(valAfter, valBefore, "LP claim must rise when an LP fee is booked");
  }
}

/// @title PoolIndexPinDecimalsTest
/// @notice The seed is `10**decimals / DEAD_SHARE_SEED_DIV`, so it has to hold across the decimal
///         span the fleet actually lists: 6 (USDC), 8 (WBTC/cbBTC) and 18 (every FX leg).
contract PoolIndexPinDecimalsTest is PoolIndexPinFixture {
  function _leg(uint8 dec) internal returns (MockERC20 t) {
    t = new MockERC20("Dec", "DEC", dec);
    oracle.setFeed(_feedId(address(t)), M.encodeB64(1e18, 18), VOL_1_PCT, 0, type(uint16).max);
    _addAsset(address(t), dec);
    t.mint(LP, 1_000_000 * 10 ** dec);
    vm.prank(LP);
    t.approve(address(pool), type(uint256).max);
  }

  function _sweep(uint8 dec) internal {
    MockERC20 t = _leg(dec);
    uint256 seed = 10 ** dec / 1000;
    if (seed == 0) seed = 1;

    vm.prank(LP);
    vm.expectRevert();
    pool.donate(address(t), seed - 1); // a credit that cannot carry the seed cannot open the leg

    vm.prank(LP);
    pool.deposit(address(t), 1000 * 10 ** dec);
    uint256 dead = pool.getLPBalance(address(0), address(t));
    uint256 idx = uint256(pool.getAsset(address(t)).liquidityIndex);
    emit log_named_uint("decimals", dec);
    emit log_named_uint("dead claim", (dead * idx) / WAD);
    assertEq((dead * idx) / WAD, seed, "seed is 0.001 token at every listed decimal count");
  }

  function test_seed_holds_at_6_decimals() public {
    _sweep(6);
  }

  function test_seed_holds_at_8_decimals() public {
    _sweep(8);
  }

  function test_seed_holds_at_18_decimals() public {
    _sweep(18);
  }
}

/// @title PoolSeedFailClosedTest
/// @notice The seed is a defence, so it must obey the same policy `accrueLpFee` states eight lines
///         above itself: SKIP the degenerate book, never revert, because a revert on a settlement
///         path is a leg-wide denial of service bought for gas. Two sites violated it.
contract PoolSeedFailClosedTest is PoolIndexPinFixture {
  /// @dev Asset slot 1: minLiquidity[0:96) liquidityIndex[96:192) lastUpdate[192:224)
  ///      presetId[224:240) deadSeedPow10[240:248).
  function _writeIndex(address t, uint256 idx) internal {
    bytes32 slot1 = bytes32(uint256(keccak256(abi.encode(t, uint256(3)))) + 1);
    uint256 word = (idx << 96) | (vm.getBlockTimestamp() << 192) | (uint256(DEFAULT_PRESET) << 224);
    vm.store(address(pool), slot1, bytes32(word));
  }

  /// DEFECT 1. `deadLp = floor(seed*WAD/idx)` hits 0 whenever the leg's index outgrew the seed, and
  /// the ZeroValue revert that guarded it then fired on EVERY credit path forever: deposit, donate,
  /// swapLiability and hookCreditYield. Reachable on exactly the legs the pin already pinned.
  /// Ceil-divide instead: the seed always mints at least one share, so the leg always opens.
  function test_high_index_unseeded_leg_is_not_bricked() public {
    MockERC20 t = new MockERC20("Two", "TWO", 2);
    oracle.setFeed(_feedId(address(t)), M.encodeB64(1e18, 18), VOL_1_PCT, 0, type(uint16).max);
    _addAsset(address(t), 2);
    t.mint(LP, 1_000_000e2);
    vm.prank(LP);
    t.approve(address(pool), type(uint256).max);
    _writeIndex(address(t), 2e18); // seed*WAD = 1e18 < idx: the floored share count was 0

    vm.prank(LP);
    pool.deposit(address(t), 100e2);
    assertGt(pool.getLPBalance(address(0), address(t)), 0, "the seed must land, not revert");
    assertGt(pool.getLPBalance(LP, address(t)), 0, "and the depositor must still get shares");

    vm.prank(LP);
    pool.donate(address(t), 100e2); // the leg is not bricked for later credits either
    assertGt(uint256(pool.getAsset(address(t)).liabilities), 100e2, "donate still books");
  }

  /// DEFECT 2. The keeper's `rebalance() -> _harvest -> hookCreditYield` credits whatever the cap
  /// allows, which on a freshly migrated leg is routinely far below the seed (a 100-token book at
  /// 100bps over 1s credits ~1.16e13 against a 1e15 seed). That reverted the whole keeper tx.
  function test_sub_seed_hook_credit_yield_skips_instead_of_reverting() public {
    vm.prank(address(admin));
    IPool(address(pool)).adminSetAssetHook(address(tok), address(this), C.HOOK_PRE_OUTFLOW);
    uint256 idx0 = _idx();

    IPool(address(pool)).hookCreditYield(address(tok), 1.16e13); // sub-seed: must not revert

    assertEq(_dead(), 0, "a sub-seed credit seeds nothing");
    assertEq(
      _idx(), idx0, "and books no index raise, exactly like accrueLpFee on a degenerate book"
    );
    assertEq(_liab(), 1.16e13, "the credit itself still lands in liabilities");

    IPool(address(pool)).hookCreditYield(address(tok), 1e18); // self-healing on the next harvest
    assertGt(_dead(), 0, "the first credit that can carry the seed opens the leg");
    assertGt(_idx(), idx0, "and the index starts moving again");
  }
}

/// @title PoolDeadSeedOverrideTest
/// @notice The seed prices an index pin at `seed * headroom`, which is a VALUE, but the default is
///         denominated in token units. 0.001 WBTC is ~$115 burned from the first depositor, and
///         0.001 KRW1 prices the pin at ~$54k. `deadSeedPow10` re-denominates it per leg.
contract PoolDeadSeedOverrideTest is PoolIndexPinFixture {
  function test_override_reprices_the_seed_without_touching_the_default() public {
    vm.prank(OWNER);
    IPool(address(pool)).adminSetDeadSeedPow10(address(tok), 18); // 1 whole token: the KRW1 shape
    vm.prank(LP);
    pool.deposit(address(tok), 10_000e18);
    assertEq(_deadClaim(), 1e18, "seed is the override, not 10**decimals/1000");
    // The pin cost is seed x headroom, so a 1000x seed is a 1000x pin cost for the same leg.
    assertEq(_deadClaim(), DEAD_SEED * 1000, "override buys exactly its own multiple of protection");
  }

  function test_override_is_owner_only_and_bounded_at_1000_tokens() public {
    vm.prank(ATTACKER);
    vm.expectRevert();
    IPool(address(pool)).adminSetDeadSeedPow10(address(tok), 18);

    vm.prank(OWNER);
    vm.expectRevert(); // decimals + 3 is the ceiling: above it the seed is a listing toll
    IPool(address(pool)).adminSetDeadSeedPow10(address(tok), 22);

    vm.prank(OWNER);
    IPool(address(pool)).adminSetDeadSeedPow10(address(tok), 21); // exactly 1000 tokens is allowed
  }

  /// A legacy Asset word carries zeros above `presetId`, so a migrated leg reads the default.
  function test_legacy_word_reads_the_default_seed() public {
    bytes32 slot1 = bytes32(uint256(keccak256(abi.encode(address(tok), uint256(3)))) + 1);
    vm.store(
      address(pool),
      slot1,
      bytes32(
        (C.LIQUIDITY_INDEX_INIT << 96) | (vm.getBlockTimestamp() << 192)
          | (uint256(DEFAULT_PRESET) << 224)
      )
    );
    vm.prank(LP);
    pool.deposit(address(tok), 10_000e18);
    assertEq(_deadClaim(), DEAD_SEED, "deadSeedPow10 reads 0 out of a legacy word");
  }
}
