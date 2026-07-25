// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {TestnetERC20} from "../../src/testnet/TestnetERC20.sol";
import {RecenterHook} from "../../src/incumbents/univ4/RecenterHook.sol";
import {RangeCLPool, RangeCLFactory} from "../../src/incumbents/univ4/RangeCLPool.sol";
import {SqrtPrice} from "../../src/incumbents/univ4/SqrtPrice.sol";
import {UniPoolOracle} from "../../src/oracles/UniPoolOracle.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {MockAC} from "../fixtures/BaseTestSetup.sol";
import {Oracle} from "../../src/libraries/Oracle.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @notice Forge tests for Uni piggyback: oracle reads sqrtPrice; hook recenters on >5% drift.
contract UniPiggybackTest is Test {
  uint24 constant FEE = 3000; // 0.3%
  uint256 constant RANGE_BPS = 1_000; // ±10%
  // 1:1 keeps virtual reserves modest so a single swap can clear the 5% drift threshold.
  uint256 constant PRICE = 1e18;

  MockAC ac;
  RecenterHook hook;
  RangeCLFactory factory;
  RangeCLPool pool;
  UniPoolOracle oracle;
  TestnetERC20 token0;
  TestnetERC20 token1;
  bytes32 feedId;

  function setUp() public {
    ac = new MockAC(address(this));
    hook = new RecenterHook();
    factory = new RangeCLFactory(address(hook));

    TestnetERC20 a = new TestnetERC20("TokenA", "A", 18);
    TestnetERC20 b = new TestnetERC20("TokenB", "B", 18);

    pool = RangeCLPool(factory.createPool(address(a), address(b), FEE));
    token0 = TestnetERC20(pool.token0());
    token1 = TestnetERC20(pool.token1());

    uint256 a0 = 1_000 ether;
    uint256 a1 = 1_000 ether;
    token0.mint(address(this), a0 * 20);
    token1.mint(address(this), a1 * 20);
    token0.approve(address(pool), type(uint256).max);
    token1.approve(address(pool), type(uint256).max);
    pool.seed(PRICE, RANGE_BPS, a0, a1);

    oracle = new UniPoolOracle(address(ac));
    feedId = oracle.addFeed(address(token0), address(token1), address(pool), 50_000, 5, 3600);
  }

  function test_oracle_readsSqrtPrice() public view {
    (uint160 sqrtP,,) = pool.slot0();
    assertApproxEqRel(SqrtPrice.decode(sqrtP), PRICE, 0.001e18, "slot0 price");

    IOracle.FeedData memory f = oracle.getFeed(feedId);
    assertApproxEqRel(Oracle.mark(f), PRICE, 0.001e18, "oracle mark == uni spot");
    assertEq(f.updatedAt, uint32(block.timestamp), "always fresh");
    assertTrue(oracle.isFeedFresh(feedId));
  }

  function test_oracle_invert_whenBaseIsToken1() public {
    bytes32 invId = oracle.addFeed(address(token1), address(token0), address(pool), 50_000, 5, 3600);
    IOracle.FeedData memory f = oracle.getFeed(invId);
    assertApproxEqRel(Oracle.mark(f), PRICE, 0.002e18, "inverted 1:1 still ~1");
  }

  function test_hook_recentersWhenDriftOver5pct() public {
    uint160 loBefore = pool.sqrtLowerX96();
    uint160 hiBefore = pool.sqrtUpperX96();
    uint256 midBefore = SqrtPrice.midPrice(loBefore, hiBefore);

    // ~50% of token1 inventory — single swap clears >5% drift (empirically 518 bps at 500e18).
    uint256 amountIn = 500 ether;
    token1.mint(address(this), amountIn);
    pool.swap(false, amountIn, 0, address(this));

    uint256 spot = SqrtPrice.decode(pool.sqrtPriceX96());
    uint160 loAfter = pool.sqrtLowerX96();
    uint160 hiAfter = pool.sqrtUpperX96();

    assertTrue(loAfter != loBefore || hiAfter != hiBefore, "bounds moved");
    // Spot must have been >5% from the OLD mid (otherwise hook would not fire).
    // After recenter, spot is near the NEW mid.
    uint256 newMid = SqrtPrice.midPrice(loAfter, hiAfter);
    assertApproxEqRel(newMid, spot, 0.05e18, "recentering mid ~ spot");
    assertLe(SqrtPrice.driftBps(spot, newMid), 500, "post-recenter drift <=5%");
    // Old mid is now stale relative to spot.
    assertGt(SqrtPrice.driftBps(spot, midBefore), 0, "spot moved from old mid");
  }

  function test_hook_noRecenterUnder5pct() public {
    uint160 loBefore = pool.sqrtLowerX96();
    uint160 hiBefore = pool.sqrtUpperX96();

    uint256 amountIn = 1 ether; // tiny
    token1.mint(address(this), amountIn);
    pool.swap(false, amountIn, 0, address(this));

    assertEq(pool.sqrtLowerX96(), loBefore, "lower unchanged");
    assertEq(pool.sqrtUpperX96(), hiBefore, "upper unchanged");
  }

  /// L-2: the flash-manipulable spot oracle is testnet-only — ctor reverts off chainid 97/31337.
  function test_oracle_ctorRejectsNonTestnetChains() public {
    vm.chainId(8453); // Base mainnet
    vm.expectRevert(Err.InvalidInput.selector);
    new UniPoolOracle(address(ac));
    vm.chainId(56); // BSC mainnet
    vm.expectRevert(Err.InvalidInput.selector);
    new UniPoolOracle(address(ac));
    vm.chainId(97); // BSC Chapel testnet — allowed
    UniPoolOracle ok = new UniPoolOracle(address(ac));
    assertEq(ok.AC(), address(ac), "chapel deploy allowed");
    vm.chainId(31337); // restore the forge default for any later assertions
  }

  function test_sqrtPrice_encodeDecodeRoundtrip() public pure {
    uint256[5] memory prices = [uint256(1e18), 574e18, 1795e18, 4090e18, 64_300e18];
    for (uint256 i; i < prices.length; i++) {
      uint160 sp = SqrtPrice.encode(prices[i]);
      assertApproxEqRel(SqrtPrice.decode(sp), prices[i], 0.0001e18);
    }
  }
}
