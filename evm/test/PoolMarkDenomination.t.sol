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
import {Err} from "@btr-shared/Errors.sol";
import {BaseTestSetup, MockAC, MockOracle, NO_DEADLINE} from "./fixtures/BaseTestSetup.sol";

/// @title PoolMarkDenominationTest - DEN-01 regression.
/// @notice The NXR signed catalog attests `<TOKEN>-USD` for every stable/FX slot (idx 1..16, 22, 23,
///         25..29) while the on-chain feed name is `<TOKEN>-USDC` and the pool prices spokes in BASE
///         units. Without `OracleConfig.usdQuoted` the pool consumes a USD mark as if it were a
///         base-denominated cross, mis-pricing every base<->spoke swap by exactly the base's own
///         depeg. These tests pin:
///           1. the exactness of the correction (it reproduces a genuine `<TOKEN>-BASE` mark),
///           2. the size of the uncorrected error at LIVE measured marks vs the pool's own minFee,
///           3. that the refBand / reservation guards do NOT absorb it,
///           4. the config-time guards on the flag.
contract PoolMarkDenominationTest is BaseTestSetup {
  // ── Live NXR marks, api.nxrates.com/v1/price/{sym}, 2026-07-29 ──
  uint256 constant USDC_USD = 999_921_617_700_000_000; // 0.99992161770 — base depeg = 0.784 bps
  uint256 constant USDT_USD = 998_865_631_100_000_000; // 0.99886563110 — signed at idx 1
  uint256 constant USDT_USDC = 998_936_603_600_000_000; // 0.99893660360 — the mark the pool WANTS

  /// @dev USDT's atomic-θ ladder minFee (keepers/oracle.sepolia.toml θ=0.257 ⇒ ceil(2θ·100) PBPS).
  uint16 constant USDT_MIN_FEE_PBPS = 51;

  address constant OWNER = address(0xA11CE);
  address constant USER = address(0xBEEF);

  struct Fixture {
    Pool pool;
    MockERC20 base;
    MockERC20 spoke;
    MockOracle oracle;
    Admin admin;
  }

  function _risk() internal pure returns (IPool.RiskConfig memory r) {
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20000;
    r.depthAmplifier = 10000;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
  }

  /// @dev Build a 2-asset star (base numeraire + one stable spoke) at the given marks/denomination.
  ///      vega = 0 so the path spread is exactly `minFeePbps` — the σ term is common-mode across
  ///      fixtures anyway, but pinning it makes the error-vs-fee comparison a direct read.
  function _mk(uint256 baseMark, uint256 spokeMark, bool usdQuoted)
    internal
    returns (Fixture memory f)
  {
    MockAC ac = new MockAC(OWNER);
    f.admin = new Admin(address(ac));
    Flash flashSingleton = new Flash();
    PoolAux poolAux = new PoolAux(address(ac), address(f.admin), address(flashSingleton));
    Pool poolImpl =
      new Pool(address(ac), address(f.admin), address(flashSingleton), address(poolAux));
    PoolFactory factory = new PoolFactory(address(poolImpl), address(this), address(ac));

    f.base = new MockERC20("Base", "USDC", 18);
    f.spoke = new MockERC20("Spoke", "USDT", 18);
    address[] memory toks = new address[](2);
    toks[0] = address(f.base);
    toks[1] = address(f.spoke);
    IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 25, flashFeePbps: 100});
    f.pool = Pool(
      payable(factory.createPool(
          address(f.base),
          toks,
          abi.encodeWithSelector(Pool.initialize.selector, address(f.base), address(0xCAFE), fp)
        ))
    );

    f.oracle = new MockOracle();
    f.oracle.setMark(address(f.base), M.encodeB64(baseMark, 18));
    f.oracle.setMark(address(f.spoke), M.encodeB64(spokeMark, 18));

    IPool.OracleConfig memory baseCfg = externalOracleCfg(f.oracle, address(f.base));
    IPool.OracleConfig memory spokeCfg = externalOracleCfg(f.oracle, address(f.spoke));
    spokeCfg.usdQuoted = usdQuoted;

    IPool.RiskConfig memory rc = _risk();
    vm.startPrank(OWNER);
    f.admin
      .setCurve(address(f.pool), DEFAULT_PRESET, defaultCurveInterior(), defaultCurveWQ(), 1000, 0);
    f.admin
      .addAsset(
        address(f.pool),
        address(f.base),
        baseCfg,
        rc,
        DEFAULT_PRESET,
        USDT_MIN_FEE_PBPS,
        18,
        1000,
        100_000,
        10_000,
        0
      );
    f.admin
      .addAsset(
        address(f.pool),
        address(f.spoke),
        spokeCfg,
        rc,
        DEFAULT_PRESET,
        USDT_MIN_FEE_PBPS,
        18,
        1000,
        100_000,
        10_000,
        0
      );
    vm.stopPrank();

    uint256 seed = 1_000_000e18;
    f.base.mint(address(this), seed);
    f.base.approve(address(f.pool), type(uint256).max);
    f.pool.deposit(address(f.base), seed);
    f.spoke.mint(address(this), seed);
    f.spoke.approve(address(f.pool), type(uint256).max);
    f.pool.deposit(address(f.spoke), seed);
  }

  /// @dev Implied execution price (base per spoke, 1e18) of a small base->spoke buy.
  ///      Small vs 1e6 reserves so curve impact is negligible and common-mode across fixtures.
  function _impliedPrice(Fixture memory f) internal view returns (uint256) {
    uint256 amtIn = 1e18;
    IPool.SwapQuote memory q = f.pool.getSwapQuote(address(f.base), address(f.spoke), amtIn);
    return (amtIn * 1e18) / q.amountOut;
  }

  function _absBps(uint256 a, uint256 b) internal pure returns (uint256) {
    uint256 d = a > b ? a - b : b - a;
    return (d * 10_000 * 1000) / b; // milli-bps for resolution
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 1. EXACTNESS: the correction reproduces a genuine base-denominated mark.
  // ─────────────────────────────────────────────────────────────────────────

  /// @notice On a self-consistent triple (trueCross := USD_mark / base_mark, exactly), a `usdQuoted`
  ///         spoke fed the USD mark must quote IDENTICALLY to a plain spoke fed the true cross.
  ///         This is the definition of correctness for the fix, tested with zero market basis.
  function test_DEN01_corrected_equals_true_cross_exactly() public {
    uint256 trueCross = (USDT_USD * 1e18) / USDC_USD;
    uint256 fixedPx = _impliedPrice(_mk(USDC_USD, USDT_USD, true));
    uint256 truthPx = _impliedPrice(_mk(USDC_USD, trueCross, false));
    // B64 mantissa quantization is the only residual (marks are re-encoded at 1e18 precision).
    assertApproxEqRel(fixedPx, truthPx, 1e12, "DEN-01: corrected mark != true cross");
  }

  /// @notice A spoke whose mark is ALREADY base-denominated (idx 17/18/19 ETH-USDC / BTC-USDC) must
  ///         be left alone: flagging it would divide a correct cross by the base depeg a second time.
  ///         Pins that the fix is opt-in per feed, not a blanket transform.
  function test_DEN01_flag_is_opt_in_double_correction_is_wrong() public {
    uint256 correct = _impliedPrice(_mk(USDC_USD, USDT_USDC, false));
    uint256 doubleCorrected = _impliedPrice(_mk(USDC_USD, USDT_USDC, true));
    assertGt(
      _absBps(doubleCorrected, correct), 500, "double-correction must move the price by ~0.78 bps"
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 2. MAGNITUDE: uncorrected error at live marks vs the pool's own fee.
  // ─────────────────────────────────────────────────────────────────────────

  /// @notice The uncorrected pool prices USDT below its true USDC cross by the USDC depeg. Measured
  ///         at live marks the gap must exceed the one-way fee the pool actually charges
  ///         (`spread/2`, Pricing.sol `_settleQuote`) — i.e. it is a positive-EV arb today, not noise.
  function test_DEN01_uncorrected_error_exceeds_fee_at_live_marks() public {
    uint256 legacyPx = _impliedPrice(_mk(USDC_USD, USDT_USD, false));
    uint256 truthPx = _impliedPrice(_mk(USDC_USD, USDT_USDC, false));
    uint256 fixedPx = _impliedPrice(_mk(USDC_USD, USDT_USD, true));

    uint256 errLegacyMbps = _absBps(legacyPx, truthPx);
    uint256 errFixedMbps = _absBps(fixedPx, truthPx);
    uint256 oneWayFeeMbps = (uint256(USDT_MIN_FEE_PBPS) * 1000) / 200; // PBPS -> milli-bps, halved

    emit log_named_uint("legacy error (milli-bps)", errLegacyMbps);
    emit log_named_uint("fixed  error (milli-bps)", errFixedMbps);
    emit log_named_uint("one-way fee (milli-bps)", oneWayFeeMbps);

    // The pool under-prices the spoke ⇒ a base->spoke buy over-delivers ⇒ legacy price is LOW.
    assertLt(legacyPx, truthPx, "uncorrected pool sells the spoke too cheap");
    assertGt(errLegacyMbps, oneWayFeeMbps, "DEN-01: uncorrected error is inside the fee (noise)");
    assertLt(errFixedMbps, oneWayFeeMbps, "DEN-01: corrected error must fall under the fee");
    assertLt(errFixedMbps, errLegacyMbps / 5, "DEN-01: fix must remove >80% of the error");
  }

  /// @notice Error scales 1:1 with the base depeg, bounded only by BASE_DEPEG_HALT_BPS (500). At a
  ///         4.9% depeg — INSIDE the halt band, so swaps still execute — the uncorrected mispricing
  ///         is ~490 bps, ~1900x the one-way fee. USDC traded at 0.88 in Mar-2023; every basis point
  ///         of the path from 1.00 down to 0.95 is extractable before the breaker bites.
  function test_DEN01_error_tracks_base_depeg_up_to_the_halt_band() public {
    uint256 depegged = 951e15; // 0.951 -> 490 bps, under the 500 bps halt
    uint256 trueCross = (USDT_USD * 1e18) / depegged;
    uint256 legacyPx = _impliedPrice(_mk(depegged, USDT_USD, false));
    uint256 truthPx = _impliedPrice(_mk(depegged, trueCross, false));
    uint256 fixedPx = _impliedPrice(_mk(depegged, USDT_USD, true));

    uint256 errLegacyMbps = _absBps(legacyPx, truthPx);
    emit log_named_uint("legacy error @ 4.9% base depeg (milli-bps)", errLegacyMbps);
    assertGt(errLegacyMbps, 480_000, "expected ~490 bps of extractable mispricing");
    assertApproxEqRel(fixedPx, truthPx, 1e12, "corrected quote must track the depeg");
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 3. GUARDS DO NOT ABSORB IT.
  // ─────────────────────────────────────────────────────────────────────────

  /// @notice The refBand (PoolIO.priceBandGuard) compares the primary mark to an INDEPENDENT oracle
  ///         quoting the SAME symbol — both USD-denominated — so the denomination error is
  ///         common-mode and the band never fires. Proven by executing a real swap on the
  ///         uncorrected fixture at live marks: it settles, it does not revert.
  function test_DEN01_refBand_does_not_catch_denomination_error() public {
    Fixture memory f = _mk(USDC_USD, USDT_USD, false);
    f.base.mint(USER, 1e18);
    vm.startPrank(USER);
    f.base.approve(address(f.pool), type(uint256).max);
    uint256 out = f.pool.swap(address(f.base), address(f.spoke), 1e18, 0, USER, NO_DEADLINE);
    vm.stopPrank();
    assertGt(out, 0, "swap settles: no guard rejects a wrongly-denominated mark");
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 4. CONFIG GUARDS.
  // ─────────────────────────────────────────────────────────────────────────

  /// @notice The base IS the USD reference and the divisor — flagging it is rejected.
  function test_DEN01_base_cannot_be_usdQuoted() public {
    Fixture memory f = _mk(USDC_USD, USDT_USD, true);
    IPool.OracleConfig memory cfg = externalOracleCfg(f.oracle, address(f.base));
    cfg.usdQuoted = true;
    vm.prank(address(f.admin));
    vm.expectRevert();
    IPool(address(f.pool)).adminSetOracleConfig(address(f.base), cfg);
  }

  /// @notice INTERNAL mode quotes off a base-denominated constant peg — the flag is meaningless
  ///         there and must be rejected rather than silently ignored.
  function test_DEN01_internal_mode_cannot_be_usdQuoted() public {
    Fixture memory f = _mk(USDC_USD, USDT_USD, false);
    IPool.OracleConfig memory cfg = externalOracleCfg(f.oracle, address(f.spoke));
    cfg.mode = C.ORACLE_MODE_INTERNAL;
    cfg.refBandBps = 50;
    cfg.usdQuoted = true;
    vm.prank(address(f.admin));
    vm.expectRevert();
    IPool(address(f.pool)).adminSetOracleConfig(address(f.spoke), cfg);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 5. DEN-02: absolute reservation is BASE-per-asset; usdQuoted converts first.
  // ─────────────────────────────────────────────────────────────────────────

  /// @notice usdQuoted spoke + BASE reservation ceiling: raw USD mark sits inside the ceiling, but
  ///         p_base = p_usd / baseUsd exceeds it. Without DEN-02 conversion the swap would false-pass.
  function test_DEN02_usdQuoted_reservation_halts_when_base_converted() public {
    // base 0.97 USD, spoke 1.00 USD → pAbs ≈ 1.0309 BASE; ceiling 1.02 BASE.
    uint256 baseUsd = 0.97e18;
    uint256 spokeUsd = 1e18;
    uint64 ceilBase = uint64(M.encodeB64(1.02e18, 18));
    Fixture memory f = _mk(baseUsd, spokeUsd, true);

    IPool.Asset memory a = f.pool.getAsset(address(f.spoke));
    vm.prank(OWNER);
    f.admin.setAssetParams(
      address(f.pool),
      address(f.spoke),
      a.minLiquidity,
      a.minFeePbps,
      a.maxFeePbps,
      a.gamma,
      a.vega,
      a.haircutSuppressor,
      0,
      ceilBase
    );

    // Sanity: raw USD would pass; converted BASE must fail.
    assertLt(spokeUsd, 1.02e18, "raw USD inside ceiling (false-pass without DEN-02)");
    assertGt((spokeUsd * 1e18) / baseUsd, 1.02e18, "BASE-converted mark above ceiling");

    f.base.mint(USER, 1e18);
    vm.startPrank(USER);
    f.base.approve(address(f.pool), type(uint256).max);
    vm.expectPartialRevert(Err.PriceOutsideReservation.selector);
    f.pool.swap(address(f.base), address(f.spoke), 1e18, 0, USER, NO_DEADLINE);
    vm.stopPrank();
  }

  /// @notice Same marks without usdQuoted treat the primary as already BASE-denominated, so a 1.00
  ///         mark clears a 1.02 BASE ceiling (control: denomination flag is load-bearing).
  function test_DEN02_non_usdQuoted_compares_raw_to_base_reservation() public {
    Fixture memory f = _mk(0.97e18, 1e18, false);
    IPool.Asset memory a = f.pool.getAsset(address(f.spoke));
    vm.prank(OWNER);
    f.admin.setAssetParams(
      address(f.pool),
      address(f.spoke),
      a.minLiquidity,
      a.minFeePbps,
      a.maxFeePbps,
      a.gamma,
      a.vega,
      a.haircutSuppressor,
      0,
      uint64(M.encodeB64(1.02e18, 18))
    );

    f.base.mint(USER, 1e18);
    vm.startPrank(USER);
    f.base.approve(address(f.pool), type(uint256).max);
    uint256 out = f.pool.swap(address(f.base), address(f.spoke), 1e18, 0, USER, NO_DEADLINE);
    vm.stopPrank();
    assertGt(out, 0, "raw BASE mark inside ceiling settles");
  }
}
