// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Constants as SC} from "@btr-shared/Constants.sol";
import {Constants as C} from "../../src/libraries/Constants.sol";
import {ICdp} from "../../src/interfaces/ICdp.sol";
import {CdpConstants} from "../../src/libraries/CdpConstants.sol";
import {DebtToken} from "../../src/DebtToken.sol";
import {CdpValuationHarness, MockCdpPool, MockLpToken} from "./mocks/CdpMocks.sol";
import {CdpTestBase} from "./CdpTestBase.sol";

contract CdpLiquidationTest is CdpTestBase {
  CdpValuationHarness h;
  address owner = address(0xA11CE);
  address alice = address(0xB0B);
  address liq = address(0x3333);
  address backstop = address(0xBACE);
  CdpEnv e;
  DebtToken btrUSD;
  MockCdpPool pool;
  MockLpToken lp;
  address asset = address(0x1111);

  function setUp() public {
    h = new CdpValuationHarness();
    e = _deployCdp(owner);
    e.ac.setTreasury(backstop);
    btrUSD = e.btrUSD;
    pool = new MockCdpPool();
    lp = new MockLpToken();
    _listUsd(e.registry, owner, address(lp), address(pool), asset, address(btrUSD), 1e27);
  }

  function test_closeFactor_partialVsFull() public view {
    assertEq(h.closeFactorBps(SC.WAD), 0);
    assertEq(h.closeFactorBps(0.96e18), CdpConstants.CLOSE_FACTOR_PARTIAL_BPS);
    assertEq(h.closeFactorBps(0.95e18), CdpConstants.CLOSE_FACTOR_PARTIAL_BPS);
    assertEq(h.closeFactorBps(0.949e18), uint16(SC.BPS));
  }

  function test_closeFactor_dustForcesFull() public view {
    uint256 debt = CdpConstants.DUST_DEBT + (CdpConstants.DUST_DEBT / 2);
    assertEq(h.closeFactorBpsWithDust(0.96e18, debt), uint16(SC.BPS));
    assertEq(h.closeFactorBpsWithDust(0.96e18, 1000e18), CdpConstants.CLOSE_FACTOR_PARTIAL_BPS);
  }

  function test_splitSeize_80_20() public view {
    (uint256 toLiq, uint256 toBs) = h.splitSeizeValue(100e18, 300);
    assertEq(toLiq + toBs, 103e18);
    assertEq(toBs, (3e18 * 2000) / 10_000);
    assertEq(toLiq, 103e18 - toBs);
  }

  function test_lpForValue_underHaircuts() public {
    vm.prank(owner);
    e.engine.setHaircuts(200, 100);
    ICdp.ValueParams memory p = e.engine.valueParams(address(lp));
    uint256 shares = h.lpForValue(address(pool), asset, 485e18, 1000e18, p);
    assertGe(h.collateralValue(address(pool), asset, shares, p), 485e18);
    if (shares > 0) {
      assertLt(h.collateralValue(address(pool), asset, shares - 1, p), 485e18);
    }
  }

  function test_liquidate_revertsIfHealthy() public {
    _open(alice, 1000e18, 850e18);
    _fundLiq(100e18);
    vm.prank(liq);
    vm.expectRevert();
    e.engine.liquidate(alice, address(lp), 100e18);
  }

  function test_liquidate_partialCloseFactor_band() public {
    _open(alice, 1000e18, 850e18);
    uint256 cover = (850e18 * 5000) / 10_000;
    _fundLiq(cover);
    pool.setRateWad(0.9e18);
    uint256 hf = e.engine.healthFactor(alice, address(lp));
    assertLt(hf, SC.WAD);
    assertGe(hf, CdpConstants.HF_FULL_LIQ_THRESHOLD_WAD);
    vm.prank(liq);
    e.engine.liquidate(alice, address(lp), type(uint256).max);
    (uint128 coll, uint128 debt) = _pos(alice);
    assertEq(debt, 850e18 - cover);
    assertLt(coll, 1000e18);
    assertGt(coll, 0);
    assertGt(lp.balanceOf(liq), 0);
    assertGt(lp.balanceOf(backstop), 0);
  }

  function test_liquidate_fullBelow095() public {
    _open(alice, 1000e18, 850e18);
    _fundLiq(850e18);
    pool.setRateWad(0.8e18);
    assertLt(e.engine.healthFactor(alice, address(lp)), CdpConstants.HF_FULL_LIQ_THRESHOLD_WAD);
    vm.prank(liq);
    e.engine.liquidate(alice, address(lp), type(uint256).max);
    (uint128 coll, uint128 debt) = _pos(alice);
    assertEq(debt, 0);
    assertEq(coll, 0);
    assertEq(lp.balanceOf(liq) + lp.balanceOf(backstop), 1000e18);
  }

  function test_liquidate_bonusSplit_underHaircuts() public {
    vm.prank(owner);
    e.engine.setHaircuts(200, 100);
    uint256 V = (1000e18 * 97) / 100;
    uint256 debtAmt = (V * 8500) / 10_000;
    _open(alice, 1000e18, debtAmt);
    uint256 cover = (debtAmt * 5000) / 10_000;
    _fundLiq(cover);
    (uint256 liqVal, uint256 bsVal) = h.splitSeizeValue(cover, 300);
    pool.setRateWad(0.92e18);
    uint256 hf = e.engine.healthFactor(alice, address(lp));
    assertLt(hf, SC.WAD);
    assertGe(hf, CdpConstants.HF_FULL_LIQ_THRESHOLD_WAD);
    uint256 liqLpBefore = lp.balanceOf(liq);
    uint256 bsBefore = lp.balanceOf(backstop);
    vm.prank(liq);
    e.engine.liquidate(alice, address(lp), cover);
    ICdp.ValueParams memory p = e.engine.valueParams(address(lp));
    uint256 liqGot = lp.balanceOf(liq) - liqLpBefore;
    uint256 bsGot = lp.balanceOf(backstop) - bsBefore;
    assertGe(h.collateralValue(address(pool), asset, liqGot, p), liqVal);
    if (bsVal > 0) {
      assertGt(bsGot, 0);
      assertGe(h.collateralValue(address(pool), asset, bsGot, p), bsVal);
    }
  }

  function test_liquidate_wipe_realizesBadDebt() public {
    _open(alice, 1000e18, 500e18);
    _fundLiq(500e18);
    pool.setLiquidityIndex(0);
    assertEq(e.engine.healthFactor(alice, address(lp)), 0);
    vm.prank(liq);
    e.engine.liquidate(alice, address(lp), 500e18);
    assertEq(e.engine.badDebt(address(btrUSD)), 0);
    (uint128 coll, uint128 debt) = _pos(alice);
    assertEq(coll, 0);
    assertEq(debt, 0);
    assertEq(lp.balanceOf(liq), 1000e18);
  }

  function test_liquidate_wipe_partialCover_reverts() public {
    _open(alice, 1000e18, 500e18);
    _fundLiq(200e18);
    pool.setLiquidityIndex(0);
    vm.prank(liq);
    vm.expectRevert(abi.encodeWithSelector(ICdp.ExhaustRequiresFullCover.selector, 1, 500e18));
    e.engine.liquidate(alice, address(lp), 1);
  }

  function test_liquidate_whileHalted_allowed() public {
    _open(alice, 1000e18, 850e18);
    uint256 cover = (850e18 * 5000) / 10_000;
    _fundLiq(cover);
    pool.setRateWad(0.9e18);
    pool.setRiskFlags(C.ASSET_PAUSED_BIT);
    lp.mint(alice, 100e18);
    vm.startPrank(alice);
    lp.approve(address(e.engine), type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(ICdp.CollateralHalted.selector, address(lp)));
    e.engine.adjust(address(lp), 0, int256(1));
    vm.stopPrank();
    vm.prank(liq);
    e.engine.liquidate(alice, address(lp), cover);
    (, uint128 debt) = _pos(alice);
    assertEq(debt, 850e18 - cover);
  }

  function test_liquidate_partialCover_exhaustColl_requiresFullCover() public {
    _open(alice, 100e18, 85e18);
    _fundLiq(10e18);
    pool.setRateWad(0.05e18);
    vm.prank(liq);
    vm.expectRevert(abi.encodeWithSelector(ICdp.ExhaustRequiresFullCover.selector, 10e18, 85e18));
    e.engine.liquidate(alice, address(lp), 10e18);
  }

  function test_liquidate_exhaustColl_fullCover_clears() public {
    _open(alice, 100e18, 85e18);
    _fundLiq(85e18);
    pool.setRateWad(0.05e18);
    vm.prank(liq);
    e.engine.liquidate(alice, address(lp), 85e18);
    assertEq(e.engine.badDebt(address(btrUSD)), 0);
    (uint128 coll, uint128 debt) = _pos(alice);
    assertEq(coll, 0);
    assertEq(debt, 0);
  }

  function _open(address who, uint256 collAmt, uint256 debtAmt) internal {
    lp.mint(who, collAmt);
    vm.startPrank(who);
    lp.approve(address(e.engine), type(uint256).max);
    e.engine.open(address(lp), collAmt, debtAmt);
    vm.stopPrank();
  }

  function _fundLiq(uint256 amount) internal {
    uint256 collNeed = amount * 2 + 1e18;
    lp.mint(liq, collNeed);
    vm.startPrank(liq);
    lp.approve(address(e.engine), type(uint256).max);
    e.engine.open(address(lp), collNeed, amount);
    vm.stopPrank();
  }

  function _pos(address who) internal view returns (uint128 coll, uint128 debt) {
    (coll, debt) = e.engine.positions(who, address(lp));
  }
}
