// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {Admin} from "../src/Admin.sol";
import {Staking} from "../src/Staking.sol";
import {Flash} from "../src/Flash.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IPoolHooks} from "../src/interfaces/IPoolHooks.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {Maths as M} from "../src/libraries/Maths.sol";
import {MockAC} from "./fixtures/BaseTestSetup.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @notice MockHooks: records inbound calls + returns configurable fee/delta.
contract MockHooks is IPoolHooks {
    uint256 public hookFeePost;
    int256  public hookDeltaPost;

    function setPostSwapFee(uint256 fee) external { hookFeePost = fee; }
    function setPostSwapDelta(int256 d) external  { hookDeltaPost = d; }

    function hookFlags() external pure returns (uint32) { return C.HOOK_PRE_SWAP | C.HOOK_POST_SWAP; }

    // unused
    function preInitialize(address,address,address,address) external {}
    function postInitialize(address,address,address,address) external {}
    function preDeposit(address,address,address,uint256) external {}
    function postDeposit(address,address,address,uint256,uint256) external returns (uint256, uint256) {}
    function preWithdraw(address,address,address,uint256) external {}
    function postWithdraw(address,address,address,uint256,uint256) external returns (uint256, uint256) {}
    function preSwap(address,address,address,address,uint256,uint256) external returns (uint256, uint16) { return (0,0); }
    function postSwap(address,address,address,address,uint256,uint256) external view returns (int256) { return hookDeltaPost; }
    function preDonate(address,address,address,uint256) external {}
    function postDonate(address,address,address,uint256) external {}
    function preFlashLoan(address,address,address,uint256,uint256,bytes calldata) external {}
    function postFlashLoan(address,address,address,uint256,uint256,bytes calldata) external {}
}

/// @title Phase42HB3eR8R6Test
/// @notice R8 HIGH (Pool._exec quote-time protoFee accounting) +
///         R6 (Pool post-swap hook protoDelta accounting) -re-port onto flat-Pool.
///         Target invariant: pool ERC20 balance == reserves[token] + protocolFees[token] post-swap.
contract Phase42HB3eR8R6Test is Test {
    PoolFactory factory;
    Pool poolImpl;
    Admin admin;
    Staking stakingSingleton;
    Flash flashSingleton;
    MockAC ac;
    Pool pool;
    MockERC20 base;
    MockERC20 quote;

    address constant OWNER = address(0xA11CE);
    address constant USER  = address(0xBEEF);
    uint8  constant PROTO_SHARE = 25;

    function _profile() internal pure returns (IPool.LiquidityProfile memory p) {
        p.weights[0] = 50; p.weights[1] = 50; p.weights[2] = 50; p.weights[3] = 50;
        p.knots[0] = -50; p.knots[1] = -25; p.knots[2] = 0; p.knots[3] = 25; p.knots[4] = 50;
    }
    function _risk() internal pure returns (IPool.RiskConfig memory r) {
        r.decayStartRatioBps = 5000;
        r.coverageMin = 5000;
        r.coverageMax = 20000;
        r.depthAmplifier = 10000;
        r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT | C.STAKEABLE_BIT;
    }
    function _oracleCfg() internal view returns (IPool.OracleConfig memory o) {
        o.primary = address(pool); o.modeFlags = C.MODE_USE_INTERNAL; o.accDecimals = 18;
    }

    function setUp() public {
        ac = new MockAC(OWNER);
        admin            = new Admin(address(ac));
        stakingSingleton = new Staking(address(ac));
        flashSingleton   = new Flash();
        PoolAux poolAux  = new PoolAux(address(ac), address(admin), address(stakingSingleton), address(flashSingleton));
        poolImpl         = new Pool(address(ac), address(admin), address(stakingSingleton), address(flashSingleton), address(poolAux));
        factory = new PoolFactory(address(poolImpl), address(this), address(ac));

        base  = new MockERC20("Base",  "BASE", 18);
        quote = new MockERC20("Quote", "QUOT", 18);
        address[] memory toks = new address[](2);
        toks[0] = address(base); toks[1] = address(quote);

        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: PROTO_SHARE, flashFeeBps: 100, _pad: pad});
        bytes memory initdata = abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
        address pa = factory.createPool(address(base), toks, initdata);
        pool = Pool(payable(pa));

        IPool.OracleConfig memory oc = _oracleCfg();
        IPool.RiskConfig memory rc = _risk();
        IPool.LiquidityProfile memory pf = _profile();
        uint64 px = M.encodeB64(1e18, 18);
        vm.startPrank(OWNER);
        admin.addAsset(pa, address(base),  oc, rc, pf, 1000, 18, px, 10_000, 10_000, 1000, 100000, 10000, 10000, 10000);
        admin.addAsset(pa, address(quote), oc, rc, pf, 1000, 18, px, 10_000, 10_000, 1000, 100000, 10000, 10000, 10000);
        vm.stopPrank();

        // Seed both sides w/ liquidity so swaps execute.
        uint256 seed = 1_000_000e18;
        base.mint(address(this), seed);  base.approve(address(pool), type(uint256).max);
        pool.deposit(address(base), seed);
        quote.mint(address(this), seed); quote.approve(address(pool), type(uint256).max);
        pool.deposit(address(quote), seed);
    }

    /// @notice R8 HIGH: post-swap, pool balance == reserves + protocolFees for tokenOut.
    ///         If `_exec` reverts to `aOut.reserves -= q.amountOut` (drop `+ q.protoFee`),
    ///         then reserves overshoot by protoFee → invariant breaks (reserves+fees > balance).
    function test_R8_token_conservation_post_swap() public {
        uint256 amt = 100e18;
        base.mint(USER, amt);
        vm.prank(USER); base.approve(address(pool), type(uint256).max);

        vm.prank(USER);
        uint256 out = pool.swap(address(base), address(quote), amt, 0, USER);
        assertGt(out, 0, "swap out");

        uint256 balOut = quote.balanceOf(address(pool));
        uint256 reservesOut = pool.getAsset(address(quote)).reserves;
        uint256 feesOut = pool.getProtocolFees(address(quote));
        assertEq(balOut, reservesOut + feesOut, "R8 conservation tokenOut");

        uint256 balIn = base.balanceOf(address(pool));
        uint256 reservesIn = pool.getAsset(address(base)).reserves;
        uint256 feesIn = pool.getProtocolFees(address(base));
        assertEq(balIn, reservesIn + feesIn, "R8 conservation tokenIn");

        // Sanity: protoFee was actually charged on tokenOut (otherwise invariant is trivial).
        assertGt(feesOut, 0, "protoFee charged on tokenOut");
    }

    /// @notice R8 fuzz: conservation holds across a range of input sizes.
    function test_R8_conservation_fuzz(uint96 amtFuzz) public {
        uint256 amt = bound(uint256(amtFuzz), 1e15, 100_000e18);
        base.mint(USER, amt);
        vm.prank(USER); base.approve(address(pool), type(uint256).max);
        vm.prank(USER);
        try pool.swap(address(base), address(quote), amt, 0, USER) returns (uint256) {
            uint256 balOut = quote.balanceOf(address(pool));
            uint256 reservesOut = pool.getAsset(address(quote)).reserves;
            uint256 feesOut = pool.getProtocolFees(address(quote));
            assertEq(balOut, reservesOut + feesOut, "fuzz conservation tokenOut");
        } catch {
            // Some fuzz inputs revert (oracle floor / threshold) -invariant only on success path.
        }
    }

    /// @notice R8 multi-swap: invariant survives several back-to-back swaps.
    function test_R8_conservation_multi_swap() public {
        uint256 amt = 50e18;
        base.mint(USER, amt * 5);
        vm.prank(USER); base.approve(address(pool), type(uint256).max);
        for (uint256 i; i < 5; ++i) {
            vm.prank(USER);
            pool.swap(address(base), address(quote), amt, 0, USER);
        }
        uint256 balOut = quote.balanceOf(address(pool));
        uint256 reservesOut = pool.getAsset(address(quote)).reserves;
        uint256 feesOut = pool.getProtocolFees(address(quote));
        assertEq(balOut, reservesOut + feesOut, "multi-swap conservation");
    }

    /// @notice R8 quote-time amountOut consistency: external balance delta matches `out`.
    function test_R8_user_received_equals_out() public {
        uint256 amt = 50e18;
        base.mint(USER, amt);
        vm.prank(USER); base.approve(address(pool), type(uint256).max);
        uint256 before = quote.balanceOf(USER);
        vm.prank(USER);
        uint256 out = pool.swap(address(base), address(quote), amt, 0, USER);
        assertEq(quote.balanceOf(USER) - before, out, "user received exactly out");
    }

    /// @notice R6: post-swap hook returning a positive delta charges protoDelta to reserves
    ///         AND the user does NOT receive that delta. Conservation holds.
    function test_R6_post_swap_hook_protoDelta_accounted() public {
        // Wire a MockHooks on tokenOut (quote) with HOOK_POST_SWAP flag.
        // Storage layout slots (PoolStorage @ slot 0):
        //   slot 8 = hooks mapping; slot 9 = hookFlags mapping.
        MockHooks hk = new MockHooks();
        hk.setPostSwapDelta(int256(1e18)); // +1e18 fee diverted via post-swap hook

        bytes32 hookSlot = keccak256(abi.encode(address(quote), uint256(8)));
        bytes32 flagSlot = keccak256(abi.encode(address(quote), uint256(9)));
        vm.store(address(pool), hookSlot, bytes32(uint256(uint160(address(hk)))));
        vm.store(address(pool), flagSlot, bytes32(uint256(C.HOOK_POST_SWAP)));

        // sanity: hook reads reflect what we wrote
        assertEq(pool.getHookForFlag(address(quote), C.HOOK_POST_SWAP), address(hk), "hook wired");

        uint256 amt = 100e18;
        base.mint(USER, amt);
        vm.prank(USER); base.approve(address(pool), type(uint256).max);

        uint256 userBefore = quote.balanceOf(USER);
        vm.prank(USER);
        uint256 out = pool.swap(address(base), address(quote), amt, 0, USER);

        // Conservation invariant on tokenOut after hook delta applied.
        uint256 balOut = quote.balanceOf(address(pool));
        uint256 reservesOut = pool.getAsset(address(quote)).reserves;
        uint256 feesOut = pool.getProtocolFees(address(quote));
        assertEq(balOut, reservesOut + feesOut, "R6 conservation w/ hook delta");

        // User received exactly `out` -hook delta did NOT leak to user.
        assertEq(quote.balanceOf(USER) - userBefore, out, "user got out, no hook leak");
    }
}
