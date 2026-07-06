// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../../src/Pool.sol";
import {PoolAux} from "../../src/PoolAux.sol";
import {PoolFactory} from "../../src/PoolFactory.sol";
import {Admin} from "../../src/Admin.sol";
import {Flash} from "../../src/Flash.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {Constants as C} from "../../src/libraries/Constants.sol";
import {Maths as M} from "../../src/libraries/Maths.sol";
import {Err} from "@btr-shared/Errors.sol";
import {MockAC, MockOracle} from "../fixtures/BaseTestSetup.sol";

/// @title AimmInvariants
/// @notice Reproduction + invariant tests for the AIMM pricer at NON-UNITY price.
///         The existing suite seeds every asset at price=1.0 (PoolLifecycle.t.sol:93),
///         which masks: BUG-1 (reciprocal oracle push), BUG-2 (sell-premium sign flip),
///         BUG-3 (buy-side decimal underflow). These tests seed a $3000 asset so the
///         orientation/sign/decimal defects become observable. They are expected to
///         FAIL on the current code and pass once the pricer is corrected.
contract AimmInvariantsTest is Test {
    PoolFactory factory;
    Pool poolImpl;
    Admin admin;
    Flash flashSingleton;
    MockAC ac;
    MockOracle oracle;

    Pool pool;
    MockERC20 base;   // numeraire, 18d, price 1.0
    MockERC20 tok;    // volatile asset, 18d, price 3000 (base per tok)

    address constant OWNER = address(0xA11CE);
    address constant USER  = address(0xBEEF);
    uint8  constant PROTO_SHARE = 25;
    uint16 constant FLASH_FEE_BPS = 100;

    uint256 constant PX = 3000e18; // 3000 base per tok

    function _profile() internal pure returns (IPool.LiquidityProfile memory p) {
        p.weights[0] = 50; p.weights[1] = 50; p.weights[2] = 50; p.weights[3] = 50;
        p.knots[0] = -50; p.knots[1] = -25; p.knots[2] = 0; p.knots[3] = 25; p.knots[4] = 50;
    }

    function _risk() internal pure returns (IPool.RiskConfig memory r) {
        r.decayStartRatioBps = 5000;
        r.coverageMin = 5000;
        r.coverageMax = 20000;
        r.decaySlope = 0;
        r.depthAmplifier = 10000;
        r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
    }

    function _oracle(address token) internal view returns (IPool.OracleConfig memory o) {
        o.primary = address(oracle);
        o.feedId = bytes32(uint256(uint160(token)));
    }
    function _feedId(address token) internal pure returns (bytes32) { return bytes32(uint256(uint160(token))); }

    function setUp() public {
        ac = new MockAC(OWNER);
        admin = new Admin(address(ac));
        flashSingleton = new Flash();
        PoolAux poolAux = new PoolAux(address(ac), address(admin), address(flashSingleton));
        poolImpl = new Pool(address(ac), address(admin), address(flashSingleton), address(poolAux));
        factory = new PoolFactory(address(poolImpl), address(this), address(ac));

        base = new MockERC20("Base", "BASE", 18);
        tok  = new MockERC20("Tok",  "TOK",  18);

        address[] memory toks = new address[](2);
        toks[0] = address(base);
        toks[1] = address(tok);

        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: PROTO_SHARE, flashFeeBps: FLASH_FEE_BPS, _pad: pad});
        bytes memory initdata = abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
        pool = Pool(payable(factory.createPool(address(base), toks, initdata)));

        oracle = new MockOracle();
        oracle.setMark(address(base), M.encodeB64(1e18, 18));
        // tok: fresh mark 3000 (base per tok, NON-UNITY), σ=1%, CI=0, finite ttl for staleness tests.
        oracle.setFeed(_feedId(address(tok)), M.encodeB64(PX, 18), 10_000, 0, 3600);
        IPool.RiskConfig memory rc = _risk();
        IPool.LiquidityProfile memory pf = _profile();

        vm.startPrank(OWNER);
        admin.addAsset(address(pool), address(base), _oracle(address(base)), rc, pf, 1000, 18, 1000, 100000, 10000, 10000);
        admin.addAsset(address(pool), address(tok),  _oracle(address(tok)),  rc, pf, 1000, 18, 1000, 100000, 10000, 10000);
        vm.stopPrank();

        // Seed reserves: deep on both sides so swaps do not reserve-clamp.
        base.mint(address(this), 10_000_000e18);
        tok.mint(address(this), 10_000e18);
        base.approve(address(pool), type(uint256).max);
        tok.approve(address(pool), type(uint256).max);
        pool.deposit(address(base), 10_000_000e18); // $10M base
        pool.deposit(address(tok), 3_000e18);        // 3000 tok = $9M
    }

    /// Confidence surcharge: the feed's 1σ CI widens the quoted spread (uncertain marks priced
    /// defensively). With CI=0 the spread floors to minFee (σ·vega alone is small); a material CI
    /// must lift it above that floor. NB: the tx-scoped oracle TCache would serve a stale cached feed
    /// on a re-quote of the SAME token, so we assert against the known floor rather than re-quoting.
    function test_confidence_surcharge_widens_beyond_floor() public {
        uint16 floorFee = pool.getAsset(address(tok)).minFeeBps; // 0.1%
        oracle.setFeed(_feedId(address(tok)), M.encodeB64(PX, 18), 10_000, 200, 3600); // 2% CI
        IPool.SwapQuote memory q = pool.getSwapQuote(address(tok), address(base), 1e18);
        assertGt(q.spreadBps, floorFee, "confidence surcharge must widen beyond the minFee floor");
    }

    /// Confidence halt: a feed CI past MAX_CONFIDENCE_HALT_BPS (10%) fail-closes the swap path.
    function test_confidence_halt_reverts_past_cap() public {
        oracle.setFeed(_feedId(address(tok)), M.encodeB64(PX, 18), 10_000, C.MAX_CONFIDENCE_HALT_BPS + 1, 3600);
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
        // Grace = ttl/2 = 1800s: a mark aged UNDER the grace must NOT widen (flat-market / live-keeper
        // case — else we quote wide and lose flow for nothing).
        vm.warp(block.timestamp + 1500);
        IPool.SwapQuote memory qWithinGrace = pool.getSwapQuote(address(tok), address(base), 1e18);
        assertEq(qWithinGrace.spreadBps, qFresh.spreadBps, "within grace (age<ttl/2) the premium must stay OFF");
        // Past the grace (keeper missed its heartbeat) but under the ttl: widen (graceful degradation).
        vm.warp(block.timestamp + 1000); // total age 2500s: > 1800 grace, < 3600 ttl → excess 700s
        IPool.SwapQuote memory qStale = pool.getSwapQuote(address(tok), address(base), 1e18);
        assertGt(qStale.spreadBps, qFresh.spreadBps, "past grace the staleness premium must widen the spread");
        // NON-SATURATION: the premium must be a GENTLE ramp, not slam to maxFee the instant age>ttl/2.
        // Regression guard for the σ-scaling bug (raw σ·√excess with σ in PBPS saturated maxFee at 1s):
        // a larger excess must quote STRICTLY MORE — if it had saturated, both points would be equal.
        vm.warp(block.timestamp + 900); // total age 3400s: excess 1600s (> the 700s above, still < ttl)
        IPool.SwapQuote memory qMoreStale = pool.getSwapQuote(address(tok), address(base), 1e18);
        assertGt(qMoreStale.spreadBps, qStale.spreadBps, "premium must keep ramping (not saturated to maxFee)");
    }

    /// Depeg band: a swap whose OUTPUT asset mark sits outside its price band must revert (the
    /// reservationPrice / reservationPriceMax guard). Here max is set below tok's mark → buying tok halts.
    function test_reservation_band_halts_out_of_band_swap() public {
        vm.prank(OWNER);
        // ...reservationPrice=0 (no floor), reservationPriceMax = half the mark → tok mark is above it.
        admin.setAssetParams(address(pool), address(tok), 1000, 100, 10_000, 10_000, 10_000, 10_000, 0, uint64(M.encodeB64(PX / 2, 18)));
        base.mint(USER, 30_000e18);
        vm.startPrank(USER);
        base.approve(address(pool), type(uint256).max);
        vm.expectRevert(); // Err.PriceBelowReservation — tok mark (PX) > reservationPriceMax (PX/2)
        pool.swap(address(base), address(tok), 30_000e18, 0, USER);
        vm.stopPrank();
    }

    /// Feed-relative depeg band must fail-closed on a STALE reference feed: the quoting path
    /// freshness-gates only the asset's own feedId, so a dead refFeedId keeper would otherwise
    /// anchor the band to a corpse price (pass/halt against dead data).
    function test_refBand_stale_reference_feed_fails_closed() public {
        bytes32 refId = bytes32(uint256(0xB7C));
        oracle.setFeed(refId, M.encodeB64(PX, 18), 10_000, 0, 100); // short ttl → rots during timelock
        IPool.OracleConfig memory oc;
        oc.primary = address(oracle);
        oc.feedId = _feedId(address(tok));
        oc.refFeedId = refId;
        oc.refBandBps = 500;
        vm.startPrank(OWNER);
        admin.requestOracleUpdate(address(pool), address(tok), oc);
        vm.warp(block.timestamp + 2 days + 1); // BASE_TIMELOCK
        admin.executeOracleUpdate(address(pool), address(tok));
        vm.stopPrank();
        // Refresh the main feed post-warp; the reference feed is left stale (age >> ttl).
        oracle.setFeed(_feedId(address(tok)), M.encodeB64(PX, 18), 10_000, 0, 3600);

        base.mint(USER, 6_000e18);
        vm.startPrank(USER);
        base.approve(address(pool), type(uint256).max);
        vm.expectPartialRevert(Err.StaleData.selector);
        pool.swap(address(base), address(tok), 3_000e18, 0, USER);

        // Fresh reference at parity → band passes, swap resumes.
        oracle.setFeed(refId, M.encodeB64(PX, 18), 10_000, 0, 3600);
        uint256 out = pool.swap(address(base), address(tok), 3_000e18, 0, USER);
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
        admin.setAssetParams(address(pool), address(tok), 0, C.MIN_FEE_PBPS, 10_000, 10_000, 10_000, 10_000, 0, 0);
        assertEq(pool.getAsset(address(tok)).minFeeBps, C.MIN_FEE_PBPS);
    }

    /// 1 PBPS spread at σ=0 must still settle fees — halving spread before multiply would zero them.
    function test_MIN_FEE_PBPS_floor_spread_collects_fee() public {
        vm.prank(OWNER);
        admin.setAssetParams(address(pool), address(tok), 0, C.MIN_FEE_PBPS, 10_000, 10_000, 10_000, 10_000, 0, 0);
        oracle.setFeed(_feedId(address(tok)), M.encodeB64(PX, 18), 0, 0, 3600);
        IPool.SwapQuote memory q = pool.getSwapQuote(address(tok), address(base), 1000e18);
        assertEq(q.spreadBps, C.MIN_FEE_PBPS);
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
        vm.expectRevert(); // Err.PriceBelowReservation — tok mark (PX) > reservationPriceMax (PX/2)
        pool.withdrawTo(address(base), address(tok), lp / 10, 0);
    }

    /// Feed-relative band on cross-withdraw: stale refFeedId must fail-closed exactly like swap.
    function test_refBand_stale_reference_feed_halts_cross_withdraw() public {
        bytes32 refId = bytes32(uint256(0xB7D));
        oracle.setFeed(refId, M.encodeB64(PX, 18), 10_000, 0, 100);
        IPool.OracleConfig memory oc;
        oc.primary = address(oracle);
        oc.feedId = _feedId(address(tok));
        oc.refFeedId = refId;
        oc.refBandBps = 500;
        vm.startPrank(OWNER);
        admin.requestOracleUpdate(address(pool), address(tok), oc);
        vm.warp(block.timestamp + 2 days + 1);
        admin.executeOracleUpdate(address(pool), address(tok));
        vm.stopPrank();
        oracle.setFeed(_feedId(address(tok)), M.encodeB64(PX, 18), 10_000, 0, 3600);

        uint256 lp = pool.getLPBalance(address(this), address(base));
        skip(20);
        vm.expectPartialRevert(Err.StaleData.selector);
        pool.withdrawTo(address(base), address(tok), lp / 10, 0);
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
