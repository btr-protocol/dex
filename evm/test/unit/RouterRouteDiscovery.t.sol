// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../../src/Pool.sol";
import {PoolAux} from "../../src/PoolAux.sol";
import {PoolFactory} from "../../src/PoolFactory.sol";
import {Admin} from "../../src/Admin.sol";
import {Flash} from "../../src/Flash.sol";
import {Router} from "../../src/Router.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {IExchange} from "../../src/interfaces/modules/IExchange.sol";
import {IRouter} from "../../src/interfaces/IRouter.sol";
import {Constants as C} from "../../src/libraries/Constants.sol";
import {Maths as M} from "../../src/libraries/Maths.sol";
import {MockAC, MockOracle} from "../fixtures/BaseTestSetup.sol";

/// @title RouterRouteDiscoveryTest
/// @notice BUG#2 regression: Router route discovery (getBestRoute / getBestDirectQuote) MUST return a
///         non-zero quote for a funded, official pool. It previously returned 0 for every pool because
///         `Pool.getSwapQuote` was non-view and wrote the transient oracle cache in its quote path; the
///         Router's `view` STATICCALL then reverted on the tstore and the try/catch swallowed it. The
///         fix makes the quote-only path a pure `view` (no cache write), so the STATICCALL succeeds.
contract RouterRouteDiscoveryTest is Test {
    PoolFactory factory;
    Admin admin;
    MockAC ac;
    MockOracle oracle;
    Router router;

    Pool pool;
    MockERC20 base;
    MockERC20 quote;

    address constant OWNER = address(0xA11CE);
    address constant USER = address(0xBEEF);

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

    function setUp() public {
        ac = new MockAC(OWNER);
        admin = new Admin(address(ac));
        Flash flash = new Flash();
        PoolAux poolAux = new PoolAux(address(ac), address(admin), address(flash));
        Pool poolImpl = new Pool(address(ac), address(admin), address(flash), address(poolAux));

        // protocolDeployer = address(this) ⇒ pools this test creates are OFFICIAL (route-discovery only
        // scans official pools).
        factory = new PoolFactory(address(poolImpl), address(this), address(ac));

        base = new MockERC20("Base", "BASE", 18);
        quote = new MockERC20("Quote", "QUOT", 18);

        address[] memory toks = new address[](2);
        toks[0] = address(base);
        toks[1] = address(quote);

        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 25, flashFeeBps: 100, _pad: pad});
        bytes memory initdata =
            abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
        pool = Pool(payable(factory.createPool(address(base), toks, initdata)));

        oracle = new MockOracle();
        oracle.setMark(address(base), M.encodeB64(1e18, 18));
        oracle.setMark(address(quote), M.encodeB64(1e18, 18));

        vm.startPrank(OWNER);
        admin.addAsset(address(pool), address(base), _oracleCfg(address(base)), _risk(), _profile(), 1000, 18, 1000, 100000, 10000, 10000);
        admin.addAsset(address(pool), address(quote), _oracleCfg(address(quote)), _risk(), _profile(), 1000, 18, 1000, 100000, 10000, 10000);
        vm.stopPrank();

        // Fund reserves on both legs so quotes are non-zero.
        _seed(base, 1_000_000e18);
        _seed(quote, 1_000_000e18);

        router = new Router(address(ac));
        vm.prank(OWNER);
        router.initialize(address(factory));
    }

    function _seed(MockERC20 tk, uint256 amt) internal {
        tk.mint(address(this), amt);
        tk.approve(address(pool), type(uint256).max);
        pool.deposit(address(tk), amt);
    }

    /// Audit fix: Router.initialize enforces msg.sender == AC.owner(), so a front-run in a non-atomic
    /// proxy deploy reverts instead of permanently binding an attacker-supplied factory.
    function test_initialize_nonOwner_reverts() public {
        Router r = new Router(address(ac));
        vm.prank(address(0xBAD));
        vm.expectRevert(); // Ownable.Unauthorized
        r.initialize(address(factory));
    }

    /// getBestDirectQuote MUST resolve the funded official pool with a non-zero output — the assertion
    /// that was missing and let the STATICCALL/tstore regression ship.
    function test_getBestDirectQuote_nonZero() public view {
        uint256 amtIn = 1_000e18;
        (address bestPool, IExchange.SwapQuote memory q) =
            router.getBestDirectQuote(address(base), address(quote), amtIn);
        assertEq(bestPool, address(pool), "resolves the funded official pool");
        assertGt(q.amountOut, 0, "direct quote is non-zero");
    }

    /// getBestRoute (the full discovery tree entry) must also produce a non-zero route + step.
    function test_getBestRoute_nonZero() public view {
        uint256 amtIn = 1_000e18;
        (IRouter.Route memory route, uint256 amountOut) =
            router.getBestRoute(address(base), address(quote), amtIn);
        assertGt(amountOut, 0, "route amountOut is non-zero");
        assertEq(route.steps.length, 1, "single direct step");
        assertEq(route.steps[0].pool, address(pool), "step targets the funded pool");
    }

    /// Reverse direction (quote -> base) also resolves.
    function test_getBestDirectQuote_reverse_nonZero() public view {
        (address bestPool, IExchange.SwapQuote memory q) =
            router.getBestDirectQuote(address(quote), address(base), 1_000e18);
        assertEq(bestPool, address(pool), "reverse resolves pool");
        assertGt(q.amountOut, 0, "reverse quote non-zero");
    }

    /// The quote must equal a direct Pool.getSwapQuote (Router is a faithful pass-through), and the
    /// swap exec path must still deliver output ≈ the quoted amount (exec caching path unbroken).
    function test_quote_matches_and_swap_exec_works() public {
        uint256 amtIn = 1_000e18;
        (, IExchange.SwapQuote memory rq) = router.getBestDirectQuote(address(base), address(quote), amtIn);
        IPool.SwapQuote memory pq = pool.getSwapQuote(address(base), address(quote), amtIn);
        assertEq(rq.amountOut, pq.amountOut, "router quote == pool view quote");

        base.mint(USER, amtIn);
        vm.startPrank(USER);
        base.approve(address(pool), type(uint256).max);
        uint256 out = pool.swap(address(base), address(quote), amtIn, 0, USER);
        vm.stopPrank();

        assertGt(out, 0, "direct swap exec delivers output");
        assertEq(out, pq.amountOut, "exec output == pre-quoted amount");
        assertEq(quote.balanceOf(USER), out, "recipient received output");
    }
}
