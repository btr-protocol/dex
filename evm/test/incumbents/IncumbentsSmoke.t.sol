// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {TestnetERC20} from "../../src/testnet/TestnetERC20.sol";
import {StableSwapPool} from "../../src/incumbents/curve/StableSwapPool.sol";
import {LiteCLFactory, LiteCLPool} from "../../src/incumbents/univ4/LiteCLPool.sol";
import {WombatLite} from "../../src/incumbents/wombat/WombatLite.sol";
import {FluidDexFactory, FluidDexPool} from "../../src/incumbents/fluid/FluidDexPool.sol";
import {FluidDexMath} from "../../src/incumbents/fluid/FluidDexMath.sol";

/// @notice Smoke tests for Chapel incumbent forks (Curve / CL / Wombat / Fluid Dex math).
contract IncumbentsSmokeTest is Test {
  TestnetERC20 usdc;
  TestnetERC20 usdt;
  TestnetERC20 usd1;
  TestnetERC20 usde;
  TestnetERC20 fdusd;

  function setUp() public {
    usdc = new TestnetERC20("USDC", "USDC", 18);
    usdt = new TestnetERC20("USDT", "USDT", 18);
    usd1 = new TestnetERC20("USD1", "USD1", 18);
    usde = new TestnetERC20("USDE", "USDE", 18);
    fdusd = new TestnetERC20("FDUSD", "FDUSD", 18);
    usdc.mint(address(this), 10_000_000 ether);
    usdt.mint(address(this), 10_000_000 ether);
    usd1.mint(address(this), 10_000_000 ether);
    usde.mint(address(this), 10_000_000 ether);
    fdusd.mint(address(this), 10_000_000 ether);
  }

  function test_curve3pool_swap() public {
    address[] memory coins = new address[](3);
    coins[0] = address(usdt);
    coins[1] = address(usdc);
    coins[2] = address(usd1);
    StableSwapPool p = new StableSwapPool(coins, 1000, 1e6);
    uint256[] memory amts = new uint256[](3);
    amts[0] = 100_000 ether;
    amts[1] = 100_000 ether;
    amts[2] = 100_000 ether;
    usdt.approve(address(p), type(uint256).max);
    usdc.approve(address(p), type(uint256).max);
    usd1.approve(address(p), type(uint256).max);
    p.add_liquidity(amts, 0);

    uint256 out = p.exchange(0, 1, 1_000 ether, 0);
    assertGt(out, 990 ether);
    assertLt(out, 1_010 ether);
  }

  function test_liteCL_two_fees() public {
    LiteCLFactory f = new LiteCLFactory();
    address p5 = f.createPool(address(usdc), address(usdt), 5, 1);
    address p100 = f.createPool(address(usdc), address(usdt), 100, 1);
    usdc.approve(p5, type(uint256).max);
    usdt.approve(p5, type(uint256).max);
    usdc.approve(p100, type(uint256).max);
    usdt.approve(p100, type(uint256).max);
    LiteCLPool(p5).mint(50_000 ether, 50_000 ether, address(this));
    LiteCLPool(p100).mint(50_000 ether, 50_000 ether, address(this));

    bool zfo = address(usdc) < address(usdt);
    uint256 out5 = LiteCLPool(p5).swap(zfo, 1_000 ether, 0, address(this));
    uint256 out100 = LiteCLPool(p100).swap(zfo, 1_000 ether, 0, address(this));
    assertGt(out5, out100); // lower fee → more out
  }

  function test_wombat_four_asset() public {
    address[] memory toks = new address[](4);
    toks[0] = address(usdc);
    toks[1] = address(usdt);
    toks[2] = address(usd1);
    toks[3] = address(usde);
    WombatLite w = new WombatLite(toks, 1e14, 2);
    for (uint256 i; i < 4; i++) {
      TestnetERC20(toks[i]).approve(address(w), type(uint256).max);
      w.deposit(toks[i], 50_000 ether, 0);
    }
    uint256 out = w.swap(address(usdc), address(usdt), 1_000 ether, 0, address(this));
    assertGt(out, 980 ether);
  }

  function test_fluid_dex_exact_math() public {
    FluidDexFactory f = new FluidDexFactory();
    // fee=100 (1bp), range ±0.5%, center=1e27 — Fluid DexLite/DexT1 units
    address pool =
      f.createPool(address(usdc), address(usdt), 100, 50, 50, FluidDexMath.PRICE_PRECISION);
    usdc.approve(pool, type(uint256).max);
    usdt.approve(pool, type(uint256).max);
    FluidDexPool(pool).initialize(50_000 ether, 50_000 ether);

    (uint256 i0, uint256 i1) = FluidDexPool(pool).getImaginaryReserves();
    assertGt(i0, 50_000 ether, "imaginary > real (outside range)");
    assertGt(i1, 50_000 ether);

    bool zfo = address(usdc) < address(usdt);
    uint256 out = FluidDexPool(pool).swap(zfo, 1_000 ether, 0, address(this));
    // Tight range + 1bp fee → near 1:1
    assertGt(out, 990 ether);
    assertLt(out, 1_000 ether);
  }

  function test_fluid_math_matches_library_formula() public {
    uint256 center = 1e27;
    uint256 rx = 100_000e18;
    uint256 ry = 100_000e18;
    (uint256 i0, uint256 i1) = FluidDexMath.imaginaryReserves(center, 50, 50, rx, ry);
    uint256 out = FluidDexMath.getAmountOut(1_000e18, i0, i1, 100);
    // Same formula as Fluid DexLite coreInternals _swapIn
    uint256 feeAmt = (1_000e18 * 100) / 1e6;
    uint256 expected = ((1_000e18 - feeAmt) * i1) / (i0 + (1_000e18 - feeAmt));
    assertEq(out, expected);
  }
}
