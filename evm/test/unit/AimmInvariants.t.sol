// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {MockERC20} from "../../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../../src/Pool.sol";
import {PoolAux} from "../../src/PoolAux.sol";
import {PoolFactory} from "../../src/PoolFactory.sol";
import {Admin} from "../../src/Admin.sol";
import {Flash} from "../../src/Flash.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {Constants as C} from "../../src/libraries/Constants.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {Err} from "@btr-shared/Errors.sol";
import {BaseTestSetup, MockAC, MockOracle, NO_DEADLINE} from "../fixtures/BaseTestSetup.sol";

/// @title AimmInvariants
/// @notice Reproduction + invariant tests for the AIMM pricer at NON-UNITY price.
///         The existing suite seeds every asset at price=1.0 (PoolLifecycle.t.sol:93),
///         which masks: BUG-1 (reciprocal oracle push), BUG-2 (sell-premium sign flip),
///         BUG-3 (buy-side decimal underflow). These tests seed a $3000 asset so the
///         orientation/sign/decimal defects become observable. They are expected to
///         FAIL on the current code and pass once the pricer is corrected.
contract AimmInvariantsTest is BaseTestSetup {
  PoolFactory factory;
  Pool poolImpl;
  Admin admin;
  Flash flashSingleton;
  MockAC ac;
  MockOracle oracle;

  Pool pool;
  MockERC20 base; // numeraire, 18d, price 1.0
  MockERC20 tok; // volatile asset, 18d, price 3000 (base per tok)

  address constant OWNER = address(0xA11CE);
  address constant USER = address(0xBEEF);
  uint8 constant PROTO_SHARE = 25;
  uint16 constant FLASH_FEE_BPS = 100;

  uint256 constant PX = 3000e18; // 3000 base per tok

  function _risk() internal pure returns (IPool.RiskConfig memory r) {
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20000;
    r.decaySlope = 0;
    r.depthAmplifier = 10000;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
  }

  /// @dev M-1: EXTERNAL spokes must carry a cumulative bound; armed via the shared mirror-ref fixture.
  function _oracle(address token) internal returns (IPool.OracleConfig memory o) {
    o = externalOracleCfg(oracle, token);
  }

  function _feedId(address token) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(token)));
  }

  function setUp() public override {
    ac = new MockAC(OWNER);
    admin = new Admin(address(ac));
    flashSingleton = new Flash();
    PoolAux poolAux = new PoolAux(address(ac), address(admin), address(flashSingleton));
    poolImpl = new Pool(address(ac), address(admin), address(flashSingleton), address(poolAux));
    factory = new PoolFactory(address(poolImpl), address(this), address(ac));

    base = new MockERC20("Base", "BASE", 18);
    tok = new MockERC20("Tok", "TOK", 18);

    address[] memory toks = new address[](2);
    toks[0] = address(base);
    toks[1] = address(tok);
    IPool.FeeParams memory fp =
      IPool.FeeParams({protoShare: PROTO_SHARE, flashFeePbps: FLASH_FEE_BPS});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
    pool = Pool(payable(factory.createPool(address(base), toks, initdata)));

    oracle = new MockOracle();
    oracle.setMark(address(base), M.encodeB64(1e18, 18));
    // tok: fresh mark 3000 (base per tok, NON-UNITY), σ=1%, CI=0, finite ttl for staleness tests.
    oracle.setFeed(_feedId(address(tok)), M.encodeB64(PX, 18), 10_000, 0, 3600);
    IPool.RiskConfig memory rc = _risk();

    vm.startPrank(OWNER);
    admin.setCurve(address(pool), DEFAULT_PRESET, defaultCurveInterior(), defaultCurveWQ(), 1000, 0);
    admin.addAsset(
      address(pool),
      address(base),
      _oracle(address(base)),
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
      address(pool),
      address(tok),
      _oracle(address(tok)),
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

    // Seed reserves: deep on both sides so swaps do not reserve-clamp.
    base.mint(address(this), 10_000_000e18);
    tok.mint(address(this), 10_000e18);
    base.approve(address(pool), type(uint256).max);
    tok.approve(address(pool), type(uint256).max);
    pool.deposit(address(base), 10_000_000e18); // $10M base
    pool.deposit(address(tok), 3_000e18); // 3000 tok = $9M
  }

  /// Confidence surcharge: the feed's 1σ CI widens the quoted spread (uncertain marks priced
  /// defensively). With CI=0 the spread floors to minFee (σ·vega alone is small); a material CI
  /// must lift it above that floor. NB: the tx-scoped oracle TCache would serve a stale cached feed
  /// on a re-quote of the SAME token, so we assert against the known floor rather than re-quoting.
  function test_confidence_surcharge_widens_beyond_floor() public {
    uint16 floorFee = pool.getAsset(address(tok)).minFeePbps; // 0.1%
    oracle.setFeed(_feedId(address(tok)), M.encodeB64(PX, 18), 10_000, 200, 3600); // 2% CI
    IPool.SwapQuote memory q = pool.getSwapQuote(address(tok), address(base), 1e18);
    assertGt(q.spreadPbps, floorFee, "confidence surcharge must widen beyond the minFee floor");
  }

  /// Confidence halt: a feed CI past MAX_CONFIDENCE_HALT_BPS (10%) fail-closes the swap path.
  function test_confidence_halt_reverts_past_cap() public {
    oracle.setFeed(
      _feedId(address(tok)), M.encodeB64(PX, 18), 10_000, C.MAX_CONFIDENCE_HALT_BPS + 1, 3600
    );
    vm.expectRevert(); // Err.ThresholdViolation(confidence, MAX_CONFIDENCE_HALT_BPS)
    pool.getSwapQuote(address(tok), address(base), 1e18);
  }

  /// BUG-2: selling tok->base must never quote a PREMIUM. Effective price (base out per tok in)
  /// must be <= TWAP (3000), minus fees/slippage. A premium = pool overpays sellers = free extraction.
  function test_bug2_sell_never_premium() public {
    uint256 amtIn = 1e18; // sell 1 tok
    IPool.SwapQuote memory q = pool.getSwapQuote(address(tok), address(base), amtIn);
    // base out per tok in, in 1e18 base-per-tok terms (both 18 decimals)
    uint256 avgPrice = (q.amountOut * 1e18) / amtIn;
    assertLe(avgPrice, PX + PX / 100, "BUG-2: sell quoted a premium above TWAP");
  }

  /// Staleness gate: once a feed ages past its ttl (default 3600s), the swap path must fail-closed
  /// (revert StaleData) rather than quote off a frozen mark. This is the mandatory guard that makes
  /// external feeds safe — a dead keeper halts trading instead of bleeding LPs to pick-off.
  function test_stale_feed_reverts() public {
    // Feed seeded in setUp; age it past ttl (default 3600s). First (uncached) read in this tx
    // must fail-closed. NB: keep it a single quote — a warm-up call would cache the feed in
    // transient TCache and legitimately skip the re-check within the same tx.
    vm.warp(block.timestamp + 4000);
    vm.expectRevert();
    pool.getSwapQuote(address(tok), address(base), 1e18);
  }

  /// Staleness PREMIUM (soft, pre-TTL): a mark aged under its ttl must quote a WIDER spread than a
  /// fresh one — the A-S STALE_Z·σ·√age keeper-lag defense in Pricing._pathSpread. This is the
  /// graceful-degradation step that sits BELOW the hard TTL revert (test_stale_feed_reverts): as the
  /// keeper lags, the pool widens instead of being picked off, then halts only if it goes fully stale.
  function test_staleness_widens_spread() public {
    IPool.SwapQuote memory qFresh = pool.getSwapQuote(address(tok), address(base), 1e18);
    // Grace = min(ttl/2, 30s cap): a mark aged UNDER the cap must NOT widen (flat-market /
    // live-keeper case — else we quote wide and lose flow for nothing).
    vm.warp(block.timestamp + 20);
    IPool.SwapQuote memory qWithinGrace = pool.getSwapQuote(address(tok), address(base), 1e18);
    assertEq(
      qWithinGrace.spreadPbps,
      qFresh.spreadPbps,
      "within grace (age<=30s) the premium must stay OFF"
    );
    // L-1 regression: age=100s sat premium-FREE under the old grace = ttl/2 (1800s here; 300s on a
    // volatile ttl=600 feed — the whole legal relay-lag window). The 30s cap must now widen it.
    vm.warp(block.timestamp + 80); // total age 100s: > 30s grace cap, ≪ ttl
    IPool.SwapQuote memory qStale = pool.getSwapQuote(address(tok), address(base), 1e18);
    assertGt(
      qStale.spreadPbps, qFresh.spreadPbps, "past grace the staleness premium must widen the spread"
    );
    // NON-SATURATION: the premium must be a GENTLE ramp, not slam to maxFee the instant age>grace.
    // Regression guard for the σ-scaling bug (raw σ·√excess with σ in PBPS saturated maxFee at 1s):
    // a larger excess must quote STRICTLY MORE — if it had saturated, both points would be equal.
    vm.warp(block.timestamp + 2400); // total age 2500s: excess 2470s (> the 70s above, still < ttl)
    IPool.SwapQuote memory qMoreStale = pool.getSwapQuote(address(tok), address(base), 1e18);
    assertGt(
      qMoreStale.spreadPbps,
      qStale.spreadPbps,
      "premium must keep ramping (not saturated to maxFee)"
    );
  }

  /// Depeg band: a swap whose OUTPUT asset mark sits outside its price band must revert (the
  /// reservationPrice / reservationPriceMax guard). Here max is set below tok's mark → buying tok halts.
  function test_reservation_band_halts_out_of_band_swap() public {
    vm.prank(OWNER);
    // ...reservationPrice=0 (no floor), reservationPriceMax = half the mark → tok mark is above it.
    admin.setAssetParams(
      address(pool),
      address(tok),
      1000,
      100,
      10_000,
      10_000,
      10_000,
      10_000,
      0,
      uint64(M.encodeB64(PX / 2, 18))
    );
    base.mint(USER, 30_000e18);
    vm.startPrank(USER);
    base.approve(address(pool), type(uint256).max);
    vm.expectRevert(); // Err.PriceOutsideReservation — tok mark (PX) > reservationPriceMax (PX/2)
    pool.swap(address(base), address(tok), 30_000e18, 0, USER, NO_DEADLINE);
    vm.stopPrank();
  }

  /// Audit fix: the depeg breaker guards the INPUT leg too, not just the output. A depegged asset
  /// (its mark outside its own band) can no longer be dumped INTO the pool to drain a healthy output.
  function test_reservation_band_halts_input_asset_swap() public {
    vm.prank(OWNER);
    // tok's own band (reservationPriceMax = PX/2) is violated by its live mark (PX).
    admin.setAssetParams(
      address(pool),
      address(tok),
      1000,
      100,
      10_000,
      10_000,
      10_000,
      10_000,
      0,
      uint64(M.encodeB64(PX / 2, 18))
    );
    tok.mint(USER, 10e18);
    vm.startPrank(USER);
    tok.approve(address(pool), type(uint256).max);
    vm.expectRevert(); // Err.PriceOutsideReservation — tok is the INPUT and fails its own band
    pool.swap(address(tok), address(base), 10e18, 0, USER, NO_DEADLINE);
    vm.stopPrank();
  }

  /// Audit fix: swapLiability is subject to the JIT flow cooldown, so deposit→swapLiability→withdraw
  /// cannot exit before the anti-JIT window. Fresh deposit + immediate liability swap reverts.
  function test_swapLiability_respects_flow_cooldown() public {
    // this contract deposited tok in setUp THIS block → lastDepositTime is now → cooldown active.
    uint256 lp = pool.getLPBalance(address(this), address(tok));
    vm.expectRevert(); // Err.CooldownActive
    pool.swapLiability(address(tok), address(base), lp / 10, 0, NO_DEADLINE);
    // after the cooldown it succeeds.
    skip(uint256(C.DEFAULT_FLOW_COOLDOWN) + 1);
    uint256 out = pool.swapLiability(address(tok), address(base), lp / 10, 0, NO_DEADLINE);
    assertGt(out, 0, "liability swap succeeds past the cooldown");
  }

  /// Feed-relative depeg band must fail-closed on a STALE reference feed: the quoting path
  /// freshness-gates only the asset's own feedId, so a dead refFeedId keeper would otherwise
  /// anchor the band to a corpse price (pass/halt against dead data).
  function test_refBand_stale_reference_feed_fails_closed() public {
    bytes32 refId = bytes32(uint256(0xB7C));
    MockOracle refOracle = new MockOracle();
    refOracle.setFeed(refId, M.encodeB64(PX, 18), 10_000, 0, 100); // short ttl → rots during timelock
    IPool.OracleConfig memory oc;
    oc.primary = address(oracle);
    oc.feedId = _feedId(address(tok));
    oc.refFeedId = refId;
    oc.refBandBps = 500;
    oc.refPrimary = address(refOracle);
    vm.startPrank(OWNER);
    admin.requestOracleUpdate(address(pool), address(tok), oc);
    vm.warp(block.timestamp + 2 days + 1); // BASE_TIMELOCK
    admin.executeOracleUpdate(address(pool), address(tok));
    vm.stopPrank();
    // Refresh the base + main feeds post-warp; the reference feed alone is left stale.
    oracle.setMark(address(base), M.encodeB64(1e18, 18));
    oracle.setFeed(_feedId(address(tok)), M.encodeB64(PX, 18), 10_000, 0, 3600);

    base.mint(USER, 6_000e18);
    vm.startPrank(USER);
    base.approve(address(pool), type(uint256).max);
    vm.expectPartialRevert(Err.StaleData.selector);
    pool.swap(address(base), address(tok), 3_000e18, 0, USER, NO_DEADLINE);

    // Fresh reference at parity → band passes, swap resumes.
    refOracle.setFeed(refId, M.encodeB64(PX, 18), 10_000, 0, 3600);
    uint256 out = pool.swap(address(base), address(tok), 3_000e18, 0, USER, NO_DEADLINE);
    assertGt(out, 0, "swap resumes once the reference feed is fresh");
    vm.stopPrank();
  }

  /// setAssetParams rejects minFee below MIN_FEE_PBPS (1 = 0.01 bp finest quantum).
  function test_MIN_FEE_PBPS_setAssetParams_reverts_below_floor() public {
    vm.prank(OWNER);
    vm.expectRevert(Err.InvalidInput.selector);
    admin.setAssetParams(address(pool), address(tok), 0, 0, 10_000, 10_000, 10_000, 10_000, 0, 0);
  }

  function test_MIN_FEE_PBPS_setAssetParams_accepts_floor() public {
    vm.prank(OWNER);
    admin.setAssetParams(
      address(pool), address(tok), 0, C.MIN_FEE_PBPS, 10_000, 10_000, 10_000, 10_000, 0, 0
    );
    assertEq(pool.getAsset(address(tok)).minFeePbps, C.MIN_FEE_PBPS);
  }

  /// 1 PBPS spread at σ=0 must still settle fees — halving spread before multiply would zero them.
  function test_MIN_FEE_PBPS_floor_spread_collects_fee() public {
    vm.prank(OWNER);
    admin.setAssetParams(
      address(pool), address(tok), 0, C.MIN_FEE_PBPS, 10_000, 10_000, 10_000, 10_000, 0, 0
    );
    oracle.setFeed(_feedId(address(tok)), M.encodeB64(PX, 18), 0, 0, 3600);
    IPool.SwapQuote memory q = pool.getSwapQuote(address(tok), address(base), 1000e18);
    assertEq(q.spreadPbps, C.MIN_FEE_PBPS);
    assertGt(q.lpFee + q.protoFee, 0, "1 PBPS floor must settle non-zero fees");
  }

  /// below the live mark blocks delivery of `tokenTo` reserves, not just the swap entrypoint.
  function test_reservation_band_halts_cross_withdraw() public {
    vm.prank(OWNER);
    admin.setAssetParams(
      address(pool),
      address(tok),
      1000,
      100,
      10_000,
      10_000,
      10_000,
      10_000,
      0,
      uint64(M.encodeB64(PX / 2, 18))
    );
    uint256 lp = pool.getLPBalance(address(this), address(base));
    skip(20);
    vm.expectRevert(); // Err.PriceOutsideReservation — tok mark (PX) > reservationPriceMax (PX/2)
    pool.withdrawTo(address(base), address(tok), lp / 10, 0, NO_DEADLINE);
  }

  /// Audit fix: cross-withdraw guards the INPUT (fromTk) band too, not just the output. The
  /// conversion is priced off fromTk's mark, so a fromTk whose mark sits above its own band must
  /// halt the withdrawal — else it over-delivers the healthy output and drains those LPs. Here
  /// tok (the LP-in asset) has reservationPriceMax=PX/2 violated by its live mark; base (out) is
  /// unbanded. Pre-fix only base was guarded → drain; post-fix tok's band reverts.
  function test_reservation_band_halts_cross_withdraw_input_asset() public {
    vm.prank(OWNER);
    admin.setAssetParams(
      address(pool),
      address(tok),
      1000,
      100,
      10_000,
      10_000,
      10_000,
      10_000,
      0,
      uint64(M.encodeB64(PX / 2, 18))
    );
    uint256 lp = pool.getLPBalance(address(this), address(tok)); // tok deposited in setUp
    skip(uint256(C.DEFAULT_FLOW_COOLDOWN) + 1); // clear JIT cooldown so only the band can revert
    vm.expectRevert(); // Err.PriceOutsideReservation — tok is the INPUT and fails its own band
    pool.withdrawTo(address(tok), address(base), lp / 10, 0, NO_DEADLINE);
  }

  /// Feed-relative band on cross-withdraw: stale refFeedId must fail-closed exactly like swap.
  function test_refBand_stale_reference_feed_halts_cross_withdraw() public {
    bytes32 refId = bytes32(uint256(0xB7D));
    MockOracle refOracle = new MockOracle();
    refOracle.setFeed(refId, M.encodeB64(PX, 18), 10_000, 0, 100);
    IPool.OracleConfig memory oc;
    oc.primary = address(oracle);
    oc.feedId = _feedId(address(tok));
    oc.refFeedId = refId;
    oc.refBandBps = 500;
    oc.refPrimary = address(refOracle);
    vm.startPrank(OWNER);
    admin.requestOracleUpdate(address(pool), address(tok), oc);
    vm.warp(block.timestamp + 2 days + 1);
    admin.executeOracleUpdate(address(pool), address(tok));
    vm.stopPrank();
    oracle.setMark(address(base), M.encodeB64(1e18, 18));
    oracle.setFeed(_feedId(address(tok)), M.encodeB64(PX, 18), 10_000, 0, 3600);

    uint256 lp = pool.getLPBalance(address(this), address(base));
    skip(20);
    vm.expectPartialRevert(Err.StaleData.selector);
    pool.withdrawTo(address(base), address(tok), lp / 10, 0, NO_DEADLINE);
  }

  /// @dev Arm tok's ref band (±5%) against `refP` via the timelocked oracle-update path, then
  ///      refresh the primary feeds post-warp. Shared by the refPrimary independence tests.
  function _armRefBand(address refP, bytes32 refId) internal {
    IPool.OracleConfig memory oc;
    oc.primary = address(oracle);
    oc.feedId = _feedId(address(tok));
    oc.refFeedId = refId;
    oc.refBandBps = 500;
    oc.refPrimary = refP;
    vm.startPrank(OWNER);
    admin.requestOracleUpdate(address(pool), address(tok), oc);
    vm.warp(block.timestamp + 2 days + 1);
    admin.executeOracleUpdate(address(pool), address(tok));
    vm.stopPrank();
    oracle.setMark(address(base), M.encodeB64(1e18, 18));
  }

  /// Layer-3 (Ostium hardening): the ref band reads refPrimary — an INDEPENDENT oracle instance —
  /// so a compromised push quorum walking the PRIMARY mark past refBandBps of the independent
  /// reference halts swaps (push-rate-independent cumulative bound); within-band trading continues.
  function test_refPrimary_independent_reference_bounds_walked_mark() public {
    MockOracle refOracle = new MockOracle(); // independent instance (distinct signer set on mainnet)
    bytes32 refId = bytes32(uint256(0xB7E));
    refOracle.setFeed(refId, M.encodeB64(PX, 18), 10_000, 0, type(uint16).max);
    _armRefBand(address(refOracle), refId);
    refOracle.setFeed(refId, M.encodeB64(PX, 18), 10_000, 0, type(uint16).max); // refresh post-warp

    base.mint(USER, 12_000e18);
    vm.startPrank(USER);
    base.approve(address(pool), type(uint256).max);
    // Walked mark: primary +10% while the independent reference holds → band (±5%) halts swaps.
    oracle.setFeed(_feedId(address(tok)), M.encodeB64((PX * 110) / 100, 18), 10_000, 0, 3600);
    vm.expectPartialRevert(Err.PriceOutsideReservation.selector);
    pool.swap(address(base), address(tok), 3_000e18, 0, USER, NO_DEADLINE);
    // Within band (+2%) → swap executes.
    oracle.setFeed(_feedId(address(tok)), M.encodeB64((PX * 102) / 100, 18), 10_000, 0, 3600);
    uint256 out = pool.swap(address(base), address(tok), 3_000e18, 0, USER, NO_DEADLINE);
    assertGt(out, 0, "within-band swap executes");
    vm.stopPrank();
  }

  /// refPrimary == 0 with the band armed FAIL-CLOSES (no self-ref fallback). Validation requires a
  /// distinct refPrimary whenever the band is armed, so this state is unreachable in production; the
  /// zero is written straight to storage to simulate pre-upgrade state and prove that even then a
  /// misconfigured zero halts swaps (reads off address(0) → revert) rather than silently self-comparing
  /// the mark against itself and disarming the depeg breaker (O-08 / L-04).
  function test_refPrimary_zero_failClosed() public {
    bytes32 refId = bytes32(uint256(0xB7F));
    MockOracle refOracle = new MockOracle();
    refOracle.setFeed(refId, M.encodeB64(PX, 18), 10_000, 0, type(uint16).max);
    oracle.setFeed(refId, M.encodeB64(PX, 18), 10_000, 0, type(uint16).max);
    _armRefBand(address(refOracle), refId);
    oracle.setFeed(refId, M.encodeB64(PX, 18), 10_000, 0, type(uint16).max); // refresh post-warp
    // Zero the refPrimary slot (OracleConfig slot 3: feedId=0, refFeedId=1, packed=2, refPrimary=3).
    bytes32 base_ = keccak256(abi.encode(address(tok), uint256(5))); // oracleConfigs mapping @ slot 5
    vm.store(address(pool), bytes32(uint256(base_) + 3), bytes32(0));

    base.mint(USER, 12_000e18);
    vm.startPrank(USER);
    base.approve(address(pool), type(uint256).max);
    // Even a perfectly in-band mark halts: the ref read targets address(0) → revert. No self-ref bypass.
    oracle.setFeed(_feedId(address(tok)), M.encodeB64((PX * 102) / 100, 18), 10_000, 0, 3600);
    vm.expectRevert();
    pool.swap(address(base), address(tok), 3_000e18, 0, USER, NO_DEADLINE);
    vm.stopPrank();
  }

  /// Sanity: a base->tok buy should cost >= TWAP per tok (buyer pays a spread), never a discount.
  function test_buy_never_discount() public {
    uint256 amtIn = 3000e18; // spend 3000 base, expect ~<=1 tok
    IPool.SwapQuote memory q = pool.getSwapQuote(address(base), address(tok), amtIn);
    // tok out per base in -> invert to base per tok
    require(q.amountOut > 0, "no out");
    uint256 avgPrice = (amtIn * 1e18) / q.amountOut; // base per tok
    assertGe(avgPrice, PX - PX / 100, "buy quoted a discount below TWAP");
  }
}
