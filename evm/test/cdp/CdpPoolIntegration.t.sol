// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Constants as C} from "../../src/libraries/Constants.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {ICdp} from "../../src/interfaces/ICdp.sol";
import {CdpValuation} from "../../src/libraries/CdpValuation.sol";
import {DebtToken} from "../../src/DebtToken.sol";
import {MockLpToken} from "./mocks/CdpMocks.sol";
import {ControllableOracle, PoolViewCdpFixture} from "./mocks/PoolViewCdpFixture.sol";
import {CdpTestBase} from "./CdpTestBase.sol";

contract CdpPoolIntegrationTest is CdpTestBase {
  address owner = address(0xA11CE);
  CdpEnv e;
  DebtToken btrUSD;
  MockLpToken lp;
  address asset = address(0x1111);
  PoolViewCdpFixture pool;
  ControllableOracle oracle;
  uint256 constant LP_AMT = 1000e18;

  function setUp() public {
    vm.warp(1_700_000_000);
    e = _deployCdp(owner);
    btrUSD = e.btrUSD;
    lp = new MockLpToken();
    pool = new PoolViewCdpFixture(asset);
    oracle = new ControllableOracle();
    pool.seedLeg(
      1000e18,
      1000e18,
      uint96(C.LIQUIDITY_INDEX_INIT),
      18,
      5000,
      0,
      0,
      uint32(block.timestamp),
      C.HAIRCUT_SUPPRESSOR_DISABLE
    );
    _listUsd(e.registry, owner, address(lp), address(pool), asset, address(btrUSD), 1e27);
  }

  function _mintLp(uint256 amt) internal {
    lp.mint(address(this), amt);
    lp.approve(address(e.engine), type(uint256).max);
  }

  function test_previewWithdrawFresh_dropsWhenDecayPending() public {
    pool.seedLeg(
      400e18,
      1000e18,
      uint96(C.LIQUIDITY_INDEX_INIT),
      18,
      5000,
      uint32(1e6),
      C.DECAY_ENABLED_BIT,
      uint32(block.timestamp),
      C.HAIRCUT_SUPPRESSOR_DISABLE
    );
    vm.warp(block.timestamp + 3600);
    uint128 pending = pool.pendingDecayAmt();
    assertGt(pending, 0, "pending decay must fire");
    (uint256 stale,) = pool.previewWithdraw(asset, LP_AMT);
    (uint256 fresh,) = pool.previewWithdrawFresh(asset, LP_AMT);
    assertLt(fresh, stale, "fresh < stored-index preview");
    assertGt(fresh, 0);
  }

  function test_mint_refusesStaleDebtWhenDecayPending() public {
    pool.seedLeg(
      400e18,
      1000e18,
      uint96(C.LIQUIDITY_INDEX_INIT),
      18,
      5000,
      uint32(1e6),
      C.DECAY_ENABLED_BIT,
      uint32(block.timestamp),
      C.HAIRCUT_SUPPRESSOR_DISABLE
    );
    vm.warp(block.timestamp + 3600);
    assertGt(pool.pendingDecayAmt(), 0);
    ICdp.ValueParams memory vp = ICdp.ValueParams({hlBps: 0, hoBps: 0, basisWad: SC.WAD});
    uint256 Vfresh = CdpValuation.collateralValue(address(pool), asset, LP_AMT, vp);
    uint256 maxFresh = CdpValuation.maxDebt(Vfresh, 8500);
    assertGt(maxFresh, 0);
    (uint256 Rstale,) = pool.previewWithdraw(asset, LP_AMT);
    uint256 maxStale = (Rstale * 8500) / SC.BPS;
    assertGt(maxStale, maxFresh, "stale max must exceed fresh");
    _mintLp(LP_AMT);
    vm.expectRevert(abi.encodeWithSelector(ICdp.LtvExceeded.selector, maxStale, maxFresh));
    e.engine.open(address(lp), LP_AMT, maxStale);
    e.engine.open(address(lp), LP_AMT, maxFresh);
    (, uint128 debt) = e.engine.positions(address(this), address(lp));
    assertEq(debt, maxFresh);
  }

  function test_externalMark_fresh_allowsMint() public {
    bytes32 fid = oracle.feedIdFor(asset);
    oracle.setMark(asset, M.encodeB64(1e18, 18));
    pool.setOracle(address(oracle), fid, 0);
    _mintLp(LP_AMT);
    e.engine.open(address(lp), LP_AMT, 850e18);
    (, uint128 debt) = e.engine.positions(address(this), address(lp));
    assertEq(debt, 850e18);
  }

  function test_externalMark_stale_blocksMint() public {
    bytes32 fid = oracle.feedIdFor(asset);
    oracle.setFeedFull(
      fid, M.encodeB64(1e18, 18), uint32(SC.ONE_PCT_PBPS), 0, 60, 0, uint32(block.timestamp), 0
    );
    pool.setOracle(address(oracle), fid, 0);
    vm.warp(block.timestamp + 61);
    _mintLp(LP_AMT);
    vm.expectRevert(abi.encodeWithSelector(Err.StaleData.selector, uint32(61), uint32(60)));
    e.engine.open(address(lp), LP_AMT, 100e18);
  }

  function test_externalMark_paused_blocksMint() public {
    bytes32 fid = oracle.feedIdFor(asset);
    oracle.setMark(asset, M.encodeB64(1e18, 18));
    oracle.pause(fid);
    pool.setOracle(address(oracle), fid, 0);
    _mintLp(LP_AMT);
    vm.expectRevert(Err.FeedPaused.selector);
    e.engine.open(address(lp), LP_AMT, 100e18);
  }

  function test_internalMark_isWad_withoutOracle() public view {
    (address primary,, uint8 mode) = pool.markFeed(asset);
    assertEq(mode, C.ORACLE_MODE_INTERNAL);
    assertEq(primary, address(0));
    uint256 b = CdpValuation.resolveBasis(address(pool), asset, 0, false);
    assertEq(b, SC.WAD);
  }

  function test_liveHook_afterList_blocksMint_registryStillHookless() public {
    ICdp.CollateralConfig memory cfg = e.registry.get(address(lp));
    assertFalse(cfg.hooked, "registry snapshot hookless");
    pool.setHook(address(0xBEEF), 1);
    assertTrue(CdpValuation.isLiveHooked(address(pool), asset));
    _mintLp(LP_AMT);
    vm.expectRevert(abi.encodeWithSelector(ICdp.HookedCollateralForbidden.selector, address(lp)));
    e.engine.open(address(lp), LP_AMT, 100e18);
  }

  function test_liveHook_afterOpen_blocksFurtherMint_liqOk() public {
    _mintLp(LP_AMT);
    e.engine.open(address(lp), LP_AMT, 850e18);
    pool.setHook(address(0xBEEF), 1);
    lp.mint(address(this), 100e18);
    lp.approve(address(e.engine), type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(ICdp.HookedCollateralForbidden.selector, address(lp)));
    e.engine.adjust(address(lp), int256(100e18), int256(1));
    pool.seedLeg(
      500e18,
      1000e18,
      uint96(0.5e18),
      18,
      5000,
      0,
      0,
      uint32(block.timestamp),
      C.HAIRCUT_SUPPRESSOR_DISABLE
    );
    address liq = address(0x333);
    btrUSD.transfer(liq, 425e18);
    vm.startPrank(liq);
    btrUSD.approve(address(e.engine), type(uint256).max);
    e.engine.liquidate(address(this), address(lp), 425e18);
    vm.stopPrank();
    (, uint128 debt) = e.engine.positions(address(this), address(lp));
    assertLt(debt, 850e18);
  }

  function test_externalMark_sameBlockSigned_blocksMint() public {
    bytes32 fid = oracle.feedIdFor(asset);
    oracle.setSameBlockSigned(fid, M.encodeB64(1e18, 18));
    pool.setOracle(address(oracle), fid, 0);
    _mintLp(LP_AMT);
    vm.expectRevert(abi.encodeWithSelector(Err.CooldownActive.selector, uint32(1)));
    e.engine.open(address(lp), LP_AMT, 100e18);
    vm.warp(block.timestamp + 1);
    uint32 prior = uint32(block.timestamp - 1);
    oracle.setFeedFull(
      fid,
      M.encodeB64(1e18, 18),
      uint32(SC.ONE_PCT_PBPS),
      0,
      type(uint16).max,
      0,
      prior,
      uint48(uint256(prior) * 1000)
    );
    e.engine.open(address(lp), LP_AMT, 100e18);
  }

  function test_afterApplyDecay_freshEqualsStored() public {
    pool.seedLeg(
      400e18,
      1000e18,
      uint96(C.LIQUIDITY_INDEX_INIT),
      18,
      5000,
      uint32(1e6),
      C.DECAY_ENABLED_BIT,
      uint32(block.timestamp),
      C.HAIRCUT_SUPPRESSOR_DISABLE
    );
    vm.warp(block.timestamp + 3600);
    assertGt(pool.pendingDecayAmt(), 0);
    (uint256 beforeFresh,) = pool.previewWithdrawFresh(asset, LP_AMT);
    pool.applyPendingDecay();
    assertEq(pool.pendingDecayAmt(), 0);
    (uint256 stale,) = pool.previewWithdraw(asset, LP_AMT);
    (uint256 fresh,) = pool.previewWithdrawFresh(asset, LP_AMT);
    assertEq(stale, fresh, "after accrue, stored == fresh");
    assertEq(stale, beforeFresh, "accrue matches prior virtual preview");
  }
}
