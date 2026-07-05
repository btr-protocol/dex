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
import {IAdmin} from "../src/interfaces/IAdmin.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {Maths as M} from "../src/libraries/Maths.sol";
import {Err} from "@btr-shared/Errors.sol";
import {MockAC, MockOracle} from "./fixtures/BaseTestSetup.sol";

/// @title PoolLifecycleTest
/// @notice Pool lifecycle sanity -Pool is standalone (no proxy, no modules, no ERC-7201).
///         Each pool instance is an EIP-1167 minimal-proxy clone deployed by PoolFactory.
contract PoolLifecycleTest is Test {
    PoolFactory factory;
    Pool poolImpl;
    Admin admin;
    Flash flashSingleton;
    MockAC ac;
    MockOracle oracle;

    Pool pool;        // clone, cast as Pool
    MockERC20 base;
    MockERC20 quote;

    address constant OWNER = address(0xA11CE);
    address constant USER  = address(0xBEEF);
    uint8  constant PROTO_SHARE = 25;
    uint16 constant FLASH_FEE_BPS = 100;

    function _defaultProfile() internal pure returns (IPool.LiquidityProfile memory p) {
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

    function _oracleCfg(address token) internal view returns (IPool.OracleConfig memory o) {
        o.primary = address(oracle);
        o.feedId = bytes32(uint256(uint160(token)));
    }

    function setUp() public {
        ac = new MockAC(OWNER);

        admin            = new Admin(address(ac));
        flashSingleton   = new Flash();
        PoolAux poolAux  = new PoolAux(address(ac), address(admin), address(flashSingleton));
        poolImpl         = new Pool(address(ac), address(admin), address(flashSingleton), address(poolAux));

        factory = new PoolFactory(address(poolImpl), address(this), address(ac));

        base  = new MockERC20("Base",  "BASE", 18);
        quote = new MockERC20("Quote", "QUOT", 18);

        address[] memory toks = new address[](2);
        toks[0] = address(base);
        toks[1] = address(quote);

        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({
            protoShare: PROTO_SHARE,
            flashFeeBps: FLASH_FEE_BPS,
            _pad: pad
        });
        bytes memory initdata = abi.encodeWithSelector(
            Pool.initialize.selector,
            address(base),
            address(0xCAFE),
            fp
        );
        address poolAddr = factory.createPool(address(base), toks, initdata);
        pool = Pool(payable(poolAddr));

        oracle = new MockOracle();
        oracle.setMark(address(base),  M.encodeB64(1e18, 18));
        oracle.setMark(address(quote), M.encodeB64(1e18, 18));
        IPool.RiskConfig    memory rc = _defaultRisk();
        IPool.LiquidityProfile memory pf = _defaultProfile();

        vm.startPrank(OWNER);
        admin.addAsset(poolAddr, address(base),  _oracleCfg(address(base)),  rc, pf, 1000, 18, 1000, 100000, 10000, 10000);
        admin.addAsset(poolAddr, address(quote), _oracleCfg(address(quote)), rc, pf, 1000, 18, 1000, 100000, 10000, 10000);
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
        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 0, flashFeeBps: 0, _pad: pad});
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
        assertTrue((pool.getRiskFlags(address(base)) & C.PROTOCOL_PAUSED_BIT) != 0, "paused");

        vm.prank(OWNER);
        admin.unpauseAsset(address(pool), address(base));
        assertEq(pool.getRiskFlags(address(base)) & C.PROTOCOL_PAUSED_BIT, 0, "unpaused");
    }

    /// PROTOCOL_PAUSED_BIT (bit6) is SEPARATE from FROZEN_BIT (bit0): an emergency pause + an
    /// independent per-asset risk freeze coexist, and clearing one must NOT clear the other.
    function test_pause_and_freeze_are_independent() public {
        vm.startPrank(OWNER);
        admin.pauseAsset(address(pool), address(base));
        admin.freezeAsset(address(pool), address(base));
        uint16 f = pool.getRiskFlags(address(base));
        assertTrue((f & C.PROTOCOL_PAUSED_BIT) != 0 && (f & C.FROZEN_BIT) != 0, "both set");

        admin.unpauseAsset(address(pool), address(base)); // clears ONLY bit6
        f = pool.getRiskFlags(address(base));
        assertEq(f & C.PROTOCOL_PAUSED_BIT, 0, "pause cleared");
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

        assertTrue((pool.getRiskFlags(address(base)) & C.PROTOCOL_PAUSED_BIT) != 0, "good leg paused");

        // unpause the good leg via the batch path too
        tokens[1] = address(base);
        vm.prank(OWNER);
        admin.batchRiskOp(pools, tokens, IAdmin.BatchOp.Unpause);
        assertEq(pool.getRiskFlags(address(base)) & C.PROTOCOL_PAUSED_BIT, 0, "unpaused via batch");
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
        (bool ok, ) = address(pool).call(abi.encodeWithSelector(bytes4(0xdeadbeef)));
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
}
