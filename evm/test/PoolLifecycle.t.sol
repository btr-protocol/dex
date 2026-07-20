// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {Admin} from "../src/Admin.sol";
import {Flash} from "../src/Flash.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IAdmin} from "../src/interfaces/IAdmin.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {BaseTestSetup, MockAC, MockOracle} from "./fixtures/BaseTestSetup.sol";

/// @title PoolLifecycleTest
/// @notice Pool lifecycle sanity -Pool is standalone (no proxy, no modules, no ERC-7201).
///         Each pool instance is an ERC1967 beacon proxy deployed by PoolFactory.
contract PoolLifecycleTest is BaseTestSetup {
  PoolFactory factory;
  Pool poolImpl;
  Admin admin;
  Flash flashSingleton;
  MockAC ac;
  MockOracle oracle;

  Pool pool; // clone, cast as Pool
  MockERC20 base;
  MockERC20 quote;

  address constant OWNER = address(0xA11CE);
  address constant USER = address(0xBEEF);
  uint8 constant PROTO_SHARE = 25;
  uint16 constant FLASH_FEE_BPS = 100;

  function _defaultRisk() internal pure returns (IPool.RiskConfig memory r) {
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20000;
    r.decaySlope = 0;
    r.depthAmplifier = 10000;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
  }

  function _oracleCfg(address token) internal view returns (IPool.OracleConfig memory o) {
    o.primary = address(oracle);
    o.feedId = bytes32(uint256(uint160(token)));
  }

  function setUp() public override {
    ac = new MockAC(OWNER);

    admin = new Admin(address(ac));
    flashSingleton = new Flash();
    PoolAux poolAux = new PoolAux(address(ac), address(admin), address(flashSingleton));
    poolImpl = new Pool(address(ac), address(admin), address(flashSingleton), address(poolAux));

    factory = new PoolFactory(address(poolImpl), address(this), address(ac));

    base = new MockERC20("Base", "BASE", 18);
    quote = new MockERC20("Quote", "QUOT", 18);

    address[] memory toks = new address[](2);
    toks[0] = address(base);
    toks[1] = address(quote);
    IPool.FeeParams memory fp =
      IPool.FeeParams({protoShare: PROTO_SHARE, flashFeePbps: FLASH_FEE_BPS});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
    address poolAddr = factory.createPool(address(base), toks, initdata);
    pool = Pool(payable(poolAddr));

    oracle = new MockOracle();
    oracle.setMark(address(base), M.encodeB64(1e18, 18));
    oracle.setMark(address(quote), M.encodeB64(1e18, 18));
    IPool.RiskConfig memory rc = _defaultRisk();

    vm.startPrank(OWNER);
    admin.setCurve(poolAddr, DEFAULT_PRESET, defaultCurveInterior(), defaultCurveWQ(), 1000, 0);
    admin.addAsset(
      poolAddr,
      address(base),
      _oracleCfg(address(base)),
      rc,
      DEFAULT_PRESET,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    admin.addAsset(
      poolAddr,
      address(quote),
      _oracleCfg(address(quote)),
      rc,
      DEFAULT_PRESET,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    vm.stopPrank();
  }

  function test_pool_initialized() public view {
    assertEq(pool.baseToken(), address(base));
    assertEq(pool.wnative(), address(0xCAFE));
    assertEq(pool.owner(), OWNER);
  }

  function test_pool_admin_immutable_set() public view {
    assertEq(pool.admin(), address(admin));
    assertEq(pool.flash(), address(flashSingleton));
    assertEq(pool.AC(), address(ac));
  }

  function test_initialize_idempotent() public {
    IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 0, flashFeePbps: 0});
    vm.expectRevert(Err.InvalidState.selector);
    pool.initialize(address(base), address(0xCAFE), fp);
  }

  function test_deposit_credits_lpBalance() public {
    uint256 amt = 1_000e18;
    base.mint(USER, amt);
    vm.prank(USER);
    base.approve(address(pool), type(uint256).max);

    vm.prank(USER);
    pool.deposit(address(base), amt);

    uint256 lp = pool.getLPBalance(USER, address(base));
    assertGt(lp, 0, "lp credited");
  }

  function test_deposit_then_withdraw_roundtrip() public {
    uint256 amt = 1_000e18;
    base.mint(USER, amt);
    vm.prank(USER);
    base.approve(address(pool), type(uint256).max);

    vm.prank(USER);
    pool.deposit(address(base), amt);

    uint256 lp = pool.getLPBalance(USER, address(base));
    skip(60);

    vm.prank(USER);
    pool.withdraw(address(base), lp, 0);

    assertEq(base.balanceOf(USER), amt, "base recovered");
    assertEq(pool.getLPBalance(USER, address(base)), 0, "lp cleared");
  }

  function test_admin_freeze_unfreeze() public {
    vm.prank(OWNER);
    admin.freezeAsset(address(pool), address(base));
    assertTrue((pool.getRiskFlags(address(base)) & C.FROZEN_BIT) != 0, "frozen");

    vm.prank(OWNER);
    admin.unfreezeAsset(address(pool), address(base));
    assertEq(pool.getRiskFlags(address(base)) & C.FROZEN_BIT, 0, "unfrozen");
  }

  function test_admin_pause_unpause() public {
    vm.prank(OWNER);
    admin.pauseAsset(address(pool), address(base));
    assertTrue((pool.getRiskFlags(address(base)) & C.ASSET_PAUSED_BIT) != 0, "paused");

    vm.prank(OWNER);
    admin.unpauseAsset(address(pool), address(base));
    assertEq(pool.getRiskFlags(address(base)) & C.ASSET_PAUSED_BIT, 0, "unpaused");
  }

  function test_guardian_can_freeze_but_not_unfreeze() public {
    address g = makeAddr("guardian");
    ac.setGuardian(g, true);

    vm.prank(g);
    admin.freezeAsset(address(pool), address(base));
    assertTrue((pool.getRiskFlags(address(base)) & C.FROZEN_BIT) != 0);

    vm.prank(g);
    vm.expectRevert(Ownable.Unauthorized.selector);
    admin.unfreezeAsset(address(pool), address(base));

    vm.prank(USER);
    vm.expectRevert(Ownable.Unauthorized.selector);
    admin.freezeAsset(address(pool), address(base));
  }

  function test_guardian_batch_cannot_unpause() public {
    address g = makeAddr("guardian");
    ac.setGuardian(g, true);
    address[] memory pools = new address[](1);
    address[] memory tokens = new address[](1);
    pools[0] = address(pool);
    tokens[0] = address(base);

    vm.prank(g);
    admin.batchRiskOp(pools, tokens, IAdmin.BatchOp.Pause);

    vm.prank(g);
    vm.expectRevert(Ownable.Unauthorized.selector);
    admin.batchRiskOp(pools, tokens, IAdmin.BatchOp.Unpause);
  }

  /// Guardian fast-veto: may CANCEL a pending timelocked op inside its window (kill a coerced/
  /// mis-clicked queue), but may never START (request) nor APPLY (execute) one. Owner keeps both.
  function test_guardian_can_cancel_pending_op_but_not_request_or_execute() public {
    address g = makeAddr("guardian");
    ac.setGuardian(g, true);
    IPool.RiskConfig memory cfg = _defaultRisk();

    // Guardian cannot START a timelocked op.
    vm.prank(g);
    vm.expectRevert(Ownable.Unauthorized.selector);
    admin.requestUpdateRiskConfig(address(pool), address(quote), cfg);

    // Owner queues; guardian vetoes it inside the window.
    vm.prank(OWNER);
    admin.requestUpdateRiskConfig(address(pool), address(quote), cfg);
    vm.prank(g);
    admin.cancelUpdateRiskConfig(address(pool), address(quote));

    // Cleared: re-cancel reverts InvalidState, and execute past the delay reverts NotReady.
    vm.prank(g);
    vm.expectRevert(Err.InvalidState.selector);
    admin.cancelUpdateRiskConfig(address(pool), address(quote));
    vm.warp(block.timestamp + 1 days + 1);
    vm.prank(OWNER);
    vm.expectRevert(Err.NotReady.selector);
    admin.executeUpdateRiskConfig(address(pool), address(quote));

    // Guardian cannot APPLY a fresh pending op either.
    vm.prank(OWNER);
    admin.requestUpdateRiskConfig(address(pool), address(quote), cfg);
    vm.warp(block.timestamp + 1 days + 1);
    vm.prank(g);
    vm.expectRevert(Ownable.Unauthorized.selector);
    admin.executeUpdateRiskConfig(address(pool), address(quote));

    // Owner can still cancel.
    vm.prank(OWNER);
    admin.cancelUpdateRiskConfig(address(pool), address(quote));
  }

  function test_steward_bounded_tighten_ok_riskup_clamped() public {
    address s = makeAddr("steward");
    ac.setRiskSteward(s, true);

    IAdmin.RiskFences memory f = IAdmin.RiskFences({
      minFeeHardMin: 100,
      minFeeHardMax: 5_000,
      maxFeeHardMax: 20_000,
      gammaHardMin: 5_000,
      gammaHardMax: 30_000,
      vegaHardMin: 5_000,
      vegaHardMax: 30_000,
      haircutHardMax: 10_000,
      maxDeltaBps: 2_500, // ±25%
      reservationHardLoMin: 0,
      reservationHardHiMax: 0
    });
    vm.prank(OWNER);
    admin.setRiskFences(address(pool), address(base), f);

    IPool.Asset memory before = pool.getAsset(address(base));
    // Tighten: raise minFee — exempt from relative clamp.
    uint16 tighterFee = before.minFeePbps + 200;
    vm.prank(s);
    admin.setAssetParamsBounded(
      address(pool),
      address(base),
      before.minLiquidity,
      tighterFee,
      before.maxFeePbps,
      before.gamma,
      before.vega,
      before.haircutSuppressor,
      before.reservationPrice,
      before.reservationPriceMax
    );
    assertEq(pool.getAsset(address(base)).minFeePbps, tighterFee);

    // Risk-up: cut minFee by >25% → revert.
    uint16 tooLow = uint16((uint256(tighterFee) * 50) / 100); // -50%
    vm.prank(s);
    vm.expectRevert();
    admin.setAssetParamsBounded(
      address(pool),
      address(base),
      before.minLiquidity,
      tooLow,
      before.maxFeePbps,
      before.gamma,
      before.vega,
      before.haircutSuppressor,
      before.reservationPrice,
      before.reservationPriceMax
    );

    // Risk-up within 25%: ok.
    uint16 mildCut = uint16((uint256(tighterFee) * 80) / 100); // -20%
    vm.prank(s);
    admin.setAssetParamsBounded(
      address(pool),
      address(base),
      before.minLiquidity,
      mildCut,
      before.maxFeePbps,
      before.gamma,
      before.vega,
      before.haircutSuppressor,
      before.reservationPrice,
      before.reservationPriceMax
    );
    assertEq(pool.getAsset(address(base)).minFeePbps, mildCut);

    // Guardian cannot write params.
    address g = makeAddr("guardian");
    ac.setGuardian(g, true);
    vm.prank(g);
    vm.expectRevert(Ownable.Unauthorized.selector);
    admin.setAssetParamsBounded(
      address(pool),
      address(base),
      before.minLiquidity,
      mildCut,
      before.maxFeePbps,
      before.gamma,
      before.vega,
      before.haircutSuppressor,
      before.reservationPrice,
      before.reservationPriceMax
    );
  }

  /// Audit ①: lowering maxFee is risk-up — must not bypass clamp via faux "tighten" on other params.
  function test_steward_cannot_collapse_maxFee_in_one_step() public {
    address s = makeAddr("steward");
    ac.setRiskSteward(s, true);
    IAdmin.RiskFences memory f = IAdmin.RiskFences({
      minFeeHardMin: 100,
      minFeeHardMax: 5_000,
      maxFeeHardMax: 20_000,
      gammaHardMin: 5_000,
      gammaHardMax: 30_000,
      vegaHardMin: 5_000,
      vegaHardMax: 30_000,
      haircutHardMax: 10_000,
      maxDeltaBps: 2_500,
      reservationHardLoMin: 0,
      reservationHardHiMax: 0
    });
    vm.prank(OWNER);
    admin.setRiskFences(address(pool), address(base), f);

    IPool.Asset memory cur = pool.getAsset(address(base));
    uint16 raisedMin = cur.minFeePbps + 50;
    vm.prank(s);
    vm.expectRevert();
    admin.setAssetParamsBounded(
      address(pool),
      address(base),
      cur.minLiquidity,
      raisedMin,
      1, // collapse maxFee — risk-up, not exempt
      cur.gamma,
      cur.vega,
      cur.haircutSuppressor,
      cur.reservationPrice,
      cur.reservationPriceMax
    );
  }

  /// Audit ②: reservation band cannot jump unbounded on steward path.
  function test_steward_reservation_clamped() public {
    address s = makeAddr("steward");
    ac.setRiskSteward(s, true);
    IAdmin.RiskFences memory f = IAdmin.RiskFences({
      minFeeHardMin: 100,
      minFeeHardMax: 5_000,
      maxFeeHardMax: 20_000,
      gammaHardMin: 5_000,
      gammaHardMax: 30_000,
      vegaHardMin: 5_000,
      vegaHardMax: 30_000,
      haircutHardMax: 10_000,
      maxDeltaBps: 2_500,
      reservationHardLoMin: 0,
      reservationHardHiMax: 0
    });
    vm.prank(OWNER);
    admin.setRiskFences(address(pool), address(base), f);

    IPool.Asset memory seeded = pool.getAsset(address(base));
    uint64 px = uint64(M.encodeB64(1e18, 18));
    vm.prank(OWNER);
    admin.setAssetParams(
      address(pool),
      address(base),
      seeded.minLiquidity,
      seeded.minFeePbps,
      seeded.maxFeePbps,
      seeded.gamma,
      seeded.vega,
      seeded.haircutSuppressor,
      px / 2,
      px * 2
    );

    IPool.Asset memory cur = pool.getAsset(address(base));
    vm.prank(s);
    vm.expectRevert();
    admin.setAssetParamsBounded(
      address(pool),
      address(base),
      cur.minLiquidity,
      cur.minFeePbps,
      cur.maxFeePbps,
      cur.gamma,
      cur.vega,
      cur.haircutSuppressor,
      1, // widen lo — risk-up
      cur.reservationPriceMax
    );
  }

  /// Audit ④: absolute reservation fence binds independently of the relative clamp.
  function test_steward_reservation_hard_fenced() public {
    address s = makeAddr("steward");
    ac.setRiskSteward(s, true);
    uint64 px = uint64(M.encodeB64(1e18, 18));
    IAdmin.RiskFences memory f = IAdmin.RiskFences({
      minFeeHardMin: 100,
      minFeeHardMax: 5_000,
      maxFeeHardMax: 20_000,
      gammaHardMin: 5_000,
      gammaHardMax: 30_000,
      vegaHardMin: 5_000,
      vegaHardMax: 30_000,
      haircutHardMax: 10_000,
      maxDeltaBps: 10_000, // 100% — relative clamp is loose; the hard fence must bind.
      reservationHardLoMin: px / 2,
      reservationHardHiMax: px * 2
    });
    vm.prank(OWNER);
    admin.setRiskFences(address(pool), address(base), f);

    IPool.Asset memory seeded = pool.getAsset(address(base));
    vm.prank(OWNER);
    admin.setAssetParams(
      address(pool),
      address(base),
      seeded.minLiquidity,
      seeded.minFeePbps,
      seeded.maxFeePbps,
      seeded.gamma,
      seeded.vega,
      seeded.haircutSuppressor,
      px / 2,
      px * 2
    );
    IPool.Asset memory cur = pool.getAsset(address(base));

    // Ceiling above hardHiMax though within 100% clamp → fence reverts.
    vm.prank(s);
    vm.expectRevert();
    admin.setAssetParamsBounded(
      address(pool),
      address(base),
      cur.minLiquidity,
      cur.minFeePbps,
      cur.maxFeePbps,
      cur.gamma,
      cur.vega,
      cur.haircutSuppressor,
      cur.reservationPrice,
      px * 2 + px / 4
    );

    // Floor below hardLoMin though within 100% clamp → fence reverts.
    vm.prank(s);
    vm.expectRevert();
    admin.setAssetParamsBounded(
      address(pool),
      address(base),
      cur.minLiquidity,
      cur.minFeePbps,
      cur.maxFeePbps,
      cur.gamma,
      cur.vega,
      cur.haircutSuppressor,
      px / 2 - px / 8,
      cur.reservationPriceMax
    );

    // Narrow within fence → ok.
    vm.prank(s);
    admin.setAssetParamsBounded(
      address(pool),
      address(base),
      cur.minLiquidity,
      cur.minFeePbps,
      cur.maxFeePbps,
      cur.gamma,
      cur.vega,
      cur.haircutSuppressor,
      px / 2 + px / 8,
      px * 2 - px / 4
    );
    assertEq(pool.getAsset(address(base)).reservationPrice, px / 2 + px / 8);
  }

  /// Sec-review LOW: zeroing a live reservation bound disables that side of the depeg breaker and
  /// must revert on the steward path even at a 100% relative clamp (only the owner's unbounded
  /// setAssetParams may disable it). At maxDeltaBps==10000 the relative clamp alone let oldV→0 pass.
  function test_steward_cannot_zero_reservation_bound() public {
    address s = makeAddr("steward");
    ac.setRiskSteward(s, true);
    uint64 px = uint64(M.encodeB64(1e18, 18));
    IAdmin.RiskFences memory f = IAdmin.RiskFences({
      minFeeHardMin: 100,
      minFeeHardMax: 5_000,
      maxFeeHardMax: 20_000,
      gammaHardMin: 5_000,
      gammaHardMax: 30_000,
      vegaHardMin: 5_000,
      vegaHardMax: 30_000,
      haircutHardMax: 10_000,
      maxDeltaBps: 10_000,
      reservationHardLoMin: px / 2,
      reservationHardHiMax: px * 2
    });
    vm.prank(OWNER);
    admin.setRiskFences(address(pool), address(base), f);
    IPool.Asset memory seeded = pool.getAsset(address(base));
    vm.prank(OWNER);
    admin.setAssetParams(
      address(pool),
      address(base),
      seeded.minLiquidity,
      seeded.minFeePbps,
      seeded.maxFeePbps,
      seeded.gamma,
      seeded.vega,
      seeded.haircutSuppressor,
      px / 2,
      px * 2
    );
    IPool.Asset memory cur = pool.getAsset(address(base));
    vm.prank(s);
    vm.expectRevert();
    admin.setAssetParamsBounded(
      address(pool),
      address(base),
      cur.minLiquidity,
      cur.minFeePbps,
      cur.maxFeePbps,
      cur.gamma,
      cur.vega,
      cur.haircutSuppressor,
      0,
      cur.reservationPriceMax
    );
  }

  /// Audit ③: minLiquidity is owner-only on steward path.
  function test_steward_cannot_change_minLiquidity() public {
    address s = makeAddr("steward");
    ac.setRiskSteward(s, true);
    IAdmin.RiskFences memory f = IAdmin.RiskFences({
      minFeeHardMin: 100,
      minFeeHardMax: 5_000,
      maxFeeHardMax: 20_000,
      gammaHardMin: 5_000,
      gammaHardMax: 30_000,
      vegaHardMin: 5_000,
      vegaHardMax: 30_000,
      haircutHardMax: 10_000,
      maxDeltaBps: 2_500,
      reservationHardLoMin: 0,
      reservationHardHiMax: 0
    });
    vm.prank(OWNER);
    admin.setRiskFences(address(pool), address(base), f);

    IPool.Asset memory cur = pool.getAsset(address(base));
    vm.prank(s);
    vm.expectRevert(Err.BadConfig.selector);
    admin.setAssetParamsBounded(
      address(pool),
      address(base),
      cur.minLiquidity + 1,
      cur.minFeePbps,
      cur.maxFeePbps,
      cur.gamma,
      cur.vega,
      cur.haircutSuppressor,
      cur.reservationPrice,
      cur.reservationPriceMax
    );
  }

  /// ASSET_PAUSED on an asset must block withdraw (same HALT_MASK gate as swap/deposit).
  function test_pause_blocks_withdraw() public {
    uint256 amt = 100e18;
    base.mint(USER, amt);
    vm.startPrank(USER);
    base.approve(address(pool), type(uint256).max);
    pool.deposit(address(base), amt);
    uint256 lp = pool.getLPBalance(USER, address(base));
    skip(60);
    vm.stopPrank();

    vm.prank(OWNER);
    admin.pauseAsset(address(pool), address(base));

    vm.prank(USER);
    vm.expectRevert(abi.encodeWithSelector(Err.FeatureDisabled.selector, Err.Resource.ASSET));
    pool.withdraw(address(base), lp / 2, 0);
  }

  /// ASSET_PAUSED_BIT (bit6) is SEPARATE from FROZEN_BIT (bit0): an emergency pause + an
  /// independent per-asset risk freeze coexist, and clearing one must NOT clear the other.
  function test_pause_and_freeze_are_independent() public {
    vm.startPrank(OWNER);
    admin.pauseAsset(address(pool), address(base));
    admin.freezeAsset(address(pool), address(base));
    uint16 f = pool.getRiskFlags(address(base));
    assertTrue((f & C.ASSET_PAUSED_BIT) != 0 && (f & C.FROZEN_BIT) != 0, "both set");

    admin.unpauseAsset(address(pool), address(base)); // clears ONLY bit6
    f = pool.getRiskFlags(address(base));
    assertEq(f & C.ASSET_PAUSED_BIT, 0, "pause cleared");
    assertTrue((f & C.FROZEN_BIT) != 0, "freeze must survive unpause");
    admin.unfreezeAsset(address(pool), address(base));
    vm.stopPrank();
  }

  /// One owner tx pauses N (pool,token) pairs; a bad leg (unlisted asset) is SKIPPED, not reverted.
  function test_batch_pause_skips_bad_leg() public {
    address[] memory pools = new address[](2);
    address[] memory tokens = new address[](2);
    pools[0] = address(pool);
    tokens[0] = address(base); // good leg
    pools[1] = address(pool);
    tokens[1] = address(0xDEAD); // bad leg (not a listed asset) → must be skipped, not revert

    vm.prank(OWNER);
    admin.batchRiskOp(pools, tokens, IAdmin.BatchOp.Pause);

    assertTrue((pool.getRiskFlags(address(base)) & C.ASSET_PAUSED_BIT) != 0, "good leg paused");

    // unpause the good leg via the batch path too
    tokens[1] = address(base);
    vm.prank(OWNER);
    admin.batchRiskOp(pools, tokens, IAdmin.BatchOp.Unpause);
    assertEq(pool.getRiskFlags(address(base)) & C.ASSET_PAUSED_BIT, 0, "unpaused via batch");
  }

  function test_batch_length_mismatch_reverts() public {
    address[] memory pools = new address[](2);
    address[] memory tokens = new address[](1);
    vm.prank(OWNER);
    vm.expectRevert(Err.InvalidInput.selector);
    admin.batchRiskOp(pools, tokens, IAdmin.BatchOp.Pause);
  }

  function test_admin_only_via_singleton() public {
    vm.prank(USER);
    vm.expectRevert(Err.NotOwner.selector);
    IPool(address(pool)).adminFreezeAsset(address(base));
  }

  /// @notice Wave-3a: cold-path selectors routed via Pool.fallback → PoolAux delegatecall.
  ///         Proves admin-gated setter still revertx Unauthorized when caller != admin
  ///         singleton, AND succeeds when called by admin (via Admin contract).
  function test_wave3a_fallback_dispatch_admin_gate() public {
    // Direct call from non-admin should revert Unauthorized (PoolAux onlyAdmin gate).
    vm.prank(USER);
    vm.expectRevert(Err.NotOwner.selector);
    IPool(address(pool)).adminSetFlowCooldown(123);

    // Call from admin singleton (impersonate) succeeds through fallback.
    vm.prank(address(admin));
    IPool(address(pool)).adminSetFlowCooldown(123);
  }

  /// @notice Wave-3a: invalid selector (not in PoolAux) must revert cleanly.
  function test_wave3a_fallback_unknown_selector_reverts() public {
    (bool ok,) = address(pool).call(abi.encodeWithSelector(bytes4(0xdeadbeef)));
    assertFalse(ok, "unknown selector must revert");
  }

  function test_factory_registers_pool() public view {
    assertTrue(factory.isPool(address(pool)));
    assertEq(factory.poolBaseTokens(address(pool)), address(base));
    assertEq(factory.getAllPoolsCount(), 1);
  }

  function test_pool_storage_at_slot_0() public {
    // Phase 42H.B.3d -PoolStorage struct lives at slot 0 (no ERC-7201 indirection).
    // Slot 0 holds first field: baseToken (address).
    bytes32 slot0 = vm.load(address(pool), bytes32(uint256(0)));
    assertEq(address(uint160(uint256(slot0))), address(base), "baseToken @ slot 0");
  }

  function test_owner_via_AC_singleton() public {
    // Owner rotation on AC propagates instantly to the pool view.
    ac.rotate(USER);
    assertEq(pool.owner(), USER);
    // Restore for other tests.
    ac.rotate(OWNER);
  }

  /// Executing a queued RiskConfig update overwrites the whole flags word: a freeze/pause raised
  /// DURING the timelock window must survive the execute (halt bits clear only via explicit
  /// unfreeze/unpause), and a queued config must not sneak halt bits IN either.
  function test_riskConfig_update_preserves_halt_bits() public {
    IPool.RiskConfig memory cfg = _defaultRisk();
    cfg.flags |= C.FROZEN_BIT; // attempt to sneak a halt bit IN via config — must be stripped
    vm.startPrank(OWNER);
    admin.requestUpdateRiskConfig(address(pool), address(quote), cfg);
    // Emergency raised while the update sits in the timelock queue.
    admin.freezeAsset(address(pool), address(quote));
    admin.pauseAsset(address(pool), address(quote));
    vm.warp(block.timestamp + 1 days + 1);
    admin.executeUpdateRiskConfig(address(pool), address(quote));
    vm.stopPrank();

    uint16 f = pool.getRiskFlags(address(quote));
    assertTrue((f & C.FROZEN_BIT) != 0, "freeze must survive config execute");
    assertTrue((f & C.ASSET_PAUSED_BIT) != 0, "pause must survive config execute");
    assertTrue((f & C.SWAP_ENABLED_BIT) != 0, "non-halt config flags applied");

    // Explicit ops remain the only way to clear halt bits.
    vm.startPrank(OWNER);
    admin.unfreezeAsset(address(pool), address(quote));
    admin.unpauseAsset(address(pool), address(quote));
    vm.stopPrank();
    f = pool.getRiskFlags(address(quote));
    assertEq(f & C.HALT_MASK, 0, "explicit unfreeze/unpause clears halt (sneaked bit stripped too)");
  }

  /// batchSwap transits base on every spoke↔spoke route, but each leg prices base as an ENDPOINT,
  /// so Pricing's interior-hub HALT_MASK gate never fires there. Regression: a frozen (or
  /// protocol-paused) base must block spoke→spoke batches exactly like the single-swap path.
  function test_batchSwap_frozen_base_blocks_spoke_to_spoke() public {
    MockERC20 tok2 = new MockERC20("Tok2", "TK2", 18);
    oracle.setMark(address(tok2), M.encodeB64(1e18, 18));
    vm.prank(OWNER);
    admin.addAsset(
      address(pool),
      address(tok2),
      _oracleCfg(address(tok2)),
      _defaultRisk(),
      DEFAULT_PRESET,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );

    // Seed reserves on base + both spokes (input leg quote→base draws base transiently).
    base.mint(address(this), 1_000e18);
    quote.mint(address(this), 1_000e18);
    tok2.mint(address(this), 1_000e18);
    base.approve(address(pool), type(uint256).max);
    quote.approve(address(pool), type(uint256).max);
    tok2.approve(address(pool), type(uint256).max);
    pool.deposit(address(base), 1_000e18);
    pool.deposit(address(quote), 1_000e18);
    pool.deposit(address(tok2), 1_000e18);

    // inputs entry: [token:160][amtB64:64][pad:32]; outputs entry: [token:160][weightBps:16][pad:16][minB64:64]
    bytes memory inputs = abi.encodePacked(
      bytes32((uint256(uint160(address(quote))) << 96) | (uint256(M.encodeB64(100e18, 18)) << 32))
    );
    bytes memory outputs = abi.encodePacked(
      bytes32(
        (uint256(uint160(address(tok2))) << 96) | (uint256(10_000) << 80)
          | uint256(M.encodeB64(1, 18))
      )
    );

    quote.mint(USER, 1_000e18);
    vm.startPrank(USER);
    quote.approve(address(pool), type(uint256).max);
    uint256[] memory outs = pool.batchSwap(inputs, outputs, USER); // sanity: routes pre-freeze
    assertGt(outs[0], 0, "spoke->spoke batch routes while base live");
    vm.stopPrank();

    vm.prank(OWNER);
    admin.freezeAsset(address(pool), address(base));
    vm.prank(USER);
    vm.expectRevert(abi.encodeWithSelector(Err.FeatureDisabled.selector, Err.Resource.ASSET));
    pool.batchSwap(inputs, outputs, USER);
  }

  // ─── perpetual profile recalibration (requestUpdateProfile / executeUpdateProfile) ───

  /// @dev Coarser single-segment preset (same ±500 pbps span as DEFAULT_PRESET, no interior knots).
  uint16 constant RECAL_PRESET = 2;

  function _installRecalCurve() internal {
    uint256[] memory interior = new uint256[](0);
    int256[] memory wQ = new int256[](5);
    (wQ[0], wQ[1], wQ[2], wQ[3], wQ[4]) =
      (int256(-500e9), int256(-250e9), int256(0), int256(250e9), int256(500e9));
    vm.prank(OWNER);
    admin.setCurve(address(pool), RECAL_PRESET, interior, wQ, 1000, 0);
  }

  /// @dev Seed base+quote reserves so a base→quote quote isn't reserve-clamped; quote is the
  ///      profile asset (base is the anchorless hub), so recalibrating `quote` moves this curve.
  function _seedForQuote(uint256 amt) internal {
    base.mint(address(this), amt);
    quote.mint(address(this), amt);
    base.approve(address(pool), type(uint256).max);
    quote.approve(address(pool), type(uint256).max);
    pool.deposit(address(base), amt);
    pool.deposit(address(quote), amt);
  }

  /// (a) Recalibration after timelock reshapes the depth curve: same fixed trade prices differently.
  ///     Widening the dispersion band scales every spline price-offset up (y = knot·dispersion/100),
  ///     so the taker's slippage strictly increases → less out.
  function test_updateProfile_recalibrates_price_impact() public {
    _seedForQuote(1_000e18);
    uint256 amtIn = 10e18;
    uint256 outBefore = pool.getSwapQuote(address(base), address(quote), amtIn).amountOut;
    assertGt(outBefore, 0, "baseline quote");

    _installRecalCurve();
    vm.prank(OWNER);
    admin.requestUpdateProfile(address(pool), address(quote), RECAL_PRESET, 80_000, 80_000);
    vm.warp(block.timestamp + 1 days + 1);
    // Keeper marks would refresh over a 1-day window; without it the mock feed staleness-halts.
    oracle.setMark(address(base), M.encodeB64(1e18, 18));
    oracle.setMark(address(quote), M.encodeB64(1e18, 18));
    vm.prank(OWNER);
    admin.executeUpdateProfile(address(pool), address(quote));

    IPool.Asset memory a = pool.getAsset(address(quote));
    assertEq(a.presetId, RECAL_PRESET, "preset repointed");
    assertEq(a.minDispersion, 80_000, "min dispersion written");
    assertEq(a.maxDispersion, 80_000, "max dispersion written");

    uint256 outAfter = pool.getSwapQuote(address(base), address(quote), amtIn).amountOut;
    assertTrue(outAfter != outBefore, "recalibration changed the price-impact curve");
    assertLt(outAfter, outBefore, "wider dispersion steepens curve, more slippage");
  }

  /// (b1) Repointing at an uninstalled preset reverts at execute via `validatePresetAssign`.
  function test_updateProfile_unknownPreset_reverts() public {
    uint16 missing = 42; // no curve installed at this id
    vm.startPrank(OWNER);
    admin.requestUpdateProfile(address(pool), address(quote), missing, 1000, 100000);
    vm.warp(block.timestamp + 1 days + 1);
    vm.expectRevert(
      abi.encodeWithSelector(Err.NotConfigured.selector, Err.Resource.ASSET, address(quote))
    );
    admin.executeUpdateProfile(address(pool), address(quote));
    vm.stopPrank();
  }

  /// (b2) Inverted dispersion band (min > max) reverts at execute (sanitizeDispersion ordering guard).
  function test_updateProfile_invalidDispersion_reverts() public {
    vm.startPrank(OWNER);
    admin.requestUpdateProfile(address(pool), address(quote), DEFAULT_PRESET, 90_000, 1000);
    vm.warp(block.timestamp + 1 days + 1);
    vm.expectRevert(Err.BadConfig.selector);
    admin.executeUpdateProfile(address(pool), address(quote));
    vm.stopPrank();
  }

  /// (c) Executing before the LOW_TIMELOCK (1 day) elapses reverts NotReady.
  function test_updateProfile_beforeTimelock_reverts() public {
    vm.startPrank(OWNER);
    admin.requestUpdateProfile(address(pool), address(quote), DEFAULT_PRESET, 1000, 100000);
    vm.warp(block.timestamp + 1 hours); // < 1 day
    vm.expectRevert(Err.NotReady.selector);
    admin.executeUpdateProfile(address(pool), address(quote));
    vm.stopPrank();
  }

  /// (d) Only the AC owner may queue/execute a recalibration.
  function test_updateProfile_nonAdmin_reverts() public {
    vm.startPrank(USER);
    vm.expectRevert(Ownable.Unauthorized.selector);
    admin.requestUpdateProfile(address(pool), address(quote), DEFAULT_PRESET, 1000, 100000);
    vm.expectRevert(Ownable.Unauthorized.selector);
    admin.executeUpdateProfile(address(pool), address(quote));
    vm.stopPrank();
  }

  function test_swap_simple() public {
    uint256 amt = 1_000e18;
    base.mint(USER, amt);
    quote.mint(address(this), amt);
    // Seed quote reserves via deposit.
    quote.approve(address(pool), type(uint256).max);
    pool.deposit(address(quote), amt);

    vm.prank(USER);
    base.approve(address(pool), type(uint256).max);

    vm.prank(USER);
    uint256 out = pool.swap(address(base), address(quote), amt / 10, 0, USER);
    assertGt(out, 0, "swap out");
    assertEq(quote.balanceOf(USER), out, "user got quote");
  }

  /// A-02 regression: a swap that quotes amountOut == 0 (dust input rounded away by the
  /// price conversion) must revert ZeroValue, never settle a zero-delivery swap.
  function test_swap_zeroOutput_reverts() public {
    uint256 amt = 1_000e18;
    base.mint(USER, amt);
    quote.mint(address(this), amt);
    quote.approve(address(pool), type(uint256).max);
    pool.deposit(address(quote), amt);

    // Quote 1e12× the base: 1 wei of base converts to 1e-12 wei of quote → floors to 0 out.
    oracle.setMark(address(quote), M.encodeB64(1e30, 18));

    vm.startPrank(USER);
    base.approve(address(pool), type(uint256).max);
    vm.expectRevert(Err.ZeroValue.selector);
    pool.swap(address(base), address(quote), 1, 0, USER);
    vm.stopPrank();
  }
}
