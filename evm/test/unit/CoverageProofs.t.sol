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
import {Pricing} from "../../src/libraries/Pricing.sol";
import {Err} from "@btr-shared/Errors.sol";
import {MockAC, MockOracle} from "../fixtures/BaseTestSetup.sol";

/// @notice Machine-checked layer for AIMM_PROOFS.md (repo root): shared walled-pool fixture.
///         Each test anchors a theorem/lemma of the coverage-safety proof program; doc §9 maps
///         claim → test. Unit fuzzes hit Pricing._covToll/_covQ directly (internal); boundary
///         fuzzes + the invariant campaign exercise the same claims through Pool entrypoints.
abstract contract CoverageProofsBase is Test {
    uint256 constant BPS = 10_000;
    uint256 constant WAD = 1e18;

    PoolFactory factory; Pool poolImpl; Admin admin; Flash flash; MockAC ac;
    MockOracle oracle;
    Pool pool; MockERC20 base; MockERC20 tok;
    address constant OWNER = address(0xA11CE);
    address constant ATK = address(0xBADD);
    uint16 constant KAPPA = 15_000; // c* = 15000/25000 = 0.6
    uint256 constant SEED = 1_000_000e18;

    function _profile() internal pure returns (IPool.LiquidityProfile memory p) {
        p.weights[0] = 50; p.weights[1] = 50; p.weights[2] = 50; p.weights[3] = 50;
        p.knots[0] = -50; p.knots[1] = -25; p.knots[2] = 0; p.knots[3] = 25; p.knots[4] = 50;
    }

    function _risk(uint16 kappa) internal pure returns (IPool.RiskConfig memory r) {
        r.coverageMin = 5000;
        r.coverageMax = 20000;
        r.depthAmplifier = 0; // κ>0 ⊕ depthAmplifier>0 enforced at config (PoolAdmin.validateRiskConfig)
        r.kappaCovBps = kappa;
        r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
    }

    function _oc(address token) internal view returns (IPool.OracleConfig memory o) {
        o.primary = address(oracle);
        o.feedId = bytes32(uint256(uint160(token)));
    }

    function setUp() public virtual {
        ac = new MockAC(OWNER); admin = new Admin(address(ac)); flash = new Flash();
        PoolAux aux = new PoolAux(address(ac), address(admin), address(flash));
        poolImpl = new Pool(address(ac), address(admin), address(flash), address(aux));
        factory = new PoolFactory(address(poolImpl), address(this), address(ac));
        base = new MockERC20("Base", "BASE", 18); tok = new MockERC20("Tok", "TOK", 18);
        address[] memory toks = new address[](2); toks[0] = address(base); toks[1] = address(tok);
        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 25, flashFeeBps: 100, _pad: pad});
        bytes memory initd = abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
        pool = Pool(payable(factory.createPool(address(base), toks, initd)));
        oracle = new MockOracle();
        oracle.setMark(address(base), M.encodeB64(1e18, 18));
        oracle.setMark(address(tok), M.encodeB64(1e18, 18)); // stable pair: mark 1.0 (walled-asset regime)
        vm.startPrank(OWNER);
        admin.addAsset(address(pool), address(base), _oc(address(base)), _risk(0), _profile(), 1000, 18, 1000, 100000, 10000, 10000);
        admin.addAsset(address(pool), address(tok), _oc(address(tok)), _risk(KAPPA), _profile(), 1000, 18, 1000, 100000, 10000, 10000);
        // Lemma B policy: walled asset runs haircutSuppressor = 0 (coverage-neutral same-asset withdraw)
        admin.setAssetParams(address(pool), address(tok), 0, 1000, 10_000, 10_000, 10_000, 0, 0, 0);
        vm.stopPrank();
        base.mint(address(this), 10 * SEED); tok.mint(address(this), 10 * SEED);
        base.approve(address(pool), type(uint256).max);
        tok.approve(address(pool), type(uint256).max);
        pool.deposit(address(base), SEED);
        pool.deposit(address(tok), SEED);
    }

    function _cov(address token) internal view returns (uint256) {
        IPool.Asset memory a = pool.getAsset(token);
        if (a.liabilities == 0) return type(uint256).max;
        return (uint256(a.reserves) * WAD) / uint256(a.liabilities);
    }
}

contract CoverageProofsTest is CoverageProofsBase {
    // ── unit-level: Lemma C + Theorem 1 math, directly on the pure toll ──

    function _cache(uint128 r, uint128 l, uint16 kappa) internal pure returns (Pricing.EndpointCache memory c) {
        c.reserves = r;
        c.liabilities = l;
        c.kappaCovBps = kappa;
    }

    /// Bound fuzz inputs to a funded-pool domain where c₁ = (r−g)·WAD/l stays > 0 (below that the
    /// code fail-closes via lnWad(0) revert — asserted in test_toll_lnWad_fail_closed).
    function _boundDrain(uint128 r0, uint128 l, uint256 g)
        internal pure returns (uint128, uint128, uint256)
    {
        r0 = uint128(bound(r0, 1e12, 1e30));
        l = uint128(bound(l, 1e12, 1e30));
        uint256 keep = uint256(l) / WAD + 1; // ≥ this many units left ⇒ c₁ ≥ 1 (WAD-units) post-drain
        vm.assume(uint256(r0) > keep + 1);
        g = bound(g, 1, uint256(r0) - keep - 1);
        return (r0, l, g);
    }

    /// Lemma C: 0 ≤ T ≤ g, and κ=0 ⇒ T=0.
    function test_fuzz_toll_bounds(uint128 r0, uint128 l, uint256 g, uint16 kappa) public pure {
        (r0, l, g) = _boundDrain(r0, l, g);
        uint256 t = Pricing._covToll(_cache(r0, l, kappa), g);
        assertLe(t, g, "toll exceeds gross output");
        assertEq(Pricing._covToll(_cache(r0, l, 0), g), 0, "kappa=0 must be free");
    }

    /// Lemma C wall: g ≥ R ⇒ T = g (the fill is fully blocked, trader nets zero).
    function test_fuzz_toll_wall_blocks_full_drain(uint128 r0, uint128 l, uint256 g, uint16 kappa) public pure {
        r0 = uint128(bound(r0, 1, type(uint128).max));
        l = uint128(bound(l, 1, type(uint128).max));
        kappa = uint16(bound(kappa, 1, type(uint16).max));
        g = bound(g, r0, type(uint256).max);
        assertEq(Pricing._covToll(_cache(r0, l, kappa), g), g, "full drain must be fully tolled");
    }

    /// Lemma C charge-only: draining an over-covered leg toward the peg (c₁ ≥ 1 ⇒ dQ ≤ 0) is free.
    function test_fuzz_toll_charge_only_overcovered(uint128 l, uint256 g, uint16 kappa) public pure {
        l = uint128(bound(l, 1e12, 1e30));
        kappa = uint16(bound(kappa, 1, type(uint16).max));
        g = bound(g, 1, uint256(l));
        vm.assume(2 * uint256(l) + g <= type(uint128).max);
        uint128 r0 = uint128(2 * uint256(l) + g); // c₁ = (r0−g)/l = 2 > 1 ⇒ dQ < 0
        assertEq(Pricing._covToll(_cache(r0, l, kappa), g), 0, "over-covered drain toward peg must be free");
    }

    /// Lemma C monotonicity: T non-decreasing in gross size.
    function test_fuzz_toll_monotone_in_size(uint128 r0, uint128 l, uint256 g1, uint256 g2, uint16 kappa) public pure {
        (r0, l, g2) = _boundDrain(r0, l, g2);
        kappa = uint16(bound(kappa, 1, type(uint16).max));
        g1 = bound(g1, 1, g2);
        assertLe(
            Pricing._covToll(_cache(r0, l, kappa), g1),
            Pricing._covToll(_cache(r0, l, kappa), g2),
            "toll must be monotone in size"
        );
    }

    /// Theorem 1 (unit form): after one tolled drain with toll retention,
    /// c_after ≥ min(c_before, c*) − ε, c* = κ/(κ+BPS).
    function test_fuzz_coverage_floor_single_drain(uint128 r0, uint128 l, uint256 g, uint16 kappa) public pure {
        (r0, l, g) = _boundDrain(r0, l, g);
        kappa = uint16(bound(kappa, 1, type(uint16).max));
        uint256 t = Pricing._covToll(_cache(r0, l, kappa), g);
        uint256 r1 = uint256(r0) - (g - t); // net drain (fees only shrink it further, see PoolIO.exec)
        uint256 cBefore = (uint256(r0) * WAD) / l;
        uint256 cAfter = (r1 * WAD) / l;
        uint256 cStar = (uint256(kappa) * WAD) / (uint256(kappa) + BPS);
        uint256 floor_ = cBefore < cStar ? cBefore : cStar;
        uint256 eps = (8 * WAD) / uint256(l) + 8; // integer-rounding dust (doc §4)
        assertGe(cAfter + eps, floor_, "coverage fell below the convex-wall floor");
    }

    /// Theorem 1 induction step: floor survives a SEQUENCE of drains with toll retention.
    function test_fuzz_coverage_floor_sequence(uint128 r0, uint128 l, uint256 g1, uint256 g2, uint16 kappa) public pure {
        (r0, l, g1) = _boundDrain(r0, l, g1);
        kappa = uint16(bound(kappa, 1, type(uint16).max));
        uint256 cStar = (uint256(kappa) * WAD) / (uint256(kappa) + BPS);
        uint256 c0 = (uint256(r0) * WAD) / l;
        uint256 floor_ = c0 < cStar ? c0 : cStar;

        uint256 t1 = Pricing._covToll(_cache(r0, l, kappa), g1);
        uint256 r1 = uint256(r0) - (g1 - t1);
        uint256 keep = uint256(l) / WAD + 1;
        vm.assume(r1 > keep + 1);
        g2 = bound(g2, 1, r1 - keep - 1);
        uint256 t2 = Pricing._covToll(_cache(uint128(r1), l, kappa), g2);
        uint256 r2 = r1 - (g2 - t2);

        uint256 eps = (16 * WAD) / uint256(l) + 16;
        assertGe((r2 * WAD) / l + eps, floor_, "sequence broke the floor");
    }

    /// Fail-closed edge (Lemma C): a drain that floors c₁ to 0 in WAD reverts (lnWad domain)
    /// instead of under-tolling.
    function test_toll_lnWad_fail_closed() public {
        Pricing.EndpointCache memory c = _cache(uint128(100), uint128(200 * uint128(WAD)), 10_000);
        vm.expectRevert();
        this.extCovToll(c, 99); // leaves 1 unit; c₁ = WAD/200e18 → 0 → lnWad reverts
    }

    /// external trampoline so expectRevert scopes the library call
    function extCovToll(Pricing.EndpointCache memory c, uint256 g) external pure returns (uint256) {
        return Pricing._covToll(c, g);
    }

    // ── boundary-level: through the Pool ──

    /// Theorem 1 at the pool boundary: no swap size can push the walled asset below min(c₀, c*).
    function test_fuzz_coverage_floor_single_swap(uint256 amtIn) public {
        amtIn = bound(amtIn, 1e6, 5 * SEED);
        uint256 cBefore = _cov(address(tok));
        uint256 cStar = (uint256(KAPPA) * WAD) / (uint256(KAPPA) + BPS);
        uint256 floor_ = cBefore < cStar ? cBefore : cStar;
        base.mint(ATK, amtIn);
        vm.startPrank(ATK);
        base.approve(address(pool), type(uint256).max);
        try pool.swap(address(base), address(tok), amtIn, 0, ATK) {} catch {
            vm.stopPrank();
            return; // revert = fail-closed wall; floor trivially holds
        }
        vm.stopPrank();
        assertGe(_cov(address(tok)) + 1e9, floor_, "swap pushed coverage below the wall floor");
    }

    /// Theorem 2 at the pool boundary (generalizes PoolRepegExploit): round trip with the wall
    /// LIVE (κ>0) across fuzzed pre-drain (coverage state) and attack size never profits.
    function test_fuzz_roundtrip_never_profits(uint256 drainAmt, uint256 atkAmt) public {
        drainAmt = bound(drainAmt, 0, SEED / 2);
        atkAmt = bound(atkAmt, 1e12, SEED / 4);
        if (drainAmt > 0) {
            try pool.swap(address(base), address(tok), drainAmt, 0, address(this)) {} catch {}
        }
        tok.mint(ATK, atkAmt);
        vm.startPrank(ATK);
        tok.approve(address(pool), type(uint256).max);
        base.approve(address(pool), type(uint256).max);
        uint256 tokStart = tok.balanceOf(ATK);
        uint256 baseOut;
        try pool.swap(address(tok), address(base), atkAmt, 0, ATK) returns (uint256 o) {
            baseOut = o;
        } catch { vm.stopPrank(); return; }
        try pool.swap(address(base), address(tok), baseOut, 0, ATK) {} catch { vm.stopPrank(); return; }
        uint256 tokEnd = tok.balanceOf(ATK);
        vm.stopPrank();
        assertLe(tokEnd, tokStart, "round trip extracted value through the walled pricer");
    }

    /// Lemma A: a deposit on an under-covered asset strictly restores coverage toward 1.
    function test_deposit_restores_coverage() public {
        try pool.swap(address(base), address(tok), SEED / 3, 0, address(this)) {} catch {}
        uint256 cBefore = _cov(address(tok));
        if (cBefore >= WAD) return; // drain didn't take (fail-closed) — nothing to restore
        pool.deposit(address(tok), SEED / 10);
        uint256 cAfter = _cov(address(tok));
        assertGt(cAfter, cBefore, "deposit must raise coverage");
        assertLe(cAfter, WAD + 1, "deposit must not overshoot the peg");
    }

    /// Thm 2 assumption enforced in code (P3): the base numeraire can never carry the coverage wall.
    function test_base_kappa_rejected_at_addAsset() public {
        address[] memory toks = new address[](1);
        toks[0] = address(base);
        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 25, flashFeeBps: 100, _pad: pad});
        bytes memory initd = abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
        Pool p2 = Pool(payable(factory.createPool(address(base), toks, initd)));
        vm.prank(OWNER);
        vm.expectRevert(Err.BadConfig.selector); // base numeraire never walled
        admin.addAsset(address(p2), address(base), _oc(address(base)), _risk(KAPPA), _profile(), 1000, 18, 1000, 100000, 10000, 10000);
    }

    /// L-2: haircutSuppressor ≥ 20000 (zeroes the haircut → bank-run) is rejected at config.
    function test_haircutSuppressor_cap_rejected() public {
        vm.prank(OWNER);
        vm.expectRevert(Err.InvalidInput.selector);
        admin.setAssetParams(address(pool), address(tok), 0, 1000, 10_000, 10_000, 10_000, 20_000, 0, 0);
    }

    /// Audit fix: donate's liquidityIndex cast is checked — a donation large enough to overflow the
    /// uint64 index (which would silently corrupt every LP's share↔value mapping) reverts instead.
    function test_donate_liquidityIndex_overflow_reverts() public {
        // tok liability = SEED (1e24); first donate uses INIT index 1e12. newIndex = 1e12·(SEED+amt)/SEED;
        // exceeding 2^64 (~1.845e19) needs (SEED+amt)/SEED > ~1.845e7 ⇒ amt > ~1.845e31.
        uint256 huge = 2e31;
        tok.mint(address(this), huge);
        vm.expectRevert(); // Err.ExcessiveAmount(newIndex, type(uint64).max)
        pool.donate(address(tok), huge);
    }

    /// Lemma B: with haircutSuppressor = 0, same-asset withdrawal leaves coverage unchanged
    /// (the withdrawer takes exactly its pro-rata share of any deficit).
    function test_withdraw_coverage_neutral_when_suppressor_zero() public {
        try pool.swap(address(base), address(tok), SEED / 3, 0, address(this)) {} catch {}
        uint256 cBefore = _cov(address(tok));
        uint256 lp = pool.getLPBalance(address(this), address(tok));
        skip(30); // > DEFAULT_FLOW_COOLDOWN (15s); marks are ttl=max so no staleness
        pool.withdrawTo(address(tok), address(tok), lp / 5, 0);
        assertApproxEqAbs(_cov(address(tok)), cBefore, 1e6, "s=0 withdrawal must be coverage-neutral");
    }
}

/// @notice Random-op driver for the Theorem-1 invariant campaign. Reverts are swallowed —
///         fail-closed paths (wall, minLiquidity, cooldown) count as the floor holding.
contract CoverageFloorHandler is Test {
    Pool public pool;
    MockERC20 public base;
    MockERC20 public tok;
    uint256 constant SEED = 1_000_000e18;

    constructor(Pool _pool, MockERC20 _base, MockERC20 _tok) {
        pool = _pool; base = _base; tok = _tok;
        base.mint(address(this), 100 * SEED);
        tok.mint(address(this), 100 * SEED);
        base.approve(address(pool), type(uint256).max);
        tok.approve(address(pool), type(uint256).max);
    }

    function drainTok(uint256 amt) external {
        amt = bound(amt, 1e6, SEED);
        try pool.swap(address(base), address(tok), amt, 0, address(this)) {} catch {}
    }

    function refillTok(uint256 amt) external {
        amt = bound(amt, 1e6, SEED);
        try pool.swap(address(tok), address(base), amt, 0, address(this)) {} catch {}
    }

    function depositTok(uint256 amt) external {
        amt = bound(amt, 1e6, SEED / 10);
        try pool.deposit(address(tok), amt) {} catch {}
    }

    function withdrawTok(uint256 frac) external {
        frac = bound(frac, 1, 50);
        uint256 lp = pool.getLPBalance(address(this), address(tok));
        if (lp == 0) return;
        skip(30);
        try pool.withdrawTo(address(tok), address(tok), (lp * frac) / 100, 0) {} catch {}
    }
}

/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = false
contract CoverageFloorInvariantTest is CoverageProofsBase {
    CoverageFloorHandler handler;

    function setUp() public override {
        super.setUp();
        handler = new CoverageFloorHandler(pool, base, tok);
        targetContract(address(handler));
    }

    /// Theorem 1 over arbitrary op interleavings: c_tok ≥ min(c_initial=1, c*) − ε at every state.
    function invariant_coverage_floor() public view {
        uint256 cStar = (uint256(KAPPA) * WAD) / (uint256(KAPPA) + BPS);
        IPool.Asset memory a = pool.getAsset(address(tok));
        if (a.liabilities == 0) return;
        uint256 c = (uint256(a.reserves) * WAD) / uint256(a.liabilities);
        assertGe(c + 1e9, cStar, "invariant: coverage floor broken");
    }
}
