// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/modules/Pool.sol";
import {Admin} from "../src/Admin.sol";
import {InternalOracle} from "../src/modules/InternalOracle.sol";
import {PoolProxy} from "../src/PoolProxy.sol";
import {PoolProxyFactory} from "../src/PoolProxyFactory.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IAdmin} from "../src/interfaces/IAdmin.sol";
import {IPoolModule} from "../src/interfaces/modules/IPool.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {Maths as M} from "../src/libraries/Maths.sol";
import {MockAC} from "./fixtures/BaseTestSetup.sol";

/// @title Phase42CR8Test
/// @notice R8 HIGH (A1-R8-1): structural conservation — quote-side q.protoFee was credited
///         to ledger without being carved from reserves. Pre-existing bug invisible to the
///         R6 harness (which bypasses Pricing.getAnchorPathQuote, leaving q.protoFee = 0).
///
/// @dev    Real factory integration test:
///           - Deploy via REAL PoolProxyFactory.createPool
///           - Configure assets via REAL Admin.addAsset (delegates through proxy)
///           - Configure oracle feeds via REAL InternalOracle.updateFeed
///           - Configure protoShare via real PoolProxy.initialize FeeParams
///           - Perform real swap() — exercises Pricing.getAnchorPathQuote → non-zero q.protoFee
///           - Assert pool balance invariant: balanceOf(pool) == Σreserves + Σprotocolfees
///             post-swap AND post-collect.
contract Phase42CR8Test is Test {
    PoolProxyFactory factory;
    Pool poolImpl;
    Admin admin;
    InternalOracle oracleImpl;
    PoolProxy refProxy;
    PoolProxy proxy;

    MockERC20 base;   // base token
    MockERC20 quote;  // non-base, anchored to base
    MockAC ac;

    address constant OWNER = address(0xA11CE);
    address constant USER = address(0xBEEF);
    address constant TREASURY = address(0x7EA);
    uint8 constant PROTO_SHARE = 25;

    // ── Module selector lists ──
    function _poolSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = Pool.deposit.selector;
        s[1] = Pool.swap.selector;
        s[2] = Pool.getAsset.selector;
        s[3] = Pool.getProtocolFees.selector;
        s[4] = Pool.baseToken.selector;
        s[5] = Pool.owner.selector;
        s[6] = Pool.getMidPrice.selector;
        s[7] = Pool.adminInitAsset.selector;
        s[8] = Pool.adminCollectProtocolFees.selector;
        s[9] = Pool.treasury.selector;
    }

    function _oracleSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = InternalOracle.updateFeed.selector;
        s[1] = InternalOracle.pushFeedInternal.selector;
    }

    /// @dev Register a module's selectors directly on the proxy via vm.store.
    ///      Bypasses the trust/timelock flow (factory is DEPLOYER, not test contract).
    function _registerModule(address proxyAddr, address impl, bytes4[] memory sels) internal {
        uint256 modulesSlot = uint256(C.CORE_STORAGE_LOC) + 13;
        for (uint256 i = 0; i < sels.length; ++i) {
            bytes32 slot = keccak256(abi.encode(sels[i], modulesSlot));
            vm.store(proxyAddr, slot, bytes32(uint256(uint160(impl))));
        }
    }

    /// @dev Set $.treasury (slot 4, packed with `initialized` bool in high byte).
    function _setTreasury(address proxyAddr, address t) internal {
        bytes32 slot4 = vm.load(proxyAddr, bytes32(uint256(C.CORE_STORAGE_LOC) + 4));
        // Preserve high byte (initialized), set low 20 bytes (treasury).
        uint256 cleared = uint256(slot4) & ~uint256(type(uint160).max);
        uint256 packed = cleared | uint256(uint160(t));
        vm.store(proxyAddr, bytes32(uint256(C.CORE_STORAGE_LOC) + 4), bytes32(packed));
    }

    function _defaultProfile() internal pure returns (IPool.LiquidityProfile memory p) {
        // Uniform 200-weighted profile: 4 segments of weight 50 each, knots [-50,-25,0,25,50].
        p.weights[0] = 50; p.weights[1] = 50; p.weights[2] = 50; p.weights[3] = 50;
        p.knots[0] = -50; p.knots[1] = -25; p.knots[2] = 0; p.knots[3] = 25; p.knots[4] = 50;
    }

    function _defaultRisk() internal pure returns (IPool.RiskConfig memory r) {
        r.decayStartRatioBps = 5000;
        r.coverageMin = 5000;
        r.coverageMax = 20000;
        r.decaySlope = 0;
        r.depthAmplifier = 10000;
        r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
    }

    function _oracleCfg(bool isBase) internal view returns (IPool.OracleConfig memory o) {
        // primary = address(this) wrt the proxy means InternalOracle module.
        o.primary = address(proxy);
        o.secondary = address(0);
        o.feedId = bytes32(0);
        o.modeFlags = C.MODE_USE_INTERNAL;
        o.accDecimals = 18;
        // unused for base — wiring just needs to validate.
        isBase;
    }

    function setUp() public {
        // 1. Deploy module impls + shared AC + singleton Admin (Phase 42H.B.3a).
        ac = new MockAC(OWNER);
        admin = new Admin(address(ac));
        // Phase 42H.B.3b: Pool ctor now takes (ac, admin, staking). Tests not exercising staking
        // can pass a sentinel non-zero address.
        poolImpl = new Pool(address(ac), address(admin), address(0xC0FFEE), address(0xF1A571));
        oracleImpl = new InternalOracle(address(ac));

        // 2. Deploy a PoolProxy reference (minimal proxies delegatecall its code).
        refProxy = new PoolProxy();

        // 3. Deploy factory with refProxy as reference (NOT a module impl — the proxy IS
        //    the diamond router; minimal proxies need to inherit its fallback dispatcher).
        factory = new PoolProxyFactory(address(refProxy), address(this), address(ac));

        // 3. Tokens.
        base  = new MockERC20("Base",  "BASE", 18);
        quote = new MockERC20("Quote", "QUOT", 18);

        // 4. Sort tokens deterministically for create2 salt.
        address[] memory toks = new address[](2);
        toks[0] = address(base);
        toks[1] = address(quote);

        // 5. Encode initdata: PoolProxy.initialize(owner, baseToken, wnative, FeeParams).
        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: PROTO_SHARE, flashFeeBps: 5, _pad: pad});
        bytes memory initdata = abi.encodeWithSelector(
            PoolProxy.initialize.selector,
            OWNER,
            address(base),
            address(0xCAFE), // wnative — unused in this test
            fp
        );

        // 6. Real factory deploy.
        address proxyAddr = factory.createPool(address(base), toks, initdata);
        proxy = PoolProxy(payable(proxyAddr));

        // 7. Register module selectors. Factory created the proxy so it's DEPLOYER;
        //    the trust/timelock flow can't be exercised by the test contract directly.
        //    This is a test-only shortcut; the production trust flow is exercised by
        //    Phase42CR1Test (A2-1) and PathAlphaACTest.
        _registerModule(proxyAddr, address(poolImpl),   _poolSelectors());
        _registerModule(proxyAddr, address(oracleImpl), _oracleSelectors());

        // 8. Set treasury (so collectProtocolFees passes the gate).
        _setTreasury(proxyAddr, TREASURY);

        // 9. Configure assets via REAL Admin.addAsset.
        //    Base asset first (anchorDepth = 0).
        IPool.OracleConfig memory ocBase  = _oracleCfg(true);
        IPool.OracleConfig memory ocQuote = _oracleCfg(false);
        IPool.RiskConfig    memory rc     = _defaultRisk();
        IPool.LiquidityProfile memory pf  = _defaultProfile();

        // Initial price for InternalOracle: 1.0 in B64 (decimals = 18).
        uint64 priceB64 = M.encodeB64(1e18, 18);

        vm.startPrank(OWNER);
        admin.addAsset(
            proxyAddr,
            address(base),
            ocBase, rc, pf,
            /* minFeeBps */ 1000,   // 0.1% PBPS
            /* decimals  */ 18,
            priceB64,
            /* fastVolEMA */ 10_000, // 1%
            /* slowVolEMA */ 10_000,
            /* minDispersion */ 1000,
            /* maxDispersion */ 100000,
            /* gamma */ 10000,
            /* vega  */ 10000,
            /* lambda */ 10000
        );
        admin.addAsset(
            proxyAddr,
            address(quote),
            ocQuote, rc, pf,
            1000,
            18,
            priceB64,
            10_000,
            10_000,
            1000, 100000, 10000, 10000, 10000
        );
        vm.stopPrank();

        // 10. Seed reserves: simulate LP deposits by minting tokens to the pool and
        //     bumping reserves/liabilities directly via Pool.deposit (real).
        base.mint(OWNER, 1_000_000e18);
        quote.mint(OWNER, 1_000_000e18);
        vm.startPrank(OWNER);
        base.approve(proxyAddr, type(uint256).max);
        quote.approve(proxyAddr, type(uint256).max);
        Pool(payable(proxyAddr)).deposit(address(base), 500_000e18);
        Pool(payable(proxyAddr)).deposit(address(quote), 500_000e18);
        vm.stopPrank();

        // 11. Seed user with input token.
        base.mint(USER, 100_000e18);
        vm.prank(USER);
        base.approve(proxyAddr, type(uint256).max);
    }

    /// @dev Conservation invariant: pool.balance(t) == reserves(t) + protocolFees(t) for both tokens.
    function _assertConservation(string memory tag) internal view {
        address p = address(proxy);
        for (uint256 i; i < 2; ++i) {
            address tk = i == 0 ? address(base) : address(quote);
            uint256 bal   = MockERC20(tk).balanceOf(p);
            uint256 res   = Pool(payable(p)).getAsset(tk).reserves;
            uint256 proto = Pool(payable(p)).getProtocolFees(tk);
            assertEq(bal, res + proto, string.concat(tag, ": conservation broken on token ", vm.toString(i)));
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // SCENARIO 1: protoShare > 0, real getAnchorPathQuote → non-zero q.protoFee
    // ════════════════════════════════════════════════════════════════════

    function test_R8_realFactorySwap_conservation_protoShareNonZero() public {
        _assertConservation("pre-swap");

        uint256 amtIn = 1_000e18;

        // Real swap exercising Pricing.getAnchorPathQuote → non-zero q.protoFee.
        vm.prank(USER);
        uint256 out = Pool(payable(address(proxy))).swap(
            address(base), address(quote), amtIn, 0, USER
        );
        assertGt(out, 0, "swap must succeed with non-zero output");

        // Confirm the swap path actually accumulated proto on tOut (the bug surface).
        uint256 protoOut = Pool(payable(address(proxy))).getProtocolFees(address(quote));
        assertGt(protoOut, 0, "quote-side q.protoFee MUST be non-zero (regression-proof gate)");

        _assertConservation("post-swap");

        // Drain protocolFees via real Admin.collectProtocolFees → Treasury.
        vm.prank(TREASURY);
        admin.collectProtocolFees(address(proxy), address(quote), TREASURY);

        // tIn ledger drained too.
        vm.prank(TREASURY);
        admin.collectProtocolFees(address(proxy), address(base), TREASURY);

        // After collect: ledger == 0 ∀ tokens; pool balance == Σreserves (no LP raid).
        assertEq(Pool(payable(address(proxy))).getProtocolFees(address(quote)), 0, "post-collect quote ledger must be 0");
        assertEq(Pool(payable(address(proxy))).getProtocolFees(address(base)),  0, "post-collect base ledger must be 0");
        _assertConservation("post-collect");
    }

    // ════════════════════════════════════════════════════════════════════
    // SCENARIO 2: protoShare = 0 — proto ledger stays at zero, conservation still holds.
    // ════════════════════════════════════════════════════════════════════

    function test_R8_realFactorySwap_conservation_protoShareZero() public {
        // Reset protoShare via vm.store on FeeParams slot.
        // Slot for feeParams: scan-resilient — pack writes only protoShare+flashFeeBps.
        // Slot index = 14 (modules at 13, FeeParams next).
        bytes32 fpSlot = bytes32(uint256(C.CORE_STORAGE_LOC) + 14);
        bytes32 cur = vm.load(address(proxy), fpSlot);
        // protoShare = lowest byte; clear and write 0.
        bytes32 patched = bytes32(uint256(cur) & ~uint256(0xFF));
        vm.store(address(proxy), fpSlot, patched);

        uint256 amtIn = 500e18;
        vm.prank(USER);
        uint256 out = Pool(payable(address(proxy))).swap(
            address(base), address(quote), amtIn, 0, USER
        );
        assertGt(out, 0, "swap must succeed");

        // protoShare=0 → splitFee returns (0, total). q.protoFee must be 0 on tOut.
        // (in-side spread fee is still ledgered to base — that's the pre-existing
        // half-spread logic, unaffected by protoShare.)
        uint256 protoOut = Pool(payable(address(proxy))).getProtocolFees(address(quote));
        assertEq(protoOut, 0, "protoShare=0 -> tOut proto ledger stays 0");

        _assertConservation("protoShare=0");
    }

    // ════════════════════════════════════════════════════════════════════
    // SCENARIO 3: multiple sequential swaps — no cumulative drift.
    // ════════════════════════════════════════════════════════════════════

    function test_R8_realFactorySwap_conservation_multiSwap() public {
        for (uint256 i; i < 5; ++i) {
            uint256 amtIn = 200e18 + i * 50e18;
            vm.prank(USER);
            Pool(payable(address(proxy))).swap(address(base), address(quote), amtIn, 0, USER);
            _assertConservation(string.concat("multi-swap ", vm.toString(i)));
        }

        // Now collect; must not raid LP.
        vm.prank(TREASURY);
        admin.collectProtocolFees(address(proxy), address(quote), TREASURY);
        vm.prank(TREASURY);
        admin.collectProtocolFees(address(proxy), address(base), TREASURY);
        _assertConservation("multi-swap post-collect");
    }
}
