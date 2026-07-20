// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {Admin} from "../src/Admin.sol";
import {Flash} from "../src/Flash.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {BaseTestSetup, MockAC, MockOracle} from "./fixtures/BaseTestSetup.sol";

/// @title PoolSwapAccountingTest
/// @notice Quote-time protoFee + token-conservation (R8) accounting.
///         Target invariant: pool ERC20 balance == reserves[token] + protocolFees[token] post-swap.
contract PoolSwapAccountingTest is BaseTestSetup {
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

  function setUp() public override {
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
    IPool.FeeParams memory fp = IPool.FeeParams({protoShare: PROTO_SHARE, flashFeePbps: 100});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
    address pa = factory.createPool(address(base), toks, initdata);
    pool = Pool(payable(pa));

    oracle = new MockOracle();
    oracle.setMark(address(base), M.encodeB64(1e18, 18));
    oracle.setMark(address(quote), M.encodeB64(1e18, 18));
    IPool.RiskConfig memory rc = _risk();
    vm.startPrank(OWNER);
    admin.setCurve(pa, DEFAULT_PRESET, defaultCurveInterior(), defaultCurveWQ(), 1000, 0);
    admin.addAsset(
      pa,
      address(base),
      _oracleCfg(address(base)),
      rc,
      DEFAULT_PRESET,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    admin.addAsset(
      pa,
      address(quote),
      _oracleCfg(address(quote)),
      rc,
      DEFAULT_PRESET,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    vm.stopPrank();

    // Seed both sides w/ liquidity so swaps execute.
    uint256 seed = 1_000_000e18;
    base.mint(address(this), seed);
    base.approve(address(pool), type(uint256).max);
    pool.deposit(address(base), seed);
    quote.mint(address(this), seed);
    quote.approve(address(pool), type(uint256).max);
    pool.deposit(address(quote), seed);
  }

  /// @notice R8 HIGH: post-swap, pool balance == reserves + protocolFees for tokenOut.
  ///         If `_exec` reverts to `aOut.reserves -= q.amountOut` (drop `+ q.protoFee`),
  ///         then reserves overshoot by protoFee → invariant breaks (reserves+fees > balance).
  function test_R8_token_conservation_post_swap() public {
    uint256 amt = 100e18;
    base.mint(USER, amt);
    vm.prank(USER);
    base.approve(address(pool), type(uint256).max);

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

  /// @notice LP profitability: a swap must NEVER reduce total LP reserve value. base/quote both mark
  ///         1:1, so aggregate LP value = reservesBase + reservesQuote. Pre-fix the input-side fee was
  ///         skimmed 100% into protocolFees[tkIn] while the output was priced off the full input, so
  ///         LP net was negative (-protoFee/swap) and treasury over-collected. Now the fee is charged
  ///         once on the output; LP retains lpFee + price-impact and the treasury only takes protoFee.
  function test_LP_reserve_value_never_decreases_on_swap() public {
    uint256 amt = 10_000e18;
    base.mint(USER, amt);
    vm.prank(USER);
    base.approve(address(pool), type(uint256).max);

    uint256 lpBefore =
      uint256(pool.getAsset(address(base)).reserves) + pool.getAsset(address(quote)).reserves;
    uint256 protoQBefore = pool.getProtocolFees(address(quote));

    vm.prank(USER);
    pool.swap(address(base), address(quote), amt, 0, USER);

    uint256 lpAfter =
      uint256(pool.getAsset(address(base)).reserves) + pool.getAsset(address(quote)).reserves;
    assertGe(lpAfter, lpBefore, "LP total reserve value must not decrease on a swap");
    // Fee is taken on the output side only; treasury still earns its protoFee share.
    assertGt(
      pool.getProtocolFees(address(quote)) - protoQBefore, 0, "treasury earns protoFee on output"
    );
    // Input side must NOT be skimmed into the treasury (the drained-LP vector).
    assertEq(pool.getProtocolFees(address(base)), 0, "no input-side protocol fee");
  }

  /// @notice R8 fuzz: conservation holds across a range of input sizes.
  function test_R8_conservation_fuzz(uint96 amtFuzz) public {
    uint256 amt = bound(uint256(amtFuzz), 1e15, 100_000e18);
    base.mint(USER, amt);
    vm.prank(USER);
    base.approve(address(pool), type(uint256).max);
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
    vm.prank(USER);
    base.approve(address(pool), type(uint256).max);
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
    vm.prank(USER);
    base.approve(address(pool), type(uint256).max);
    uint256 before = quote.balanceOf(USER);
    vm.prank(USER);
    uint256 out = pool.swap(address(base), address(quote), amt, 0, USER);
    assertEq(quote.balanceOf(USER) - before, out, "user received exactly out");
  }
}
