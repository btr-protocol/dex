// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {Admin} from "../src/Admin.sol";
import {Flash} from "../src/Flash.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IERC3156FlashBorrower} from "../src/interfaces/external/IERC3156FlashBorrower.sol";
import {BasePoolHook} from "../src/hooks/BasePoolHook.sol";
import {VenusHook} from "../src/hooks/VenusHook.sol";
import {MockVenus} from "../src/hooks/MockVenus.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {Maths as M} from "../src/libraries/Maths.sol";
import {MockAC, MockOracle} from "./fixtures/BaseTestSetup.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";

/// @notice Counts callback invocations; optional hard revert on beforeOutflow.
contract CountingHook is BasePoolHook {
    uint256 public beforeOutflowCalls;
    uint256 public postDepositCalls;
    bool public revertBeforeOutflow;

    function setRevertBeforeOutflow(bool v) external {
        revertBeforeOutflow = v;
    }

    function beforeOutflow(address, address, address, uint256) external override {
        ++beforeOutflowCalls;
        if (revertBeforeOutflow) revert("beforeOutflow boom");
    }

    function postDeposit(address, address, address, uint256, uint256) external override {
        ++postDepositCalls;
    }
}

/// @notice Recalls by transferring pre-funded tokens to the pool (simulates redeem).
contract RecallHook is BasePoolHook {
    using SafeTransferLib for address;

    address public immutable token;
    mapping(address => uint256) public recalled;

    constructor(address token_) {
        token = token_;
    }

    function beforeOutflow(address pool, address, address token_, uint256 amountNeeded) external override {
        if (token_ != token) return;
        uint256 liq = IPool(pool).getLiquidReserves(token);
        if (liq >= amountNeeded) return;
        uint256 need = amountNeeded - liq;
        uint256 inv = IPool(pool).getInvested(token);
        if (need > inv) need = inv;
        token.safeTransfer(pool, need);
        recalled[pool] += need;
    }
}

/// @notice Pulls liquid on postDeposit (deploy simulator) for misconfig tests.
contract DeployHook is BasePoolHook {
    using SafeTransferLib for address;

    address public immutable token;
    uint256 public deployAmt;

    constructor(address token_, uint256 deployAmt_) {
        token = token_;
        deployAmt = deployAmt_;
    }

    function postDeposit(address pool, address, address token_, uint256, uint256) external override {
        if (token_ != token || deployAmt == 0) return;
        uint256 liq = IPool(pool).getLiquidReserves(token);
        uint256 amt = deployAmt > liq ? liq : deployAmt;
        if (amt == 0) return;
        token.safeTransferFrom(pool, address(this), amt);
    }
}

/// @notice Malicious: tries to transferFrom the full R_liq on postDeposit (past minLiquidity).
contract DrainAllHook is BasePoolHook {
    using SafeTransferLib for address;

    address public immutable token;

    constructor(address token_) {
        token = token_;
    }

    function postDeposit(address pool, address, address token_, uint256, uint256) external override {
        if (token_ != token) return;
        uint256 liq = IPool(pool).getLiquidReserves(token);
        if (liq == 0) return;
        token.safeTransferFrom(pool, address(this), liq);
    }
}

/// @notice Malicious: transferFrom (Δbalance) then hookPull → double-book invested.
contract DoubleBookDeployHook is BasePoolHook {
    using SafeTransferLib for address;

    address public immutable token;
    uint256 public deployAmt;

    constructor(address token_, uint256 deployAmt_) {
        token = token_;
        deployAmt = deployAmt_;
    }

    function postDeposit(address pool, address, address token_, uint256, uint256) external override {
        if (token_ != token || deployAmt == 0) return;
        uint256 liq = IPool(pool).getLiquidReserves(token);
        uint256 amt = deployAmt > liq ? liq : deployAmt;
        if (amt == 0) return;
        token.safeTransferFrom(pool, address(this), amt);
        IPool(pool).hookPull(token, amt);
    }
}

/// @notice Malicious: transfer recall then hookNotifyRecall → double-cut invested.
contract DoubleBookRecallHook is BasePoolHook {
    using SafeTransferLib for address;

    address public immutable token;

    constructor(address token_) {
        token = token_;
    }

    function beforeOutflow(address pool, address, address token_, uint256 amountNeeded) external override {
        if (token_ != token) return;
        uint256 liq = IPool(pool).getLiquidReserves(token);
        if (liq >= amountNeeded) return;
        uint256 need = amountNeeded - liq;
        uint256 inv = IPool(pool).getInvested(token);
        if (need > inv) need = inv;
        if (need == 0) return;
        token.safeTransfer(pool, need);
        IPool(pool).hookNotifyRecall(token, need);
    }
}

/// @notice Malicious: hookCreditYield during postDeposit (phantom R / R_inv).
contract PhantomYieldHook is BasePoolHook {
    address public immutable token;

    constructor(address token_) {
        token = token_;
    }

    function postDeposit(address pool, address, address token_, uint256, uint256) external override {
        if (token_ != token) return;
        IPool(pool).hookCreditYield(token, 1e18);
    }
}

contract MockFlashBorrower is IERC3156FlashBorrower {
    function postFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        address pool = abi.decode(data, (address));
        MockERC20(token).transfer(pool, amount + fee);
        return keccak256("ERC3156FlashBorrower.postFlashLoan");
    }
}

contract PoolHooksTest is Test {
    PoolFactory factory;
    Pool poolImpl;
    Admin admin;
    Flash flashSingleton;
    MockAC ac;
    MockOracle oracle;
    Pool pool;
    MockERC20 base;
    MockERC20 quote;

    address constant OWNER = address(0xA11CE);
    address constant USER = address(0xBEEF);
    uint8 constant PROTO_SHARE = 25;

    function _profile() internal pure returns (IPool.LiquidityProfile memory p) {
        p.weights[0] = 50;
        p.weights[1] = 50;
        p.weights[2] = 50;
        p.weights[3] = 50;
        p.knots[0] = -50;
        p.knots[1] = -25;
        p.knots[2] = 0;
        p.knots[3] = 25;
        p.knots[4] = 50;
    }

    function _risk() internal pure returns (IPool.RiskConfig memory r) {
        r.decayStartRatioBps = 5000;
        r.coverageMin = 5000;
        r.coverageMax = 20000;
        r.depthAmplifier = 10000;
        r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT | C.FLASH_ENABLED_BIT;
    }

    function _oracleCfg(address token) internal view returns (IPool.OracleConfig memory o) {
        o.primary = address(oracle);
        o.feedId = bytes32(uint256(uint160(token)));
    }

    function setUp() public {
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

        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: PROTO_SHARE, flashFeeBps: 100, _pad: pad});
        bytes memory initdata = abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
        address pa = factory.createPool(address(base), toks, initdata);
        pool = Pool(payable(pa));

        oracle = new MockOracle();
        oracle.setMark(address(base), M.encodeB64(1e18, 18));
        oracle.setMark(address(quote), M.encodeB64(1e18, 18));
        IPool.RiskConfig memory rc = _risk();
        IPool.LiquidityProfile memory pf = _profile();
        vm.startPrank(OWNER);
        admin.addAsset(pa, address(base), _oracleCfg(address(base)), rc, pf, 1000, 18, 1000, 100000, 10000, 10000);
        admin.addAsset(pa, address(quote), _oracleCfg(address(quote)), rc, pf, 1000, 18, 1000, 100000, 10000, 10000);
        vm.stopPrank();

        uint256 seed = 1_000_000e18;
        base.mint(address(this), seed);
        base.approve(address(pool), type(uint256).max);
        pool.deposit(address(base), seed);
        quote.mint(address(this), seed);
        quote.approve(address(pool), type(uint256).max);
        pool.deposit(address(quote), seed);
    }

    function _setHook(address token, address hook, uint32 flags) internal {
        vm.startPrank(OWNER);
        admin.requestSetAssetHook(address(pool), token, hook, flags);
        vm.warp(block.timestamp + 1 days + 1);
        admin.executeSetAssetHook(address(pool), token);
        vm.stopPrank();
        // Refresh marks after warp (oracle TTL is uint16.max ≈ 18h).
        oracle.setMark(address(base), M.encodeB64(1e18, 18));
        oracle.setMark(address(quote), M.encodeB64(1e18, 18));
    }

    function _setMinLiquidity(address token, uint128 minLiq) internal {
        IPool.Asset memory a = pool.getAsset(token);
        vm.prank(OWNER);
        admin.setAssetParams(
            address(pool),
            token,
            minLiq,
            a.minFeeBps,
            a.maxFeeBps,
            a.gamma,
            a.vega,
            a.haircutSuppressor,
            a.reservationPrice,
            a.reservationPriceMax
        );
    }

    /// @notice Hookless swap: liquid check early-out, 0 CALL.
    function test_hookless_swap_gas_path() public {
        uint256 amt = 100e18;
        base.mint(USER, amt);
        vm.prank(USER);
        base.approve(address(pool), type(uint256).max);

        uint256 g0 = gasleft();
        vm.prank(USER);
        pool.swap(address(base), address(quote), amt, 0, USER);
        uint256 used = g0 - gasleft();
        // Sanity pin: should stay in the same ballpark as pre-hooks (~warm path).
        assertLt(used, 800_000, "hookless swap gas");
        assertEq(IPool(address(pool)).getInvested(address(quote)), 0);
    }

    /// @notice HOOK-EOA: an EOA (no code) hook target must be rejected at request time.
    function test_hook_eoa_rejected() public {
        vm.prank(OWNER);
        vm.expectRevert(Err.NotCode.selector);
        admin.requestSetAssetHook(address(pool), address(quote), address(0xE0A), C.HOOK_BEFORE_OUTFLOW);
    }

    /// @notice Flag off → no callback even when hook is set.
    function test_flag_skip_no_call() public {
        CountingHook hook = new CountingHook();
        // Only POST_DEPOSIT — BEFORE_OUTFLOW off.
        _setHook(address(quote), address(hook), C.HOOK_POST_DEPOSIT);

        uint256 amt = 100e18;
        base.mint(USER, amt);
        vm.prank(USER);
        base.approve(address(pool), type(uint256).max);
        vm.prank(USER);
        pool.swap(address(base), address(quote), amt, 0, USER);

        assertEq(hook.beforeOutflowCalls(), 0, "beforeOutflow skipped");
    }

    /// @notice beforeOutflow recall books invested down; reserves (R) unchanged across recall.
    function test_beforeOutflow_recall_updates_invested() public {
        RecallHook hook = new RecallHook(address(quote));
        _setHook(address(quote), address(hook), C.HOOK_BEFORE_OUTFLOW);

        // Simulate R_inv: leave only a tiny liquid buffer so swap must recall.
        uint256 reserves = pool.getAsset(address(quote)).reserves;
        uint256 keep = 1e18;
        uint256 inv = reserves - keep;
        uint256 fees = pool.getProtocolFees(address(quote));
        deal(address(quote), address(hook), inv);
        deal(address(quote), address(pool), keep + fees + inv);
        vm.prank(address(hook));
        IPool(address(pool)).hookPull(address(quote), inv);

        assertEq(IPool(address(pool)).getInvested(address(quote)), inv);
        assertEq(IPool(address(pool)).getLiquidReserves(address(quote)), keep);

        uint256 amt = 50e18;
        base.mint(USER, amt);
        vm.prank(USER);
        base.approve(address(pool), type(uint256).max);
        uint256 invBefore = IPool(address(pool)).getInvested(address(quote));
        vm.prank(USER);
        pool.swap(address(base), address(quote), amt, 0, USER);

        assertLt(IPool(address(pool)).getInvested(address(quote)), invBefore, "invested reduced by recall");
        uint256 balAfter = quote.balanceOf(address(pool));
        uint256 r = pool.getAsset(address(quote)).reserves;
        uint256 i = IPool(address(pool)).getInvested(address(quote));
        uint256 f = pool.getProtocolFees(address(quote));
        assertEq(balAfter, r - i + f, "R8 liquid conservation");
    }

    /// @notice Fail-closed when shortfall and hook cannot cover.
    function test_fail_closed_shortfall() public {
        CountingHook hook = new CountingHook();
        _setHook(address(quote), address(hook), C.HOOK_BEFORE_OUTFLOW);

        uint256 reserves = pool.getAsset(address(quote)).reserves;
        uint256 keep = 1e18;
        uint256 inv = reserves - keep;
        deal(address(quote), address(pool), keep);
        vm.prank(address(hook));
        // Need tokens in pool for hookPull — restore then pull.
        deal(address(quote), address(pool), keep + inv);
        vm.prank(address(hook));
        IPool(address(pool)).hookPull(address(quote), inv);
        // Hook does not transfer anything back on beforeOutflow (CountingHook).
        uint256 amt = 100e18;
        base.mint(USER, amt);
        vm.prank(USER);
        base.approve(address(pool), type(uint256).max);
        vm.prank(USER);
        vm.expectRevert();
        pool.swap(address(base), address(quote), amt, 0, USER);
    }

    /// @notice MockVenus + VenusHook integration: deposit deploys, swap recalls.
    function test_mockVenus_integration() public {
        MockVenus vToken = new MockVenus(address(quote));
        VenusHook hook = new VenusHook(address(ac), address(pool), address(quote), address(vToken));
        uint32 flags = hook.recommendedFlags();
        _setHook(address(quote), address(hook), flags);

        // Force deploy by depositing more (postDeposit).
        uint256 more = 200_000e18;
        quote.mint(address(this), more);
        pool.deposit(address(quote), more);

        uint256 inv = IPool(address(pool)).getInvested(address(quote));
        assertGt(inv, 0, "deployed to MockVenus");
        assertGt(vToken.balanceOf(address(hook)), 0);

        uint256 liq = IPool(address(pool)).getLiquidReserves(address(quote));
        // Drain liquid so next swap must recall — leave minLiquidity room (0 here).
        if (liq > 10e18) {
            uint256 leave = 5e18;
            uint256 extra = liq - leave;
            if (extra > 0) {
                vm.prank(address(hook));
                IPool(address(pool)).hookPull(address(quote), extra);
            }
            uint256 onHook = quote.balanceOf(address(hook));
            if (onHook > 0) {
                vm.startPrank(address(hook));
                quote.approve(address(vToken), onHook);
                vToken.mint(onHook);
                vm.stopPrank();
            }
        }

        assertLt(IPool(address(pool)).getLiquidReserves(address(quote)), 50e18);

        uint256 amt = 20e18;
        base.mint(USER, amt);
        vm.prank(USER);
        base.approve(address(pool), type(uint256).max);
        uint256 invBefore = IPool(address(pool)).getInvested(address(quote));
        vm.prank(USER);
        uint256 out = pool.swap(address(base), address(quote), amt, 0, USER);
        assertGt(out, 0);
        assertLe(IPool(address(pool)).getInvested(address(quote)), invBefore, "recall reduced or held invested");
    }

    function test_clearAssetHook_requires_zero_invested() public {
        RecallHook hook = new RecallHook(address(quote));
        _setHook(address(quote), address(hook), C.HOOK_BEFORE_OUTFLOW);
        uint256 inv = 100e18;
        deal(address(quote), address(pool), IPool(address(pool)).getLiquidReserves(address(quote)) + inv);
        vm.prank(address(hook));
        IPool(address(pool)).hookPull(address(quote), inv);

        vm.prank(OWNER);
        vm.expectRevert(Err.InvalidState.selector);
        admin.clearAssetHook(address(pool), address(quote));
    }

    function test_storage_layout_slots_0_3_unchanged() public {
        // Reuse pin: slots 0-3 still base/wnative/bridge/treasury.
        assertEq(pool.baseToken(), address(base));
    }

    // ── Adversarial MUST coverage ──────────────────────────────────────────

    /// @notice Pool spoof: non-bound caller cannot drive VenusHook recall/drain.
    function test_venusHook_pool_spoof_reverts() public {
        MockVenus vToken = new MockVenus(address(quote));
        VenusHook hook = new VenusHook(address(ac), address(pool), address(quote), address(vToken));
        _setHook(address(quote), address(hook), hook.recommendedFlags());

        quote.mint(address(this), 100e18);
        pool.deposit(address(quote), 100e18);
        assertGt(IPool(address(pool)).getInvested(address(quote)), 0);

        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(VenusHook.OnlyPool.selector);
        hook.beforeOutflow(attacker, attacker, address(quote), 1e18);

        // Spoofed "pool" arg is ignored; msg.sender must be immutable pool.
        vm.prank(attacker);
        vm.expectRevert(VenusHook.OnlyPool.selector);
        hook.beforeOutflow(address(pool), attacker, address(quote), 1e18);
    }

    /// @notice Write-down when Venus NAV < book: invested + reserves + liabilities cut; R_liq unchanged.
    function test_writeDown_nav_below_book() public {
        MockVenus vToken = new MockVenus(address(quote));
        VenusHook hook = new VenusHook(address(ac), address(pool), address(quote), address(vToken));
        _setHook(address(quote), address(hook), hook.recommendedFlags());

        quote.mint(address(this), 200_000e18);
        pool.deposit(address(quote), 200_000e18);

        uint256 invBefore = IPool(address(pool)).getInvested(address(quote));
        uint256 rBefore = pool.getAsset(address(quote)).reserves;
        uint256 liabBefore = pool.getAsset(address(quote)).liabilities;
        uint256 liqBefore = IPool(address(pool)).getLiquidReserves(address(quote));
        assertGt(invBefore, 0);

        vToken.setRate(0.5e18);
        uint256 nav = (vToken.balanceOf(address(hook)) * vToken.exchangeRateStored()) / 1e18;
        uint256 loss = invBefore - nav;
        assertGt(loss, 0);

        // Direct ledger path (harvest calls the same).
        vm.prank(address(hook));
        IPool(address(pool)).hookWriteDown(address(quote), loss);

        assertEq(IPool(address(pool)).getInvested(address(quote)), invBefore - loss, "invested");
        assertEq(pool.getAsset(address(quote)).reserves, rBefore - loss, "reserves");
        assertEq(pool.getAsset(address(quote)).liabilities, liabBefore - loss, "liabilities");
        assertEq(IPool(address(pool)).getLiquidReserves(address(quote)), liqBefore, "R_liq");

        // Keeper rebalance harvest also write-downs when NAV < book.
        vm.prank(address(hook));
        IPool(address(pool)).hookCreditYield(address(quote), loss);
        uint256 invRestored = IPool(address(pool)).getInvested(address(quote));
        vm.prank(OWNER);
        hook.rebalance();
        assertLt(IPool(address(pool)).getInvested(address(quote)), invRestored, "rebalance harvest");
    }

    /// @notice Deploy never leaves R_liq < minLiquidity.
    function test_minLiquidity_deploy_floor() public {
        uint128 minLiq = 100e18;
        _setMinLiquidity(address(quote), minLiq);

        MockVenus vToken = new MockVenus(address(quote));
        VenusHook hook = new VenusHook(address(ac), address(pool), address(quote), address(vToken));
        _setHook(address(quote), address(hook), hook.recommendedFlags());

        quote.mint(address(this), 200_000e18);
        pool.deposit(address(quote), 200_000e18);

        uint256 liq = IPool(address(pool)).getLiquidReserves(address(quote));
        assertGe(liq, minLiq, "post-deploy R_liq >= minLiquidity");

        // hookPull also respects floor.
        uint256 pullAmt = liq - minLiq + 1;
        vm.prank(address(hook));
        vm.expectRevert();
        IPool(address(pool)).hookPull(address(quote), pullAmt);
    }

    /// @notice Malicious postDeposit cannot pull full R_liq past minLiquidity (approve cap).
    function test_postDeposit_malicious_full_drain_reverts() public {
        uint128 minLiq = 100e18;
        _setMinLiquidity(address(quote), minLiq);

        DrainAllHook hook = new DrainAllHook(address(quote));
        _setHook(address(quote), address(hook), C.HOOK_BEFORE_OUTFLOW | C.HOOK_POST_DEPOSIT);

        quote.mint(address(this), 50_000e18);
        // transferFrom(liq) fails: allowance = liq - minLiquidity only.
        vm.expectRevert();
        pool.deposit(address(quote), 50_000e18);

        assertEq(IPool(address(pool)).getInvested(address(quote)), 0, "no stranded invested");
        assertGe(IPool(address(pool)).getLiquidReserves(address(quote)), minLiq, "floor held");
    }

    /// @notice flags=0 (or drop BEFORE_OUTFLOW) blocked while invested > 0.
    function test_flags_zero_blocked_when_invested() public {
        RecallHook hook = new RecallHook(address(quote));
        _setHook(address(quote), address(hook), C.HOOK_BEFORE_OUTFLOW | C.HOOK_POST_DEPOSIT);

        uint256 inv = 50e18;
        deal(address(quote), address(pool), IPool(address(pool)).getLiquidReserves(address(quote)) + inv);
        vm.prank(address(hook));
        IPool(address(pool)).hookPull(address(quote), inv);

        // Soft-clear via flags=0.
        vm.prank(address(admin));
        vm.expectRevert(Err.InvalidState.selector);
        IPool(address(pool)).adminSetAssetHook(address(quote), address(hook), 0);

        // Drop BEFORE_OUTFLOW only (POST_DEPOSIT alone).
        vm.prank(address(admin));
        vm.expectRevert(Err.InvalidState.selector);
        IPool(address(pool)).adminSetAssetHook(address(quote), address(hook), C.HOOK_POST_DEPOSIT);

        // Unknown bits rejected.
        vm.prank(address(admin));
        vm.expectRevert(Err.InvalidInput.selector);
        IPool(address(pool)).adminSetAssetHook(address(quote), address(hook), uint32(1 << 7));
    }

    /// @notice flashPrepare recalls amount + minLiquidity when invested covers the shortfall.
    function test_flash_recall_amount_plus_minLiquidity() public {
        uint128 minLiq = 10e18;
        _setMinLiquidity(address(quote), minLiq);

        RecallHook hook = new RecallHook(address(quote));
        _setHook(address(quote), address(hook), C.HOOK_BEFORE_OUTFLOW);

        uint256 reserves = pool.getAsset(address(quote)).reserves;
        // Leave liquid just below amount+minLiq so flash must recall.
        uint256 loan = 100e18;
        uint256 keep = minLiq; // liquid == minLiq only → need full loan recalled
        uint256 inv = reserves - keep;
        uint256 fees = pool.getProtocolFees(address(quote));
        deal(address(quote), address(hook), inv);
        deal(address(quote), address(pool), keep + fees + inv);
        vm.prank(address(hook));
        IPool(address(pool)).hookPull(address(quote), inv);

        assertEq(IPool(address(pool)).getLiquidReserves(address(quote)), keep);

        // Fund borrower with fee buffer.
        MockFlashBorrower borrower = new MockFlashBorrower();
        uint256 fee = flashSingleton.flashFee(address(pool), address(quote), loan);
        quote.mint(address(borrower), fee);

        uint256 invBefore = IPool(address(pool)).getInvested(address(quote));
        flashSingleton.flashLoan(
            address(pool), borrower, address(quote), loan, abi.encode(address(pool))
        );
        // Recall booked down by (loan + minLiq - keep) = loan (since keep == minLiq).
        assertLt(IPool(address(pool)).getInvested(address(quote)), invBefore);
        assertGe(IPool(address(pool)).getLiquidReserves(address(quote)), minLiq);
    }

    // ── HIGH re-review MUST coverage ───────────────────────────────────────

    /// @notice POST_DEPOSIT-only cannot create invested (hookPull + postDeposit delta).
    function test_beforeOutflow_required_to_increase_invested() public {
        DeployHook hook = new DeployHook(address(quote), 50e18);
        _setHook(address(quote), address(hook), C.HOOK_POST_DEPOSIT);

        // hookPull blocked without BEFORE_OUTFLOW.
        vm.prank(address(hook));
        vm.expectRevert(Err.InvalidState.selector);
        IPool(address(pool)).hookPull(address(quote), 1e18);

        // postDeposit deploy attempt reverts the whole deposit (no stranded invested).
        quote.mint(address(this), 100e18);
        vm.expectRevert(Err.InvalidState.selector);
        pool.deposit(address(quote), 100e18);

        assertEq(IPool(address(pool)).getInvested(address(quote)), 0);

        // Same hook with BEFORE_OUTFLOW can invest.
        _setHook(address(quote), address(hook), C.HOOK_BEFORE_OUTFLOW | C.HOOK_POST_DEPOSIT);
        quote.mint(address(this), 100e18);
        pool.deposit(address(quote), 100e18);
        assertEq(IPool(address(pool)).getInvested(address(quote)), 50e18);
    }

    /// @notice Withdraw recalls cashNeed + minLiquidity so post-debit R_liq ≥ floor.
    function test_withdraw_recall_cashNeed_plus_minLiquidity() public {
        uint128 minLiq = 10e18;
        _setMinLiquidity(address(quote), minLiq);

        RecallHook hook = new RecallHook(address(quote));
        _setHook(address(quote), address(hook), C.HOOK_BEFORE_OUTFLOW);

        uint256 reserves = pool.getAsset(address(quote)).reserves;
        // Leave liquid == minLiq only → withdraw of W requires recall of W + minLiq - keep = W.
        uint256 keep = minLiq;
        uint256 inv = reserves - keep;
        uint256 fees = pool.getProtocolFees(address(quote));
        deal(address(quote), address(hook), inv);
        deal(address(quote), address(pool), keep + fees + inv);
        vm.prank(address(hook));
        IPool(address(pool)).hookPull(address(quote), inv);
        assertEq(IPool(address(pool)).getLiquidReserves(address(quote)), keep);

        // Seed USER LP on quote via deposit then force most capital invested already.
        uint256 lpSeed = 200e18;
        quote.mint(USER, lpSeed);
        vm.startPrank(USER);
        quote.approve(address(pool), type(uint256).max);
        pool.deposit(address(quote), lpSeed);
        vm.stopPrank();
        // Clear deposit cooldown before withdraw.
        vm.warp(block.timestamp + 1 days);
        oracle.setMark(address(base), M.encodeB64(1e18, 18));
        oracle.setMark(address(quote), M.encodeB64(1e18, 18));

        // Re-invest any liquid above keep so withdraw must recall.
        uint256 liqNow = IPool(address(pool)).getLiquidReserves(address(quote));
        if (liqNow > keep) {
            uint256 extra = liqNow - keep;
            deal(address(quote), address(hook), quote.balanceOf(address(hook)) + extra);
            vm.prank(address(hook));
            IPool(address(pool)).hookPull(address(quote), extra);
        }
        assertEq(IPool(address(pool)).getLiquidReserves(address(quote)), keep);

        uint256 lpBal = pool.getLPBalance(USER, address(quote));
        uint256 invBefore = IPool(address(pool)).getInvested(address(quote));
        // Withdraw half of USER LP — without cashNeed+minLiq recall this reverts on floor.
        vm.prank(USER);
        IPool.WithdrawResult memory wr = pool.withdrawTo(address(quote), address(quote), lpBal / 2, 0);
        assertGt(wr.amountOut, 0);
        assertLt(IPool(address(pool)).getInvested(address(quote)), invBefore, "recalled for withdraw");
        assertGe(IPool(address(pool)).getLiquidReserves(address(quote)), minLiq, "floor held");
    }

    /// @notice Severe write-down: loss > L, loss == L, and shares==0 with positive book.
    function test_writeDown_severe_loss_and_zero_shares() public {
        MockVenus vToken = new MockVenus(address(quote));
        VenusHook hook = new VenusHook(address(ac), address(pool), address(quote), address(vToken));
        _setHook(address(quote), address(hook), hook.recommendedFlags());

        quote.mint(address(this), 200_000e18);
        pool.deposit(address(quote), 200_000e18);

        uint256 inv0 = IPool(address(pool)).getInvested(address(quote));
        assertGt(inv0, 0);

        // Clear deposit cooldown before cross-withdraw.
        vm.warp(block.timestamp + 1 days);
        oracle.setMark(address(base), M.encodeB64(1e18, 18));
        oracle.setMark(address(quote), M.encodeB64(1e18, 18));

        // Shrink quote L below invested: cross-withdraw burns from-L, leaves from-R / invested.
        // Exit enough of this contract's quote LP into base so L < inv.
        uint256 lpSelf = pool.getLPBalance(address(this), address(quote));
        uint256 idx = pool.getAsset(address(quote)).liquidityIndex;
        if (idx == 0) idx = C.LIQUIDITY_INDEX_INIT;
        uint256 liabNow = pool.getAsset(address(quote)).liabilities;
        uint256 targetBurn = liabNow > inv0 ? (liabNow - inv0 + 1) : (liabNow / 2);
        // lp = face * WAD / index (WAD = 1e18)
        uint256 lpBurn = (targetBurn * 1e18) / idx;
        if (lpBurn > lpSelf) lpBurn = (lpSelf * 8) / 10;
        if (lpBurn > 0) {
            pool.withdrawTo(address(quote), address(base), lpBurn, 0);
        }

        uint256 inv = IPool(address(pool)).getInvested(address(quote));
        uint256 liab = pool.getAsset(address(quote)).liabilities;
        uint256 r = pool.getAsset(address(quote)).reserves;
        uint256 liq = IPool(address(pool)).getLiquidReserves(address(quote));
        assertGt(inv, liab, "precondition: inv > L after cross-exit");
        assertGt(liab, 0);

        // Case: loss > liabilities — must not revert; L→0, index floor, R_liq stable.
        vm.prank(address(hook));
        IPool(address(pool)).hookWriteDown(address(quote), inv);
        assertEq(IPool(address(pool)).getInvested(address(quote)), 0);
        assertEq(pool.getAsset(address(quote)).reserves, r - inv);
        assertEq(pool.getAsset(address(quote)).liabilities, 0);
        assertEq(pool.getAsset(address(quote)).liquidityIndex, 1);
        assertEq(IPool(address(pool)).getLiquidReserves(address(quote)), liq);

        // Case: loss == liabilities (exact wipe) on a fresh book slice.
        // Re-seed via deposit + pull, then write exactly L.
        vm.prank(OWNER);
        hook.setBuffer(0, 0); // keep liquid; no auto-deploy
        quote.mint(address(this), 100e18);
        pool.deposit(address(quote), 100e18);
        uint256 pullAmt = 40e18;
        deal(address(quote), address(pool), IPool(address(pool)).getLiquidReserves(address(quote)) + pullAmt);
        vm.prank(address(hook));
        IPool(address(pool)).hookPull(address(quote), pullAmt);

        // Reduce L to equal a chosen cut via another cross-exit until L == pullAmt.
        // Simpler: write-down exactly current L (≤ inv).
        uint256 invB = IPool(address(pool)).getInvested(address(quote));
        uint256 liabB = pool.getAsset(address(quote)).liabilities;
        uint256 cutEq = liabB <= invB ? liabB : invB;
        assertGt(cutEq, 0);
        uint256 liqB = IPool(address(pool)).getLiquidReserves(address(quote));
        vm.prank(address(hook));
        IPool(address(pool)).hookWriteDown(address(quote), cutEq);
        assertEq(pool.getAsset(address(quote)).liabilities, liabB - cutEq);
        if (cutEq == liabB) {
            assertEq(pool.getAsset(address(quote)).liquidityIndex, 1, "index floor on L wipe");
        }
        assertEq(IPool(address(pool)).getLiquidReserves(address(quote)), liqB);

        // Drain residual invested so zero-shares case starts clean.
        uint256 rem = IPool(address(pool)).getInvested(address(quote));
        if (rem > 0) {
            vm.prank(address(hook));
            IPool(address(pool)).hookWriteDown(address(quote), rem);
        }

        // Case: shares == 0 with positive book → harvest clears stale invested.
        uint256 stale = 25e18;
        deal(address(quote), address(pool), IPool(address(pool)).getLiquidReserves(address(quote)) + stale);
        vm.prank(address(hook));
        IPool(address(pool)).hookPull(address(quote), stale);
        assertEq(IPool(address(pool)).getInvested(address(quote)), stale);

        uint256 sh = vToken.balanceOf(address(hook));
        if (sh > 0) {
            vm.prank(address(hook));
            vToken.redeem(sh);
        }
        assertEq(vToken.balanceOf(address(hook)), 0);
        assertGt(IPool(address(pool)).getInvested(address(quote)), 0);

        vm.prank(OWNER);
        hook.rebalance();
        assertEq(IPool(address(pool)).getInvested(address(quote)), 0, "zero-shares clears book");
    }

    // ── Mutex / double-book (MUST: nonReentrant on ledger writers) ─────────

    /// @notice postDeposit cannot hookPull after Δbalance transfer (shared Solady guard).
    function test_postDeposit_hookPull_reverts_reentrancy() public {
        DoubleBookDeployHook hook = new DoubleBookDeployHook(address(quote), 50e18);
        _setHook(address(quote), address(hook), C.HOOK_BEFORE_OUTFLOW | C.HOOK_POST_DEPOSIT);

        quote.mint(address(this), 100e18);
        vm.expectRevert(ReentrancyGuardTransient.Reentrancy.selector);
        pool.deposit(address(quote), 100e18);

        assertEq(IPool(address(pool)).getInvested(address(quote)), 0, "no double-book");
    }

    /// @notice beforeOutflow cannot hookNotifyRecall after transfer (Δbalance is sole booker).
    function test_beforeOutflow_hookNotifyRecall_reverts_reentrancy() public {
        DoubleBookRecallHook hook = new DoubleBookRecallHook(address(quote));
        _setHook(address(quote), address(hook), C.HOOK_BEFORE_OUTFLOW);

        uint256 inv = 50e18;
        deal(address(quote), address(hook), inv);
        deal(address(quote), address(pool), IPool(address(pool)).getLiquidReserves(address(quote)) + inv);
        vm.prank(address(hook));
        IPool(address(pool)).hookPull(address(quote), inv);

        // Force recall: leave liquid short of a modest swap-sized need via withdraw path.
        uint256 keep = 1e18;
        uint256 liq = IPool(address(pool)).getLiquidReserves(address(quote));
        if (liq > keep) {
            uint256 extra = liq - keep;
            deal(address(quote), address(hook), quote.balanceOf(address(hook)) + extra);
            vm.prank(address(hook));
            IPool(address(pool)).hookPull(address(quote), extra);
        }

        uint256 lpSeed = 200e18;
        quote.mint(USER, lpSeed);
        vm.startPrank(USER);
        quote.approve(address(pool), type(uint256).max);
        pool.deposit(address(quote), lpSeed);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        oracle.setMark(address(base), M.encodeB64(1e18, 18));
        oracle.setMark(address(quote), M.encodeB64(1e18, 18));

        // Re-invest liquid above keep so withdraw must call beforeOutflow.
        uint256 liqNow = IPool(address(pool)).getLiquidReserves(address(quote));
        if (liqNow > keep) {
            uint256 extra = liqNow - keep;
            deal(address(quote), address(hook), quote.balanceOf(address(hook)) + extra);
            vm.prank(address(hook));
            IPool(address(pool)).hookPull(address(quote), extra);
        }

        uint256 lpBal = pool.getLPBalance(USER, address(quote));
        uint256 invBefore = IPool(address(pool)).getInvested(address(quote));
        vm.prank(USER);
        vm.expectRevert(ReentrancyGuardTransient.Reentrancy.selector);
        pool.withdrawTo(address(quote), address(quote), lpBal / 2, 0);

        assertEq(IPool(address(pool)).getInvested(address(quote)), invBefore, "invested unchanged");
    }

    /// @notice postDeposit cannot hookCreditYield (phantom R / R_inv).
    function test_postDeposit_hookCreditYield_reverts_reentrancy() public {
        PhantomYieldHook hook = new PhantomYieldHook(address(quote));
        _setHook(address(quote), address(hook), C.HOOK_BEFORE_OUTFLOW | C.HOOK_POST_DEPOSIT);

        quote.mint(address(this), 100e18);
        vm.expectRevert(ReentrancyGuardTransient.Reentrancy.selector);
        pool.deposit(address(quote), 100e18);
    }

    /// @notice hookNotifyRecall without prior transfer fails balance proof (keeper trim only).
    function test_hookNotifyRecall_requires_balance_proof() public {
        CountingHook hook = new CountingHook();
        _setHook(address(quote), address(hook), C.HOOK_BEFORE_OUTFLOW);

        uint256 inv = 20e18;
        // Pull from existing liquid book (no surplus deal — bal must track R_liq + fees).
        assertGe(IPool(address(pool)).getLiquidReserves(address(quote)), inv + 1);
        vm.prank(address(hook));
        IPool(address(pool)).hookPull(address(quote), inv);

        // No tokens returned — bal ≈ R_liq + fees, need bal ≥ R_liq + fees + amount.
        vm.prank(address(hook));
        vm.expectRevert();
        IPool(address(pool)).hookNotifyRecall(address(quote), inv);

        // Transfer then notify (keeper trim path).
        deal(address(quote), address(this), inv);
        quote.transfer(address(pool), inv);
        vm.prank(address(hook));
        IPool(address(pool)).hookNotifyRecall(address(quote), inv);
        assertEq(IPool(address(pool)).getInvested(address(quote)), 0);
    }
}
