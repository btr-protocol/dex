// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Constants as C} from "../../src/libraries/Constants.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {ICdp} from "../../src/interfaces/ICdp.sol";
import {CdpConstants} from "../../src/libraries/CdpConstants.sol";
import {CdpValuation} from "../../src/libraries/CdpValuation.sol";
import {DebtToken} from "../../src/DebtToken.sol";
import {CdpValuationHarness, MockCdpPool, MockLpToken} from "./mocks/CdpMocks.sol";
import {ControllableOracle, PoolViewCdpFixture} from "./mocks/PoolViewCdpFixture.sol";
import {CdpTestBase} from "./CdpTestBase.sol";

contract CdpOpenFindingsTest is CdpTestBase {
  address owner = address(0xA11CE);
  address backstop = address(0xBACE);
  CdpEnv e;
  DebtToken btrUSD;
  MockCdpPool pool;
  MockLpToken lp;
  ControllableOracle oracle;
  CdpValuationHarness h;
  address asset = address(0x1111);

  function setUp() public {
    vm.warp(1_700_000_000);
    h = new CdpValuationHarness();
    e = _deployCdp(owner);
    e.ac.setTreasury(backstop);
    btrUSD = e.btrUSD;
    pool = new MockCdpPool();
    lp = new MockLpToken();
    oracle = new ControllableOracle();
    _listUsd(e.registry, owner, address(lp), address(pool), asset, address(btrUSD), 1e27);
  }

  function test_INT10_staleMark_blocksMint_allowsLiq() public {
    bytes32 fid = oracle.feedIdFor(asset);
    oracle.setFeedFull(
      fid, M.encodeB64(1e18, 18), uint32(SC.ONE_PCT_PBPS), 0, 60, 0, uint32(block.timestamp), 0
    );
    pool.setOracleConfig(address(oracle), fid, 0);
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    e.engine.open(address(lp), 1000e18, 850e18);
    vm.warp(block.timestamp + 61);
    vm.expectRevert(abi.encodeWithSelector(Err.StaleData.selector, uint32(61), uint32(60)));
    e.engine.adjust(address(lp), 0, int256(1));
    pool.setFreshRateWad(0.5e18);
    address liq = address(0x333);
    btrUSD.transfer(liq, 425e18);
    vm.startPrank(liq);
    btrUSD.approve(address(e.engine), type(uint256).max);
    e.engine.liquidate(address(this), address(lp), 425e18);
    vm.stopPrank();
    (, uint128 debt) = e.engine.positions(address(this), address(lp));
    assertLt(debt, 850e18);
  }

  function test_INT10_pausedMark_blocksLiq() public {
    bytes32 fid = oracle.feedIdFor(asset);
    oracle.setMark(asset, M.encodeB64(1e18, 18));
    pool.setOracleConfig(address(oracle), fid, 0);
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    e.engine.open(address(lp), 1000e18, 850e18);
    pool.setFreshRateWad(0.5e18);
    oracle.pause(fid);
    address liq = address(0x334);
    btrUSD.transfer(liq, 425e18);
    vm.startPrank(liq);
    btrUSD.approve(address(e.engine), type(uint256).max);
    vm.expectRevert(Err.FeedPaused.selector);
    e.engine.liquidate(address(this), address(lp), 425e18);
    vm.stopPrank();
  }

  function test_INT11_decayTerminal_mintRevertsWiped() public {
    PoolViewCdpFixture fx = new PoolViewCdpFixture(asset);
    fx.seedLeg(
      0,
      1000e18,
      uint96(C.LIQUIDITY_INDEX_INIT),
      18,
      10_000,
      type(uint32).max,
      C.DECAY_ENABLED_BIT,
      uint32(block.timestamp),
      C.HAIRCUT_SUPPRESSOR_DISABLE
    );
    vm.warp(block.timestamp + 300_000_000);
    assertGt(fx.liquidityIndex(asset), 0, "stored index still live");
    assertEq(fx.pendingDecayAmt(), 1000e18, "full deficit decay");
    (uint256 fresh,) = fx.previewWithdrawFresh(asset, SC.WAD);
    assertEq(fresh, 0, "virtual wipe");
    assertTrue(CdpValuation.isWiped(address(fx), asset));
    MockLpToken lp2 = new MockLpToken();
    _listUsd(e.registry, owner, address(lp2), address(fx), asset, address(btrUSD), 1e27);
    lp2.mint(address(this), 100e18);
    lp2.approve(address(e.engine), type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(ICdp.CollateralWiped.selector, address(lp2)));
    e.engine.open(address(lp2), 100e18, 1);
  }

  function test_C14_03_tierFormula_rejectsOverBound() public {
    uint16 maxOk = CdpValuation.maxLtvForBonus(300);
    assertEq(maxOk, 9029);
    assertGe(maxOk, CdpConstants.STABLE_CORE_CANONICAL_LTV_BPS);
    MockLpToken lpX = new MockLpToken();
    vm.prank(owner);
    vm.expectRevert(ICdp.BadParams.selector);
    e.registry.listWithParams(
      address(lpX), address(pool), asset, address(btrUSD), ICdp.Denom.USD, false, 0, 9030, 9500, 300
    );
    assertEq(CdpValuation.maxLtvForBonus(2000), 7750);
    vm.prank(owner);
    vm.expectRevert(ICdp.BadParams.selector);
    e.registry.listWithParams(
      address(lpX), address(pool), asset, address(btrUSD), ICdp.Denom.USD, false, 0, 8500, 9000, 2000
    );
  }

  function test_C14_04_capacityShort_allowsRepayAndAddColl() public {
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    e.engine.open(address(lp), 1000e18, 500e18);
    pool.setMaxRedeem(0);
    vm.expectRevert(abi.encodeWithSelector(ICdp.CapacityShortfall.selector, address(lp)));
    e.engine.adjust(address(lp), 0, int256(1));
    e.engine.adjust(address(lp), 0, -int256(100e18));
    (, uint128 debt) = e.engine.positions(address(this), address(lp));
    assertEq(debt, 400e18);
    lp.mint(address(this), 100e18);
    e.engine.adjust(address(lp), int256(100e18), 0);
    (uint128 coll,) = e.engine.positions(address(this), address(lp));
    assertEq(coll, 1100e18);
    assertEq(h.effectiveLtv(address(pool), asset, 8500, false, address(e.engine), 1100e18), 0);
    assertEq(
      h.effectiveLtvNoCapacity(address(pool), asset, 8500, false, address(e.engine), 1100e18), 8500
    );
  }
}
