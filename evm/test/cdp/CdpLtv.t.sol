// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Constants as SC} from "@btr-shared/Constants.sol";
import {Constants as C} from "../../src/libraries/Constants.sol";
import {ICdp} from "../../src/interfaces/ICdp.sol";
import {CdpConstants} from "../../src/libraries/CdpConstants.sol";
import {DebtToken} from "../../src/DebtToken.sol";
import {CdpValuationHarness, MockCdpPool, MockLpToken} from "./mocks/CdpMocks.sol";
import {CdpTestBase} from "./CdpTestBase.sol";

contract CdpLtvTest is CdpTestBase {
  CdpValuationHarness h;
  address owner = address(0xA11CE);
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

  function test_defaults_not95Percent() public pure {
    assertEq(CdpConstants.STABLE_CORE_CANONICAL_LTV_BPS, 8500);
    assertLt(CdpConstants.STABLE_CORE_CANONICAL_LTV_BPS, 9500);
    assertEq(CdpConstants.STABLE_CORE_CANONICAL_LT_BPS, 9000);
    assertEq(CdpConstants.STABLE_CORE_CANONICAL_BONUS_BPS, 300);
  }

  function test_maxDebt_roundsDown() public view {
    assertEq(h.maxDebt(1000e18, 8500), 850e18);
    uint256 expected = (uint256(1001) * 8500) / 10_000;
    assertEq(h.maxDebt(1001, 8500), expected);
  }

  function test_healthFactor_atLtvBoundary() public view {
    uint256 hf = h.healthFactorWad(1000e18, 850e18, 9000);
    assertGt(hf, SC.WAD);
    assertEq(h.healthFactorWad(1000e18, 900e18, 9000), SC.WAD);
    assertLt(h.healthFactorWad(1000e18, 901e18, 9000), SC.WAD);
  }

  function test_healthFactor_zeroDebtMax() public view {
    assertEq(h.healthFactorWad(1000e18, 0, 9000), type(uint256).max);
  }

  function test_registry_rejectsLtv95() public {
    MockLpToken lp2 = new MockLpToken();
    vm.prank(owner);
    vm.expectRevert(ICdp.BadParams.selector);
    e.registry.listWithParams(
      address(lp2), address(pool), asset, address(btrUSD), ICdp.Denom.USD, false, 0, 9500, 9700, 200
    );
  }

  function test_open_revertsAboveLtv() public {
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(ICdp.LtvExceeded.selector, 851e18, 850e18));
    e.engine.open(address(lp), 1000e18, 851e18);
  }

  function test_open_atExactLtv() public {
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    e.engine.open(address(lp), 1000e18, 850e18);
    (uint256 V, uint256 debt, uint256 maxM) = e.engine.positionValue(address(this), address(lp));
    assertEq(V, 1000e18);
    assertEq(debt, 850e18);
    assertEq(maxM, 850e18);
  }

  function test_ltvFence_holdsWithHaircutsAndBasis() public {
    vm.prank(owner);
    e.engine.setHaircuts(CdpConstants.DEFAULT_HL_BPS, CdpConstants.DEFAULT_HO_BPS);
    vm.prank(owner);
    e.engine.setBasisWad(address(lp), 0.99e18);
    uint256 V = (uint256(1000e18) * 99 / 100) * 97 / 100;
    uint256 maxD = (V * 8500) / 10_000;
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(ICdp.LtvExceeded.selector, maxD + 1, maxD));
    e.engine.open(address(lp), 1000e18, maxD + 1);
    e.engine.open(address(lp), 1000e18, maxD);
    (uint256 v2, uint256 debt, uint256 maxM) = e.engine.positionValue(address(this), address(lp));
    assertEq(v2, V);
    assertEq(debt, maxD);
    assertEq(maxM, maxD);
  }

  function test_previewValuation_respectsRate() public view {
    ICdp.ValueParams memory p;
    assertEq(h.applyFactors(500e18, p), 500e18);
    assertEq(h.maxDebt(500e18, 8500), 425e18);
  }

  function test_basisClamp_neverAboveOne() public view {
    assertEq(h.clampBasis(0), SC.WAD);
    assertEq(h.clampBasis(0.5e18), 0.5e18);
    assertEq(h.clampBasis(1.2e18), SC.WAD);
  }

  function test_applyFactors_basisAndHaircuts() public view {
    ICdp.ValueParams memory p;
    p.basisWad = 0.9e18;
    p.hlBps = 200;
    p.hoBps = 100;
    assertEq(h.applyFactors(1000e18, p), 873e18);
  }

  function test_applyFactors_haircutSumGeBpsReverts() public {
    ICdp.ValueParams memory p;
    p.hlBps = 6000;
    p.hoBps = 4000;
    vm.expectRevert(ICdp.IncompleteValuation.selector);
    h.applyFactors(1000e18, p);
  }

  function test_wipe_indexZero_valueZero() public {
    pool.setLiquidityIndex(0);
    ICdp.ValueParams memory p;
    assertTrue(h.isWiped(address(pool), asset));
    assertEq(h.collateralValue(address(pool), asset, 1000e18, p), 0);
    assertEq(h.effectiveLtv(address(pool), asset, 8500, false, address(this), 1000e18), 0);
  }

  function test_open_revertsWhenWiped() public {
    pool.setLiquidityIndex(0);
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(ICdp.CollateralWiped.selector, address(lp)));
    e.engine.open(address(lp), 1000e18, 1);
  }

  function test_paused_refusesMint_ltvZero() public {
    pool.setRiskFlags(C.ASSET_PAUSED_BIT);
    assertTrue(h.isHalted(address(pool), asset));
    assertEq(h.effectiveLtv(address(pool), asset, 8500, false, address(this), 1000e18), 0);
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(ICdp.CollateralHalted.selector, address(lp)));
    e.engine.open(address(lp), 1000e18, 1);
  }

  function test_frozen_refusesMint() public {
    pool.setRiskFlags(C.FROZEN_BIT);
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(ICdp.CollateralHalted.selector, address(lp)));
    e.engine.open(address(lp), 1000e18, 1);
  }

  function test_halted_allowsRepayAndClose() public {
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    e.engine.open(address(lp), 1000e18, 500e18);
    pool.setRiskFlags(C.ASSET_PAUSED_BIT);
    vm.expectRevert(abi.encodeWithSelector(ICdp.CollateralHalted.selector, address(lp)));
    e.engine.adjust(address(lp), 0, int256(1));
    e.engine.repay(address(lp), 200e18);
    e.engine.close(address(lp));
    assertEq(lp.balanceOf(address(this)), 1000e18);
  }

  function test_setHaircuts_rejectsIncomplete() public {
    vm.prank(owner);
    vm.expectRevert(ICdp.IncompleteValuation.selector);
    e.engine.setHaircuts(5000, 5000);
  }

  function test_decimals_6leg_scaleAndLtv() public {
    pool.setDecimals(6);
    pool.setRateWad(1e6);
    pool.setFreshRateWad(0);
    ICdp.ValueParams memory p = ICdp.ValueParams({hlBps: 0, hoBps: 0, basisWad: SC.WAD});
    assertEq(h.toDebtDecimals(1e6, 6), 1e18);
    assertEq(h.collateralValue(address(pool), asset, 1000e18, p), 1000e18);
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    e.engine.open(address(lp), 1000e18, 850e18);
  }

  function test_halt_blocksMint_notZeroLiqValue() public {
    ICdp.ValueParams memory p = ICdp.ValueParams({hlBps: 0, hoBps: 0, basisWad: SC.WAD});
    assertEq(h.collateralValue(address(pool), asset, 1000e18, p), 1000e18);
    pool.setRiskFlags(C.HALT_MASK);
    assertEq(h.collateralValue(address(pool), asset, 1000e18, p), 1000e18);
    assertEq(h.effectiveLtv(address(pool), asset, 8500, false, address(this), 1000e18), 0);
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(ICdp.CollateralHalted.selector, address(lp)));
    e.engine.open(address(lp), 1000e18, 100e18);
  }

  function test_halt_allowsLiquidation() public {
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    e.engine.open(address(lp), 1000e18, 850e18);
    pool.setFreshRateWad(0.5e18);
    pool.setRiskFlags(C.HALT_MASK);
    address liq = address(0x222);
    btrUSD.transfer(liq, 425e18);
    vm.startPrank(liq);
    btrUSD.approve(address(e.engine), type(uint256).max);
    e.engine.liquidate(address(this), address(lp), 425e18);
    vm.stopPrank();
    (uint128 coll, uint128 debt) = e.engine.positions(address(this), address(lp));
    assertLt(debt, 850e18);
    assertLt(coll, 1000e18);
  }

  function test_capacityShort_blocksMint() public {
    pool.setMaxRedeem(500e18);
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(ICdp.CapacityShortfall.selector, address(lp)));
    e.engine.open(address(lp), 1000e18, 100e18);
  }
}
