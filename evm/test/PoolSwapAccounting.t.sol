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
import {BaseTestSetup, MockAC, MockOracle, NO_DEADLINE} from "./fixtures/BaseTestSetup.sol";
import {Vm} from "forge-std/Vm.sol";

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

  /// @dev M-1: EXTERNAL spokes must carry a cumulative bound; armed via the shared mirror-ref fixture.
  function _oracleCfg(address token) internal returns (IPool.OracleConfig memory o) {
    o = externalOracleCfg(oracle, token);
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
    uint256 out = pool.swap(address(base), address(quote), amt, 0, USER, NO_DEADLINE);
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
    pool.swap(address(base), address(quote), amt, 0, USER, NO_DEADLINE);

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

  /// @notice #71: the swap LP fee must land in LP CLAIM, not sit above liabilities as dead coverage.
  ///         Pre-fix `q.lpFee` was split at Pricing and never read again: liabilities and the index
  ///         were untouched, so realised LP return from swaps was exactly zero and the fee was
  ///         unclaimable by LPs, governance or treasury.
  function test_lpFee_raises_liquidityIndex_and_liabilities() public {
    uint256 amt = 100e18;
    base.mint(USER, amt);
    vm.prank(USER);
    base.approve(address(pool), type(uint256).max);

    IPool.SwapQuote memory q = pool.getSwapQuote(address(base), address(quote), amt);
    assertGt(q.lpFee, 0, "fixture must charge a nonzero LP fee");

    IPool.Asset memory before = pool.getAsset(address(quote));
    vm.prank(USER);
    pool.swap(address(base), address(quote), amt, 0, USER, NO_DEADLINE);
    IPool.Asset memory afterA = pool.getAsset(address(quote));

    assertEq(
      uint256(afterA.liabilities), uint256(before.liabilities) + q.lpFee, "liabilities += lpFee"
    );
    assertGt(
      uint256(afterA.liquidityIndex), uint256(before.liquidityIndex), "index must rise on the fee"
    );
    // Booking the fee must not have moved reserves: the accrual is claim-side only.
    assertEq(
      uint256(afterA.reserves),
      uint256(before.reserves) - q.amountOut - q.protoFee,
      "reserves untouched by the accrual"
    );
  }

  /// @notice The move is logged as its own reason so an indexer can separate realised fee APR from
  ///         donate and hook yield. Untested, the constant is decorative.
  function test_lpFee_logs_INDEX_REASON_FEE() public {
    uint256 amt = 100e18;
    base.mint(USER, amt);
    vm.prank(USER);
    base.approve(address(pool), type(uint256).max);

    vm.recordLogs();
    vm.prank(USER);
    pool.swap(address(base), address(quote), amt, 0, USER, NO_DEADLINE);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool found;
    for (uint256 i; i < logs.length; ++i) {
      if (logs[i].topics[0] != IPool.IndexUpdated.selector) continue;
      if (address(uint160(uint256(logs[i].topics[1]))) != address(quote)) continue;
      (,,, uint8 reason) = abi.decode(logs[i].data, (uint256, uint128, uint128, uint8));
      if (reason == C.INDEX_REASON_FEE) found = true;
    }
    assertTrue(found, "swap must log IndexUpdated(reason=FEE) on the output leg");
  }

  /// @notice The cross-asset withdraw leg charges the same output-side spread and stranded it the
  ///         same way. Third patched money path; nothing else covers it.
  function test_crossWithdraw_lpFee_accrues_on_the_output_leg() public {
    IPool.Asset memory before = pool.getAsset(address(quote));
    uint256 lp = pool.getLPBalance(address(this), address(base)) / 10;
    skip(60); // clear the JIT cooldown from setUp's deposit

    pool.withdrawTo(address(base), address(quote), lp, 0, NO_DEADLINE);

    IPool.Asset memory afterA = pool.getAsset(address(quote));
    assertGt(uint256(afterA.liquidityIndex), uint256(before.liquidityIndex), "out-leg index rises");
    assertGt(uint256(afterA.liabilities), uint256(before.liabilities), "out-leg liabilities rise");
  }

  /// @notice The supply invariant survives the accrual: outstanding claim never exceeds liabilities.
  ///         `address(this)` is the sole quote LP in this fixture, so its balance IS total supply.
  function test_lpFee_preserves_supply_invariant() public {
    uint256 amt = 50_000e18;
    base.mint(USER, amt);
    vm.prank(USER);
    base.approve(address(pool), type(uint256).max);

    for (uint256 i; i < 5; ++i) {
      vm.prank(USER);
      pool.swap(address(base), address(quote), amt / 5, 0, USER, NO_DEADLINE);
      IPool.Asset memory a = pool.getAsset(address(quote));
      uint256 claim =
        pool.getLPBalance(address(this), address(quote)) * uint256(a.liquidityIndex) / 1e18;
      assertLe(claim, uint256(a.liabilities), "totalSupply*index/WAD <= liabilities");
    }
  }

  /// @notice End to end: an LP who sat through round-trip flow withdraws MORE than it put in. This
  ///         is the number `feeApr` publishes; pre-fix `previewWithdraw` was flat forever, because
  ///         the fee raised reserves only and withdraw pays face (`lp·index/WAD`).
  ///         A round trip is required: one directed swap leaves the output leg short on inventory,
  ///         so the coverage haircut masks the accrual. Restoring inventory isolates the fee.
  function test_lpFee_is_realised_on_withdraw() public {
    // setUp's quote deposit by address(this), net of the #73 dead-share seed carved out of it.
    uint256 seedLp = 1_000_000e18 - 0.001e18;
    uint256 lp = pool.getLPBalance(address(this), address(quote));
    (uint256 pre,) = pool.previewWithdraw(address(quote), lp);
    assertEq(pre, seedLp, "flat before any flow");

    uint256 amt = 10_000e18;
    base.mint(USER, amt);
    vm.startPrank(USER);
    base.approve(address(pool), type(uint256).max);
    quote.approve(address(pool), type(uint256).max);
    uint256 got = pool.swap(address(base), address(quote), amt, 0, USER, NO_DEADLINE);
    pool.swap(address(quote), address(base), got, 0, USER, NO_DEADLINE);
    vm.stopPrank();

    (uint256 post,) = pool.previewWithdraw(address(quote), lp);
    assertGt(post, seedLp, "LP claim must grow on swap fees");
  }

  /// @notice A leg whose liabilities went to dust must NOT brick. `newIndex = idx·(L+f)/L` blows the
  ///         index ceiling once `f` dwarfs `L`, and an accrual that reverts inside settlement is a
  ///         leg-wide DoS bought for gas. A cross-asset withdraw burns quote liabilities in full
  ///         while paying out of BASE reserves, which is exactly that shape: quote keeps ~1M
  ///         reserves against a liability floored at the #73 dead-share seed.
  function test_lpFee_skips_rather_than_bricks_a_dust_liability_leg() public {
    skip(60); // clear the JIT cooldown from setUp
    uint256 lp = pool.getLPBalance(address(this), address(quote));
    pool.withdrawTo(address(quote), address(base), lp, 0, NO_DEADLINE);
    IPool.Asset memory dust = pool.getAsset(address(quote));
    assertEq(uint256(dust.liabilities), 0.001e18, "quote liabilities drained to the dead floor");
    assertGt(uint256(dust.reserves), 0);

    uint256 amt = 100e18;
    base.mint(USER, amt);
    vm.startPrank(USER);
    base.approve(address(pool), type(uint256).max);
    uint256 out = pool.swap(address(base), address(quote), amt, 0, USER, NO_DEADLINE);
    vm.stopPrank();
    assertGt(out, 0, "swap out of a dust-liability leg must still settle");
    IPool.Asset memory post = pool.getAsset(address(quote));
    assertLe(
      pool.getLPBalance(address(0), address(quote)) * uint256(post.liquidityIndex) / WAD,
      uint256(post.liabilities),
      "no claim booked past the leg's liabilities"
    );
  }

  /// @notice R8 fuzz: conservation holds across a range of input sizes.
  function test_R8_conservation_fuzz(uint96 amtFuzz) public {
    uint256 amt = bound(uint256(amtFuzz), 1e15, 100_000e18);
    base.mint(USER, amt);
    vm.prank(USER);
    base.approve(address(pool), type(uint256).max);
    vm.prank(USER);
    try pool.swap(address(base), address(quote), amt, 0, USER, NO_DEADLINE) returns (uint256) {
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
      pool.swap(address(base), address(quote), amt, 0, USER, NO_DEADLINE);
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
    uint256 out = pool.swap(address(base), address(quote), amt, 0, USER, NO_DEADLINE);
    assertEq(quote.balanceOf(USER) - before, out, "user received exactly out");
  }
}
