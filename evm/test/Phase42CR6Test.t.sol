// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/modules/Pool.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IPoolHooks} from "../src/interfaces/IPoolHooks.sol";
import {LibConstants as C} from "../src/libraries/LibConstants.sol";

/// @title PoolHarness — exposes _processSwap end-to-end so tests can deploy a real Pool,
///        set up real reserves + real ERC20s + real IPoolHooks, and exercise the actual
///        named-return path that swap() pushes to the user.
/// @dev   Intentionally bypasses Pricing.getAnchorPathQuote (which needs anchor/oracle wiring)
///        by accepting a precomputed SwapQuote. All other helpers (_pull, _exec, _applyHookFee,
///        _postSwap, _reconcile, _push) are the real Pool internals — exactly the surface where
///        Phase 42C R5/R6 lived.
contract PoolHarness is Pool {
    function harnessSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient,
        IPool.SwapQuote calldata qIn
    ) external returns (uint256 out) {
        IPool.PoolStorage storage $ = _s();
        address[2] memory tk = [tokenIn, tokenOut];

        // Mirror swap() w/o quote/oracle plumbing — accept caller-supplied quote.
        IPool.SwapQuote memory q = qIn;
        uint256 actualIn = _pull(tokenIn, amountIn);
        out = _processSwap($, tk, actualIn, q);
        _push(tokenOut, recipient, out);
    }

    // ── Test-only state setters (ERC-7201 namespaced storage). ──
    function setInitialized(bool v) external { _s().initialized = v; }
    function setOwner(address o) external { _s().owner = o; }
    function setBaseToken(address t) external { _s().baseToken = t; }
    function setFeeParams(uint8 protoShare, uint16 flashFeeBps) external {
        _s().feeParams.protoShare = protoShare;
        _s().feeParams.flashFeeBps = flashFeeBps;
    }
    function setAsset(address tk, uint128 reserves, uint128 liabilities, uint8 decimals) external {
        IPool.Asset storage a = _s().assets[tk];
        a.reserves = reserves;
        a.liabilities = liabilities;
        a.decimals = decimals;
        a.lastUpdate = uint32(block.timestamp);
    }
    function setHook(address tk, address hook, uint32 flags) external {
        _s().hooks[tk] = hook;
        _s().hookFlags[tk] = flags;
    }
    function harnessReserves(address tk) external view returns (uint128) {
        return _s().assets[tk].reserves;
    }
    function harnessProtocolFees(address tk) external view returns (uint256) {
        return _s().protocolFees[tk];
    }
    function harnessDebitProtocolFeesTo(address tk, address to, uint256 amt) external {
        _s().protocolFees[tk] -= amt;
        _push(tk, to, amt);
    }
}

/// @title MockHooks — IPoolHooks impl returning a configurable post-swap delta.
contract MockHooks is IPoolHooks {
    int256 public deltaToReturn;
    uint32 public flags = C.HOOK_POST_SWAP;

    function setDelta(int256 d) external { deltaToReturn = d; }
    function hookFlags() external pure returns (uint32) { return C.HOOK_POST_SWAP; }

    function preInitialize(address, address, address, address) external {}
    function postInitialize(address, address, address, address) external {}
    function preDeposit(address, address, address, uint256) external {}
    function postDeposit(address, address, address, uint256, uint256) external returns (uint256, uint256) { return (0, 0); }
    function preWithdraw(address, address, address, uint256) external {}
    function postWithdraw(address, address, address, uint256, uint256) external returns (uint256, uint256) { return (0, 0); }
    function preSwap(address, address, address, address, uint256, uint256) external returns (uint256, uint16) { return (0, 0); }
    function postSwap(address, address, address, address, uint256, uint256) external returns (int256) {
        return deltaToReturn;
    }
    function preDonate(address, address, address, uint256) external {}
    function postDonate(address, address, address, uint256) external {}
    function preFlashLoan(address, address, address, uint256, uint256, bytes calldata) external {}
    function postFlashLoan(address, address, address, uint256, uint256, bytes calldata) external {}
}

/// @title Phase42CR6Test
/// @notice Real integration test for the Phase 42C R6 fix.
///         Reproduces the CRIT regression introduced by R5 (commit 154b603) and pins the
///         R6 remediation: protoDelta is debited from `aOut.reserves` AFTER `_reconcile`
///         while the named-return `out` retains its user-facing value.
///
///         Replaces the prior pure-math fuzz in Phase42CR5Test.t.sol, which modelled a
///         fictional `userOut = out - protoDelta` that did not match production semantics.
contract Phase42CR6Test is Test {
    PoolHarness pool;
    MockHooks hooks;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    address constant USER = address(0xCAFE);
    address constant RECIPIENT = address(0xBEEF);
    uint8 constant PROTO_SHARE = 25;

    function setUp() public {
        pool = new PoolHarness();
        hooks = new MockHooks();
        tokenIn = new MockERC20("In", "IN", 18);
        tokenOut = new MockERC20("Out", "OUT", 18);

        pool.setInitialized(true);
        pool.setOwner(address(this));
        pool.setBaseToken(address(tokenIn));
        pool.setFeeParams(PROTO_SHARE, 5);

        pool.setAsset(address(tokenIn),  1_000_000e18, 1_000_000e18, 18);
        pool.setAsset(address(tokenOut), 1_000_000e18, 1_000_000e18, 18);

        // Hook attached to tokenOut (post-swap branch hits when delta > 0).
        pool.setHook(address(tokenOut), address(hooks), C.HOOK_POST_SWAP);

        // Seed pool balances to match reserves (token conservation requires this).
        tokenOut.mint(address(pool), 1_000_000e18);
        tokenIn.mint(address(pool), 1_000_000e18);
        // tokenIn is pulled from USER on each swap — give USER an allowance + balance.
        tokenIn.mint(USER, 100_000e18);
        vm.prank(USER);
        tokenIn.approve(address(pool), type(uint256).max);
    }

    function _quote(uint256 amountIn, uint256 amountOut, uint16 spreadBps)
        internal pure returns (IPool.SwapQuote memory q)
    {
        q.amountIn = amountIn;
        q.amountOut = amountOut;
        q.spreadBps = spreadBps;
        q.protoFee = 0;
        q.lpFee = 0;
        q.routeHops = new address[](0);
        q.hopAmounts = new uint256[](0);
        q.hopPrices = new uint64[](0);
    }

    /// @dev Token conservation invariant: pool token balance == Σreserves[tk] + protocolFees[tk].
    function _assertInvariant(string memory tag) internal view {
        uint256 balOut = tokenOut.balanceOf(address(pool));
        uint256 reservesOut = pool.harnessReserves(address(tokenOut));
        uint256 protoOut = pool.harnessProtocolFees(address(tokenOut));
        assertEq(balOut, reservesOut + protoOut, string.concat(tag, ": tokenOut balance != reserves + protoFees"));

        uint256 balIn = tokenIn.balanceOf(address(pool));
        uint256 reservesIn = pool.harnessReserves(address(tokenIn));
        uint256 protoIn = pool.harnessProtocolFees(address(tokenIn));
        assertEq(balIn, reservesIn + protoIn, string.concat(tag, ": tokenIn balance != reserves + protoFees"));
    }

    /// @notice CRIT regression: with a non-zero post-swap hook delta and protoShare > 0,
    ///         the user must receive ONLY `q.amountOut` (no protoDelta bonus).
    function test_R6_user_does_not_receive_protoDelta() public {
        uint256 amountIn = 1_000e18;
        uint256 amountOut = 1_000e18; // 1:1 quote, zero core fees.
        int256 hookDelta = 40e18;
        hooks.setDelta(hookDelta);

        IPool.SwapQuote memory q = _quote(amountIn, amountOut, 0);

        uint256 recipBalBefore = tokenOut.balanceOf(RECIPIENT);
        vm.prank(USER);
        uint256 out = pool.harnessSwap(address(tokenIn), address(tokenOut), amountIn, RECIPIENT, q);

        uint256 recipDelta = tokenOut.balanceOf(RECIPIENT) - recipBalBefore;
        // User-facing out: q.amountOut - hookFee = 1000 - 40 = 960e18.
        assertEq(recipDelta, amountOut - uint256(hookDelta), "recipient must NOT receive protoDelta bonus");
        assertEq(out, recipDelta, "harnessSwap return must equal pushed amount");

        // Ledger captured the proto portion.
        uint256 expectedProto = (uint256(hookDelta) * PROTO_SHARE) / 100;
        assertEq(pool.harnessProtocolFees(address(tokenOut)), expectedProto, "ledger must hold protoDelta");

        _assertInvariant("post-swap-1");
    }

    /// @notice Token conservation invariant across multiple swaps with non-zero hook deltas.
    function test_R6_invariant_across_multiple_swaps() public {
        uint256[3] memory amountIns  = [uint256(500e18), uint256(750e18), uint256(1_200e18)];
        uint256[3] memory amountOuts = [uint256(500e18), uint256(750e18), uint256(1_200e18)];
        int256[3]  memory deltas     = [int256(10e18), int256(60e18), int256(0)];

        for (uint256 i; i < 3; ++i) {
            hooks.setDelta(deltas[i]);
            IPool.SwapQuote memory q = _quote(amountIns[i], amountOuts[i], 0);
            uint256 recipBalBefore = tokenOut.balanceOf(RECIPIENT);

            vm.prank(USER);
            uint256 out = pool.harnessSwap(address(tokenIn), address(tokenOut), amountIns[i], RECIPIENT, q);

            uint256 recipDelta = tokenOut.balanceOf(RECIPIENT) - recipBalBefore;
            uint256 expectedUserOut = deltas[i] > 0
                ? amountOuts[i] - uint256(deltas[i])
                : amountOuts[i];
            assertEq(recipDelta, expectedUserOut, "user out mismatch at swap i");
            assertEq(out, recipDelta, "named return must equal pushed amount");
            _assertInvariant(string.concat("swap ", vm.toString(i)));
        }
    }

    /// @notice After draining the protocol-fee ledger via Treasury-equivalent collect, the
    ///         pool's tokenOut balance must remain >= Σreserves (no LP-reserve raid).
    function test_R6_treasury_collect_does_not_drain_LP() public {
        // Run two swaps to accumulate protoDelta in the ledger.
        hooks.setDelta(40e18);
        IPool.SwapQuote memory q1 = _quote(1_000e18, 1_000e18, 0);
        vm.prank(USER);
        pool.harnessSwap(address(tokenIn), address(tokenOut), 1_000e18, RECIPIENT, q1);

        hooks.setDelta(80e18);
        IPool.SwapQuote memory q2 = _quote(2_000e18, 2_000e18, 0);
        vm.prank(USER);
        pool.harnessSwap(address(tokenIn), address(tokenOut), 2_000e18, RECIPIENT, q2);

        uint256 protoBefore = pool.harnessProtocolFees(address(tokenOut));
        assertGt(protoBefore, 0, "proto ledger should be populated");

        uint256 reservesBefore = pool.harnessReserves(address(tokenOut));
        address treasury = address(0x7123);

        // Drain the ledger to "treasury" — analogous to Admin.collectProtocolFees.
        pool.harnessDebitProtocolFeesTo(address(tokenOut), treasury, protoBefore);

        // Treasury received exactly protoBefore.
        assertEq(tokenOut.balanceOf(treasury), protoBefore, "treasury should receive protoDelta total");
        // Pool's tokenOut balance now == reserves only; LP reserves were NOT raided.
        assertEq(tokenOut.balanceOf(address(pool)), reservesBefore, "post-collect: pool balance == reserves (no LP raid)");
        assertEq(pool.harnessProtocolFees(address(tokenOut)), 0, "ledger drained");
    }

    /// @notice delta == 0 path: pool behaves identically to pre-fix world (no protoDelta logic).
    function test_R6_zero_delta_no_op() public {
        hooks.setDelta(0);
        IPool.SwapQuote memory q = _quote(500e18, 500e18, 0);
        uint256 protoBefore = pool.harnessProtocolFees(address(tokenOut));

        vm.prank(USER);
        uint256 out = pool.harnessSwap(address(tokenIn), address(tokenOut), 500e18, RECIPIENT, q);

        assertEq(out, 500e18, "zero-delta path: out == amountOut");
        assertEq(pool.harnessProtocolFees(address(tokenOut)), protoBefore, "zero-delta: no proto credit");
        _assertInvariant("zero-delta");
    }

    /// @notice Fuzz across amountIn / amountOut / hookDelta — invariant must hold ∀ inputs.
    function testFuzz_R6_invariant(
        uint96 amountIn,
        uint96 amountOut,
        uint96 hookDelta
    ) public {
        amountIn  = uint96(bound(uint256(amountIn),  1e15, 100_000e18));
        amountOut = uint96(bound(uint256(amountOut), 1e15, 500_000e18));
        // Hook fee can't exceed amountOut (else `_applyHookFee` clamps `out` to 0).
        hookDelta = uint96(bound(uint256(hookDelta), 0, uint256(amountOut)));

        // Top up USER if needed.
        if (tokenIn.balanceOf(USER) < amountIn) tokenIn.mint(USER, uint256(amountIn));

        hooks.setDelta(int256(uint256(hookDelta)));
        IPool.SwapQuote memory q = _quote(amountIn, amountOut, 0);

        uint256 recipBalBefore = tokenOut.balanceOf(RECIPIENT);
        vm.prank(USER);
        uint256 out = pool.harnessSwap(address(tokenIn), address(tokenOut), amountIn, RECIPIENT, q);

        uint256 recipDelta = tokenOut.balanceOf(RECIPIENT) - recipBalBefore;
        assertEq(recipDelta, out, "recipient delta == named return");
        assertLe(recipDelta, amountOut, "user can never receive more than quoted amount");

        // Token conservation.
        _assertInvariant("fuzz");
    }
}
