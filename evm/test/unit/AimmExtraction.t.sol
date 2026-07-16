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

/// @title AimmExtraction
/// @notice High-volatility extraction tests for the AIMM pricer. At high dispersion the spline
///         offset (+/- 5% at maxDispersion) dwarfs the 1% fee cap, so a sign error in the
///         sell-side spline (BUG-2) or a dead/mis-decimalled buy path (BUG-3) becomes a CROSSED
///         market (bid > ask) = free round-trip extraction. Expected to FAIL pre-fix.
contract AimmExtractionTest is Test {
  PoolFactory factory;
  Pool poolImpl;
  Admin admin;
  Flash flashSingleton;
  MockAC ac;
  MockOracle oracle;

  Pool pool;
  MockERC20 base; // numeraire, 18d
  MockERC20 tok; // volatile, 18d, price 3000, HIGH vol

  address constant OWNER = address(0xA11CE);
  uint8 constant PROTO_SHARE = 25;
  uint16 constant FLASH_FEE_BPS = 100;
  uint256 constant PX = 3000e18;
  uint32 constant HI_VOL = 100_000_000; // drives dispersion to its max (10%)

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
    r.decaySlope = 0;
    r.depthAmplifier = 10000;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
  }

  function _oracle(address token) internal view returns (IPool.OracleConfig memory o) {
    o.primary = address(oracle);
    o.feedId = bytes32(uint256(uint160(token)));
  }

  function _feedId(address token) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(token)));
  }

  function setUp() public {
    ac = new MockAC(OWNER);
    admin = new Admin(address(ac));
    flashSingleton = new Flash();
    PoolAux poolAux = new PoolAux(address(ac), address(admin), address(flashSingleton));
    poolImpl = new Pool(address(ac), address(admin), address(flashSingleton), address(poolAux));
    factory = new PoolFactory(address(poolImpl), address(this), address(ac));
    base = new MockERC20("Base", "BASE", 18);
    tok = new MockERC20("Tok", "TOK", 18);
    address[] memory toks = new address[](2);
    toks[0] = address(base);
    toks[1] = address(tok);
    IPool.FeeParams memory fp =
      IPool.FeeParams({protoShare: PROTO_SHARE, flashFeeBps: FLASH_FEE_BPS});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
    pool = Pool(payable(factory.createPool(address(base), toks, initdata)));

    oracle = new MockOracle();
    // HIGH σ on both feeds drives dispersion to its max (was the internal vol-EMA seed).
    oracle.setFeed(_feedId(address(base)), M.encodeB64(1e18, 18), HI_VOL, 0, type(uint16).max);
    oracle.setFeed(_feedId(address(tok)), M.encodeB64(PX, 18), HI_VOL, 0, type(uint16).max);
    IPool.RiskConfig memory rc = _risk();
    IPool.LiquidityProfile memory pf = _profile();
    vm.startPrank(OWNER);
    admin.addAsset(
      address(pool),
      address(base),
      _oracle(address(base)),
      rc,
      pf,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    admin.addAsset(
      address(pool),
      address(tok),
      _oracle(address(tok)),
      rc,
      pf,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    vm.stopPrank();

    base.mint(address(this), 100_000_000e18);
    tok.mint(address(this), 100_000e18);
    base.approve(address(pool), type(uint256).max);
    tok.approve(address(pool), type(uint256).max);
    pool.deposit(address(base), 30_000_000e18); // $30M base
    pool.deposit(address(tok), 10_000e18); // 10000 tok = $30M
  }

  /// No crossed market: the price to BUY tok (base paid per tok) must be >= the price to SELL
  /// tok (base received per tok). bid > ask => free round-trip extraction.
  function test_no_crossed_market() public {
    uint256 baseIn = 300_000e18; // buy ~100 tok
    IPool.SwapQuote memory bq = pool.getSwapQuote(address(base), address(tok), baseIn);
    require(bq.amountOut > 0, "no buy out");
    uint256 askPrice = (baseIn * 1e18) / bq.amountOut; // base per tok paid

    uint256 tokIn = 100e18; // sell 100 tok
    IPool.SwapQuote memory sq = pool.getSwapQuote(address(tok), address(base), tokIn);
    uint256 bidPrice = (sq.amountOut * 1e18) / tokIn; // base per tok received

    // bid > ask = crossed market = free round-trip extraction (pre-fix: ask 2941 < bid 2986).
    assertGe(askPrice, bidPrice, "CROSSED MARKET: bid > ask -> free extraction (BUG-2/3)");
  }

  /// Sell-side sanity: selling tok must never yield MORE base than the mark (pre-fee discount).
  function test_sell_not_premium_highvol() public {
    uint256 tokIn = 100e18;
    IPool.SwapQuote memory sq = pool.getSwapQuote(address(tok), address(base), tokIn);
    uint256 bidPrice = (sq.amountOut * 1e18) / tokIn;
    assertLe(bidPrice, PX, "BUG-2: sell yields a premium above TWAP at high vol");
  }
}
