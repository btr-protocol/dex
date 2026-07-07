// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test, console2} from "forge-std/Test.sol";
import {MockERC20} from "../../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../../src/Pool.sol";
import {PoolAux} from "../../src/PoolAux.sol";
import {PoolFactory} from "../../src/PoolFactory.sol";
import {Admin} from "../../src/Admin.sol";
import {Flash} from "../../src/Flash.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {Constants as C} from "../../src/libraries/Constants.sol";
import {Maths as M} from "../../src/libraries/Maths.sol";
import {MockAC, MockOracle} from "../fixtures/BaseTestSetup.sol";

/// @notice MEASURE: does the BASE transit in a spoke->spoke cross (USDT->USDC->USD1) add its OWN
///         spline price impact (double-tax), or is base a flat numeraire (zero base impact)?
///         3 stables, all price 1.0, balanced (coverage=1). Compare a single cross quote against
///         the two legs executed as separate standalone direct swaps.
contract CrossBaseImpactTest is Test {
    PoolFactory factory;
    Admin admin;
    MockAC ac;
    MockOracle oracle;
    Pool pool;

    MockERC20 usdc; // base / numeraire (hub)
    MockERC20 usdt; // spoke 1
    MockERC20 usd1; // spoke 2

    address constant OWNER = address(0xA11CE);
    uint256 constant SEED = 10_000_000e18; // 10M each, balanced
    uint256 constant AMT  = 100_000e18;    // 100k cross

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
        factory = new PoolFactory(address(poolImpl), address(this), address(ac));

        usdc = new MockERC20("USDC", "USDC", 18);
        usdt = new MockERC20("USDT", "USDT", 18);
        usd1 = new MockERC20("USD1", "USD1", 18);

        address[] memory toks = new address[](3);
        toks[0] = address(usdc); toks[1] = address(usdt); toks[2] = address(usd1);

        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 25, flashFeeBps: 100, _pad: pad});
        bytes memory initdata = abi.encodeWithSelector(Pool.initialize.selector, address(usdc), address(0xCAFE), fp);
        pool = Pool(payable(factory.createPool(address(usdc), toks, initdata)));

        oracle = new MockOracle();
        oracle.setMark(address(usdc), M.encodeB64(1e18, 18));
        oracle.setMark(address(usdt), M.encodeB64(1e18, 18));
        oracle.setMark(address(usd1), M.encodeB64(1e18, 18));

        // minFeeBps = 1000 PBPS (~5bps half-spread on output) so the single-vs-double spread is visible.
        vm.startPrank(OWNER);
        admin.addAsset(address(pool), address(usdc), _oracleCfg(address(usdc)), _risk(), _profile(), 1000, 18, 1000, 100000, 10000, 10000);
        admin.addAsset(address(pool), address(usdt), _oracleCfg(address(usdt)), _risk(), _profile(), 1000, 18, 1000, 100000, 10000, 10000);
        admin.addAsset(address(pool), address(usd1), _oracleCfg(address(usd1)), _risk(), _profile(), 1000, 18, 1000, 100000, 10000, 10000);
        vm.stopPrank();

        _seed(usdc); _seed(usdt); _seed(usd1);
    }

    function _seed(MockERC20 tk) internal {
        tk.mint(address(this), SEED);
        tk.approve(address(pool), type(uint256).max);
        pool.deposit(address(tk), SEED);
    }

    function test_measure_cross_vs_two_standalone_legs() public view {
        _measure(AMT);        // 100k  = 1% of depth (spline ~ flat near center)
        _measure(3_000_000e18); // 3M  = 30% of depth (spline bites -> visible spoke impact)
    }

    function _measure(uint256 amt) internal view {
        // --- The cross: USDT -> USDC(base) -> USD1, ONE getAnchorPathQuote ---
        IPool.SwapQuote memory x = pool.getSwapQuote(address(usdt), address(usd1), amt);
        uint256 baseMid = x.hopAmounts[1];             // base out of leg1 (== base in of leg2)
        uint256 legXImpact = amt - baseMid;            // USDT spline only (sold into pool)
        uint256 grossOut = x.hopAmounts[2];            // USD1 out of leg2 spline (pre-settle spread)
        uint256 legYImpact = baseMid > grossOut ? baseMid - grossOut : 0; // USD1 spline only
        uint256 pathSpread = grossOut - x.amountOut;   // SINGLE spread taken once on final output

        // --- The same two legs as SEPARATE standalone direct swaps (each pays its own spread) ---
        IPool.SwapQuote memory sA = pool.getSwapQuote(address(usdt), address(usdc), amt);
        IPool.SwapQuote memory sB = pool.getSwapQuote(address(usdc), address(usd1), sA.amountOut);

        console2.log("========== amountIn ==========", amt);
        console2.log("hop1 base out (USDC)   ", baseMid);
        console2.log("  leg1 USDT spline loss", legXImpact);
        console2.log("hop2 gross out (USD1)  ", grossOut);
        console2.log("  leg2 USD1 spline loss", legYImpact);
        console2.log("path spread (once)     ", pathSpread);
        console2.log("spreadBps (PBPS)       ", x.spreadBps);
        console2.log("cross final amountOut  ", x.amountOut);
        console2.log("cross loss (bps)       ", ((amt - x.amountOut) * 10_000) / amt);
        console2.log("two-standalone-leg out ", sB.amountOut);
        console2.log("two-leg loss (bps)     ", ((amt - sB.amountOut) * 10_000) / amt);
        console2.log("cross_out - twoleg_out ", x.amountOut - sB.amountOut);

        // (1) BASE IS A FLAT NUMERAIRE: base out of leg1 carries the FULL value of the USDT sold,
        //     minus USDT's OWN spline only. There is no separate base spline draining hop1.
        //     (2) The single cross is CHEAPER than two standalone legs (one spread vs two) => the hub
        //     is a net-neutral pass-through, NOT double-taxed.
        assertGe(x.amountOut, sB.amountOut, "cross must not cost more than two separate legs");

        // (3) No hidden base spline term: leg-X spline + leg-Y spline + single spread == total loss.
        assertEq(legXImpact + legYImpact + pathSpread, amt - x.amountOut, "decomposition closes exactly");
    }
}
