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
import {MockAC, MockOracle} from "../fixtures/BaseTestSetup.sol";

/// @title AimmDecimals
/// @notice Mixed-decimal pricing tests. base = 6-dec (USDC-like), tok = 18-dec (WETH-like) @ $3000.
///         This is BUG-3's decimal-underflow scenario: volumeFraction = amountIn(6d) * BPS / depth(18d)
///         underflows to 0 for realistic buy sizes → zero size-dependent slippage on the buy side.
contract AimmDecimalsTest is Test {
    PoolFactory factory; Pool poolImpl; Admin admin; Flash flashSingleton; MockAC ac;
    MockOracle oracle;
    Pool pool; MockERC20 base; MockERC20 tok;
    address constant OWNER = address(0xA11CE);
    uint256 constant PX = 3000e18;

    function _profile() internal pure returns (IPool.LiquidityProfile memory p) {
        p.weights[0]=50; p.weights[1]=50; p.weights[2]=50; p.weights[3]=50;
        p.knots[0]=-50; p.knots[1]=-25; p.knots[2]=0; p.knots[3]=25; p.knots[4]=50;
    }
    function _risk() internal pure returns (IPool.RiskConfig memory r) {
        r.decayStartRatioBps=5000; r.coverageMin=5000; r.coverageMax=20000;
        r.decaySlope=0; r.depthAmplifier=10000;
        r.flags=C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
    }
    function _oracle(address token) internal view returns (IPool.OracleConfig memory o) {
        o.primary=address(oracle); o.feedId=bytes32(uint256(uint160(token)));
    }

    function setUp() public {
        ac = new MockAC(OWNER);
        admin = new Admin(address(ac));
        flashSingleton = new Flash();
        PoolAux poolAux = new PoolAux(address(ac), address(admin), address(flashSingleton));
        poolImpl = new Pool(address(ac), address(admin), address(flashSingleton), address(poolAux));
        factory = new PoolFactory(address(poolImpl), address(this), address(ac));
        base = new MockERC20("USDC", "USDC", 6);
        tok  = new MockERC20("Weth", "WETH", 18);
        address[] memory toks = new address[](2);
        toks[0]=address(base); toks[1]=address(tok);
        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare:25, flashFeeBps:100, _pad:pad});
        bytes memory initdata = abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
        pool = Pool(payable(factory.createPool(address(base), toks, initdata)));

        oracle = new MockOracle();
        oracle.setMark(address(base), M.encodeB64(1e18, 18));
        oracle.setMark(address(tok),  M.encodeB64(PX, 18));
        IPool.RiskConfig memory rc=_risk(); IPool.LiquidityProfile memory pf=_profile();
        vm.startPrank(OWNER);
        admin.addAsset(address(pool), address(base), _oracle(address(base)), rc, pf, 1000, 6,  1000, 100000, 10000, 10000);
        admin.addAsset(address(pool), address(tok),  _oracle(address(tok)),  rc, pf, 1000, 18, 1000, 100000, 10000, 10000);
        vm.stopPrank();

        base.mint(address(this), 100_000_000e6);
        tok.mint(address(this), 100_000e18);
        base.approve(address(pool), type(uint256).max);
        tok.approve(address(pool), type(uint256).max);
        pool.deposit(address(base), 30_000_000e6); // $30M base (6-dec)
        pool.deposit(address(tok), 10_000e18);       // 10000 WETH = $30M
    }

    /// Buy-side size monotonicity: a bigger buy must pay a strictly higher average price (more
    /// slippage). BUG-3 decimal underflow makes volumeFraction=0 for both → identical avg price.
    function test_buy_size_monotonic_mixed_decimals() public {
        uint256 small = 30_000e6;     // $30k
        uint256 big   = 6_000_000e6;  // $6M (large vs $30M depth)

        IPool.SwapQuote memory qs = pool.getSwapQuote(address(base), address(tok), small);
        IPool.SwapQuote memory qb = pool.getSwapQuote(address(base), address(tok), big);

        // avg price = base paid per tok received (base is 6-dec, tok 18-dec) -> normalize to 1e18 base/tok
        uint256 pSmall = (small * 1e30) / qs.amountOut; // (6d base *1e12 ->18d) *1e18 / 18d tok
        uint256 pBig   = (big   * 1e30) / qb.amountOut;
        assertGt(pBig, pSmall, "BUG-3: buy slippage flat across sizes (decimal underflow)");
    }

    /// Sanity: market not crossed under mixed decimals either.
    function test_no_crossed_market_mixed_decimals() public {
        uint256 baseIn = 300_000e6;
        IPool.SwapQuote memory bq = pool.getSwapQuote(address(base), address(tok), baseIn);
        require(bq.amountOut > 0, "no buy");
        uint256 ask = (baseIn * 1e30) / bq.amountOut; // base/tok 1e18

        uint256 tokIn = 100e18;
        IPool.SwapQuote memory sq = pool.getSwapQuote(address(tok), address(base), tokIn);
        uint256 bid = (sq.amountOut * 1e30) / tokIn;  // (6d base ->18d) per 18d tok... 1e18 base/tok

        assertGe(ask, bid, "CROSSED MARKET (mixed decimals)");
    }
}
