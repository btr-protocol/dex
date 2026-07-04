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
import {MockAC} from "../fixtures/BaseTestSetup.sol";

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

    function _oracle() internal view returns (IPool.OracleConfig memory o) {
        o.primary = address(pool);
        o.secondary = address(0);
        o.feedId = bytes32(0);
        o.modeFlags = C.MODE_USE_INTERNAL;
        o.accDecimals = 18;
    }

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

        IPool.OracleConfig memory oc = _oracle();
        IPool.RiskConfig memory rc = _risk();
        IPool.LiquidityProfile memory pf = _profile();

        vm.startPrank(OWNER);
        // base: price 1.0
        admin.addAsset(address(pool), address(base), oc, rc, pf, 1000, 18, M.encodeB64(1e18, 18), 10_000, 10_000, 1000, 100000, 10000, 10000, 10000);
        // tok: price 3000 (base per tok)  <-- NON-UNITY: this is what unmasks the bugs
        admin.addAsset(address(pool), address(tok), oc, rc, pf, 1000, 18, M.encodeB64(PX, 18), 10_000, 10_000, 1000, 100000, 10000, 10000, 10000);
        vm.stopPrank();

        // Seed reserves: deep on both sides so swaps do not reserve-clamp.
        base.mint(address(this), 10_000_000e18);
        tok.mint(address(this), 10_000e18);
        base.approve(address(pool), type(uint256).max);
        tok.approve(address(pool), type(uint256).max);
        pool.deposit(address(base), 10_000_000e18); // $10M base
        pool.deposit(address(tok), 3_000e18);        // 3000 tok = $9M
    }

    /// BUG-1: after a base->tok BUY, the tok internal mark must still read ~3000 (base per tok),
    /// not its reciprocal ~1/3000. midPrice() returns the raw stored lastPriceB64.
    function test_bug1_oracle_orientation_after_buy() public {
        uint256 pre = pool.midPrice(address(tok));
        assertApproxEqRel(pre, PX, 0.01e18, "seed mark should be ~3000");

        // Escape the per-block 1-update/token TWAP rate-limit so the swap actually pushes the mark.
        vm.roll(block.number + 1);
        skip(301);

        base.mint(USER, 30_000e18);
        vm.startPrank(USER);
        base.approve(address(pool), type(uint256).max);
        pool.swap(address(base), address(tok), 30_000e18, 0, USER); // buy ~10 tok
        vm.stopPrank();

        // BUG-1: a base->tok BUY must leave the tok mark denominated base-per-tok (~3000),
        // not its reciprocal (~1/3000). Pre-fix this flipped to ~3.33e14.
        uint256 post = pool.midPrice(address(tok));
        assertApproxEqRel(post, PX, 0.20e18, "BUG-1: tok mark flipped to reciprocal after buy");
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
