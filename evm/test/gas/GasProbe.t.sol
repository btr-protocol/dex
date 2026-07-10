// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

// GAS PROBE — per-component swap gas attribution (profiling only; no invariants beyond sanity).
// Fixture mirrors test/unit/CrossBaseImpact.t.sol: usdc(base) + usdt/usd1 spokes, all marks 1.0,
// 10M seed each. Every test = fresh tx => COLD storage/accounts (prod-like); in-test repeats give
// the warm delta (NOTE: same-tx repeat also hits the TransientCache oracle feed cache + warm
// reentrancy-guard slots, which prod txs would NOT share — stated in the report).
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "../../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../../src/Pool.sol";
import {PoolAux} from "../../src/PoolAux.sol";
import {PoolFactory} from "../../src/PoolFactory.sol";
import {Admin} from "../../src/Admin.sol";
import {Flash} from "../../src/Flash.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {Constants as C} from "../../src/libraries/Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Maths as M} from "../../src/libraries/Maths.sol";
import {Pricing} from "../../src/libraries/Pricing.sol";
import {Spline} from "../../src/libraries/Spline.sol";
import {MockAC, MockOracle} from "../fixtures/BaseTestSetup.sol";

/// @dev Internal-component harness: holds the SAME LiquidityProfile as the pool fixture in its own
///      storage and times Pricing/Spline internals with the QuarticProto gasleft() pattern.
contract PricingHarness {
    IPool.LiquidityProfile internal profile;

    constructor(IPool.LiquidityProfile memory p) { profile = p; }

    function noop() external pure returns (uint256) { return 1; }

    function gBuildPoints(uint32 disp) external view returns (uint256 g, uint256 n) {
        uint256 g0 = gasleft();
        Spline.Point[] memory pts = Pricing._buildSplinePoints(profile, disp);
        g = g0 - gasleft();
        n = pts.length;
    }

    function gEval(uint32 disp, uint256 x) external view returns (uint256 g, int256 y) {
        Spline.Point[] memory pts = Pricing._buildSplinePoints(profile, disp);
        uint256 g0 = gasleft();
        y = Spline.eval(x, pts);
        g = g0 - gasleft();
    }

    function gArea(uint32 disp, uint256 lo, uint256 hi) external view returns (uint256 g, int256 a) {
        Spline.Point[] memory pts = Pricing._buildSplinePoints(profile, disp);
        uint256 g0 = gasleft();
        a = Spline.area(pts, lo, hi);
        g = g0 - gasleft();
    }

    /// @dev Full sell-leg math = Pricing.quoteSwap (depth + dispersion + traversal + mul).
    function gQuoteSwapSell(uint256 amtIn, uint128 res, uint128 liab)
        external view returns (uint256 g, uint256 out)
    {
        uint256 g0 = gasleft();
        (out,) = Pricing.quoteSwap(
            amtIn, res, liab, 1e18, uint32(SC.ONE_PCT_PBPS), profile, 0, true, 10000, 10000, 1000, 100000
        );
        g = g0 - gasleft();
    }

    /// @dev Sell-side spline traversal only (points build + area + floors).
    function gTraverse(uint256 amtIn, uint256 depth, bool selling)
        external view returns (uint256 g, uint256 px)
    {
        uint256 g0 = gasleft();
        px = Pricing._traverseSplineByVolume(1e18, 1010, profile, 0, amtIn, depth, selling);
        g = g0 - gasleft();
    }

    /// @dev Buy-leg mid estimate (spline EVAL path inside _getMidPriceFromProfile).
    function gMid() external view returns (uint256 g, uint256 px) {
        uint256 g0 = gasleft();
        px = Pricing._getMidPriceFromProfile(1e18, 0, 1010, profile);
        g = g0 - gasleft();
    }

    function gSkew(uint128 res, uint128 liab) external view returns (uint256 g, int8 s) {
        uint256 g0 = gasleft();
        s = Pricing.computeInventorySkew(res, liab, 5000, 20000, 10000);
        g = g0 - gasleft();
    }

    function gCovToll(uint128 res, uint128 liab, uint16 kappa, uint256 grossOut)
        external view returns (uint256 g, uint256 toll)
    {
        Pricing.EndpointCache memory c;
        c.reserves = res;
        c.liabilities = liab;
        c.kappaCovBps = kappa;
        uint256 g0 = gasleft();
        toll = Pricing._covToll(c, grossOut);
        g = g0 - gasleft();
    }

    function gDepth(uint128 res, uint128 liab) external view returns (uint256 g, uint256 d) {
        uint256 g0 = gasleft();
        d = Pricing.calculateDepth(res, liab, 10000);
        g = g0 - gasleft();
    }

    function gSplitFee(uint256 fee) external view returns (uint256 g, uint256 p, uint256 l) {
        uint256 g0 = gasleft();
        (p, l) = Pricing.splitFee(fee, 25);
        g = g0 - gasleft();
    }
}

contract GasProbeTest is Test {
    PoolFactory factory;
    Admin admin;
    MockAC ac;
    MockOracle oracle;
    Pool pool;       // EIP-1167 clone (prod shape)
    Pool poolDirect; // direct deployment (no clone hop) — isolates the proxy cost
    PricingHarness harness;

    MockERC20 usdc; // base / hub
    MockERC20 usdt; // spoke 1
    MockERC20 usd1; // spoke 2

    address constant OWNER = address(0xA11CE);
    address constant USER = address(0xBEEF);
    uint256 constant SEED = 10_000_000e18;
    uint256 constant AMT = 10_000e18; // 0.1% of depth

    function _profile() internal pure returns (IPool.LiquidityProfile memory p) {
        p.weights[0] = 50; p.weights[1] = 50; p.weights[2] = 50; p.weights[3] = 50;
        p.knots[0] = -50; p.knots[1] = -25; p.knots[2] = 0; p.knots[3] = 25; p.knots[4] = 50;
    }

    function _risk() internal pure returns (IPool.RiskConfig memory r) {
        r.decayStartRatioBps = 5000;
        r.coverageMin = 5000;
        r.coverageMax = 20000;
        r.depthAmplifier = 10000;
        r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
    }

    function _oracleCfg(address token) internal view returns (IPool.OracleConfig memory o) {
        o.primary = address(oracle);
        o.feedId = bytes32(uint256(uint160(token)));
    }

    /// @dev Direct pool initializes with $.factory = this test => adminInitAsset best-effort syncs
    ///      the "factory" discovery index by calling this. No-op sink.
    function registerTokens(address[] calldata) external {}

    function setUp() public {
        ac = new MockAC(OWNER);
        admin = new Admin(address(ac));
        Flash flash = new Flash();
        PoolAux poolAux = new PoolAux(address(ac), address(admin), address(flash));
        Pool poolImpl = new Pool(address(ac), address(admin), address(flash), address(poolAux));
        factory = new PoolFactory(address(poolImpl), address(this), address(ac));

        usdc = new MockERC20("USDC", "USDC", 18);
        usdt = new MockERC20("USDT", "USDT", 18);
        usd1 = new MockERC20("USD1", "USD1", 18);

        address[] memory toks = new address[](3);
        toks[0] = address(usdc); toks[1] = address(usdt); toks[2] = address(usd1);

        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 25, flashFeeBps: 100, _pad: pad});
        bytes memory initdata =
            abi.encodeWithSelector(Pool.initialize.selector, address(usdc), address(0xCAFE), fp);
        pool = Pool(payable(factory.createPool(address(usdc), toks, initdata)));

        // Direct (non-clone) twin — same impl bytecode, same config, no EIP-1167 hop.
        poolDirect = new Pool(address(ac), address(admin), address(flash), address(poolAux));
        poolDirect.initialize(address(usdc), address(0xCAFE), fp);

        oracle = new MockOracle();
        oracle.setMark(address(usdc), M.encodeB64(1e18, 18));
        oracle.setMark(address(usdt), M.encodeB64(1e18, 18));
        oracle.setMark(address(usd1), M.encodeB64(1e18, 18));

        vm.startPrank(OWNER);
        for (uint256 p = 0; p < 2; p++) {
            address tgt = p == 0 ? address(pool) : address(poolDirect);
            admin.addAsset(tgt, address(usdc), _oracleCfg(address(usdc)), _risk(), _profile(), 1000, 18, 1000, 100000, 10000, 10000);
            admin.addAsset(tgt, address(usdt), _oracleCfg(address(usdt)), _risk(), _profile(), 1000, 18, 1000, 100000, 10000, 10000);
            admin.addAsset(tgt, address(usd1), _oracleCfg(address(usd1)), _risk(), _profile(), 1000, 18, 1000, 100000, 10000, 10000);
        }
        vm.stopPrank();

        _seed(pool, usdc); _seed(pool, usdt); _seed(pool, usd1);
        _seed(poolDirect, usdc); _seed(poolDirect, usdt); _seed(poolDirect, usd1);

        // USER pre-approved in setUp (separate tx) => allowance slot pre-existing, like prod.
        deal(address(usdc), USER, 1_000_000e18);
        deal(address(usdt), USER, 1_000_000e18);
        deal(address(usd1), USER, 1_000_000e18);
        vm.startPrank(USER);
        usdc.approve(address(pool), type(uint256).max);
        usdt.approve(address(pool), type(uint256).max);
        usd1.approve(address(pool), type(uint256).max);
        usdc.approve(address(poolDirect), type(uint256).max);
        usdt.approve(address(poolDirect), type(uint256).max);
        usd1.approve(address(poolDirect), type(uint256).max);
        usdt.approve(address(this), type(uint256).max); // for the raw transferFrom probe
        vm.stopPrank();

        harness = new PricingHarness(_profile());
    }

    function _seed(Pool p, MockERC20 tk) internal {
        tk.mint(address(this), SEED);
        tk.approve(address(p), type(uint256).max);
        p.deposit(address(tk), SEED);
    }

    // ── measurement helpers ──────────────────────────────────────────────────

    function _gswap(Pool p, address tin, address tout) internal returns (uint256 g) {
        vm.prank(USER);
        uint256 g0 = gasleft();
        p.swap(tin, tout, AMT, 0, USER);
        g = g0 - gasleft();
    }

    function _gquote(Pool p, address tin, address tout) internal view returns (uint256 g) {
        uint256 g0 = gasleft();
        p.getSwapQuote(tin, tout, AMT);
        g = g0 - gasleft();
    }

    // ── pool-level probes (each test = fresh cold tx) ────────────────────────

    function test_gas_swap_base_to_spoke() public {
        uint256 cold = _gswap(pool, address(usdc), address(usdt));
        uint256 warm = _gswap(pool, address(usdc), address(usdt));
        uint256 warm2 = _gswap(pool, address(usdc), address(usdt));
        console2.log("PROBE swap_base_spoke_cold", cold);
        console2.log("PROBE swap_base_spoke_warm", warm);
        console2.log("PROBE swap_base_spoke_warm2", warm2);
    }

    function test_gas_swap_spoke_to_base() public {
        uint256 cold = _gswap(pool, address(usdt), address(usdc));
        uint256 warm = _gswap(pool, address(usdt), address(usdc));
        uint256 warm2 = _gswap(pool, address(usdt), address(usdc));
        console2.log("PROBE swap_spoke_base_cold", cold);
        console2.log("PROBE swap_spoke_base_warm", warm);
        console2.log("PROBE swap_spoke_base_warm2", warm2);
    }

    function test_gas_swap_spoke_to_spoke() public {
        uint256 cold = _gswap(pool, address(usdt), address(usd1));
        uint256 warm = _gswap(pool, address(usdt), address(usd1));
        uint256 warm2 = _gswap(pool, address(usdt), address(usd1));
        console2.log("PROBE swap_spoke_spoke_cold", cold);
        console2.log("PROBE swap_spoke_spoke_warm", warm);
        console2.log("PROBE swap_spoke_spoke_warm2", warm2);
    }

    /// @dev Same swap, direct (non-clone) pool => cold-swap delta vs clone = EIP-1167 hop
    ///      (cold impl account access + delegatecall + calldata/returndata copies).
    function test_gas_swap_direct_pool() public {
        uint256 crossD = _gswap(poolDirect, address(usdt), address(usd1));
        console2.log("PROBE swap_spoke_spoke_direct_cold", crossD);
        uint256 singleD = _gswap(poolDirect, address(usdc), address(usdt));
        console2.log("PROBE swap_base_spoke_directWARMISH", singleD); // shares slots w/ cross: not cold
    }

    function test_gas_swap_direct_pool_single() public {
        uint256 singleD = _gswap(poolDirect, address(usdc), address(usdt));
        console2.log("PROBE swap_base_spoke_direct_cold", singleD);
    }

    /// @dev Clone-hop lower bound via a trivial view: baseToken() on clone vs direct.
    function test_gas_clone_hop_view() public view {
        uint256 g0 = gasleft();
        pool.baseToken();
        uint256 gClone = g0 - gasleft();
        g0 = gasleft();
        poolDirect.baseToken();
        uint256 gDirect = g0 - gasleft();
        g0 = gasleft();
        pool.baseToken();
        uint256 gCloneWarm = g0 - gasleft();
        g0 = gasleft();
        poolDirect.baseToken();
        uint256 gDirectWarm = g0 - gasleft();
        console2.log("PROBE view_baseToken_clone_cold", gClone);
        console2.log("PROBE view_baseToken_direct_cold", gDirect);
        console2.log("PROBE view_baseToken_clone_warm", gCloneWarm);
        console2.log("PROBE view_baseToken_direct_warm", gDirectWarm);
    }

    function test_gas_quote_base_to_spoke() public view {
        uint256 cold = _gquote(pool, address(usdc), address(usdt));
        uint256 warm = _gquote(pool, address(usdc), address(usdt));
        console2.log("PROBE quote_base_spoke_cold", cold);
        console2.log("PROBE quote_base_spoke_warm", warm);
    }

    function test_gas_quote_spoke_to_base() public view {
        uint256 cold = _gquote(pool, address(usdt), address(usdc));
        uint256 warm = _gquote(pool, address(usdt), address(usdc));
        console2.log("PROBE quote_spoke_base_cold", cold);
        console2.log("PROBE quote_spoke_base_warm", warm);
    }

    function test_gas_quote_spoke_to_spoke() public view {
        uint256 cold = _gquote(pool, address(usdt), address(usd1));
        uint256 warm = _gquote(pool, address(usdt), address(usd1));
        console2.log("PROBE quote_spoke_spoke_cold", cold);
        console2.log("PROBE quote_spoke_spoke_warm", warm);
    }

    // ── boundary-call probes ─────────────────────────────────────────────────

    function test_gas_oracle_getFeed() public view {
        bytes32 id = oracle.feedIdFor(address(usdt));
        uint256 g0 = gasleft();
        oracle.getFeed(id);
        uint256 cold = g0 - gasleft();
        g0 = gasleft();
        oracle.getFeed(id);
        uint256 warm = g0 - gasleft();
        console2.log("PROBE oracle_getFeed_cold", cold);
        console2.log("PROBE oracle_getFeed_warm", warm);
    }

    function test_gas_erc20_ops() public {
        // transferFrom USER -> this (allowance = max => no allowance SSTORE in solady)
        uint256 g0 = gasleft();
        usdt.transferFrom(USER, address(this), AMT);
        uint256 gTF = g0 - gasleft();
        // plain transfer this -> USER (both balance slots now warm)
        g0 = gasleft();
        usdt.transfer(USER, AMT);
        uint256 gT = g0 - gasleft();
        // balanceOf (warm account, cold-ish slot? pool slot untouched this tx)
        g0 = gasleft();
        usdt.balanceOf(address(pool));
        uint256 gB = g0 - gasleft();
        g0 = gasleft();
        usdt.balanceOf(address(pool));
        uint256 gBw = g0 - gasleft();
        console2.log("PROBE erc20_transferFrom_cold", gTF);
        console2.log("PROBE erc20_transfer_warmslots", gT);
        console2.log("PROBE erc20_balanceOf_coldslot", gB);
        console2.log("PROBE erc20_balanceOf_warm", gBw);
    }

    // ── internal pricing components (harness; call twice: cold/warm profile slots) ──

    function test_gas_pricing_components() public view {
        harness.noop(); // warm harness account
        uint256 depthV;
        { (, depthV) = harness.gDepth(uint128(SEED), uint128(SEED)); }

        (uint256 g1,) = harness.gBuildPoints(1010);   // cold profile slots
        (uint256 g1w,) = harness.gBuildPoints(1010);  // warm
        (uint256 g2,) = harness.gEval(1010, 5000);
        (uint256 g3,) = harness.gArea(1010, 4950, 5000);
        (uint256 g4,) = harness.gTraverse(AMT, depthV, true);
        (uint256 g5,) = harness.gTraverse(AMT, depthV, false);
        (uint256 g6,) = harness.gMid();
        (uint256 g7,) = harness.gQuoteSwapSell(AMT, uint128(SEED), uint128(SEED));
        (uint256 g8,) = harness.gSkew(uint128(SEED), uint128(SEED));
        (uint256 g9,) = harness.gCovToll(uint128(9_000_000e18), uint128(SEED), 1000, AMT);
        (uint256 g9z,) = harness.gCovToll(uint128(9_000_000e18), uint128(SEED), 0, AMT);
        (uint256 g10,) = harness.gDepth(uint128(SEED), uint128(SEED));
        (uint256 g11,,) = harness.gSplitFee(1e18);

        console2.log("PROBE prc_buildPoints_cold", g1);
        console2.log("PROBE prc_buildPoints_warm", g1w);
        console2.log("PROBE prc_splineEval", g2);
        console2.log("PROBE prc_splineArea_50w", g3);
        console2.log("PROBE prc_traverseSell", g4);
        console2.log("PROBE prc_traverseBuy", g5);
        console2.log("PROBE prc_midFromProfile", g6);
        console2.log("PROBE prc_quoteSwapSell_full", g7);
        console2.log("PROBE prc_inventorySkew", g8);
        console2.log("PROBE prc_covToll_k1000", g9);
        console2.log("PROBE prc_covToll_k0", g9z);
        console2.log("PROBE prc_calculateDepth", g10);
        console2.log("PROBE prc_splitFee", g11);
    }

    // sanity: fixture actually swaps
    function test_probe_sanity() public {
        vm.prank(USER);
        uint256 out = pool.swap(address(usdt), address(usd1), AMT, 0, USER);
        assertGt(out, 0, "cross swap outputs");
        vm.prank(USER);
        uint256 out2 = poolDirect.swap(address(usdt), address(usd1), AMT, 0, USER);
        assertGt(out2, 0, "direct pool cross swap outputs");
    }
}
