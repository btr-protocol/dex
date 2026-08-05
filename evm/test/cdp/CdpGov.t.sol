// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Err} from "@btr-shared/Errors.sol";
import {ICdp} from "../../src/interfaces/ICdp.sol";
import {CdpTimelock} from "../../src/libraries/CdpTimelock.sol";
import {DebtToken} from "../../src/DebtToken.sol";
import {MockCdpPool, MockLpToken} from "./mocks/CdpMocks.sol";
import {CdpTestBase} from "./CdpTestBase.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

contract CdpGovTest is CdpTestBase {
  using stdStorage for StdStorage;

  address owner = address(0xA11CE);
  address guardian = address(0x4444);
  address backstop = address(0xBACE);
  CdpEnv e;
  DebtToken btrUSD;
  MockCdpPool pool;
  MockLpToken lp;
  MockLpToken lp2;
  address asset = address(0x1111);

  function setUp() public {
    e = _deployCdp(owner);
    e.ac.setTreasury(backstop);
    e.ac.setGuardian(guardian, true);
    btrUSD = e.btrUSD;
    pool = new MockCdpPool();
    lp = new MockLpToken();
    lp2 = new MockLpToken();
    _listUsd(e.registry, owner, address(lp), address(pool), asset, address(btrUSD), 500e18);
  }

  function test_tier_tightenImmediate() public {
    vm.prank(owner);
    e.registry.setTier(address(lp), 8000, 8800, 200);
    ICdp.CollateralConfig memory c = e.registry.get(address(lp));
    assertEq(c.ltvBps, 8000);
    assertEq(c.ltBps, 8800);
    assertEq(c.bonusBps, 200);
  }

  function test_tier_weakenMustQueue() public {
    vm.prank(owner);
    vm.expectRevert(ICdp.MustQueue.selector);
    e.registry.setTier(address(lp), 8600, 9000, 300);
  }

  function test_tier_weakenQueuesAndExecutes() public {
    vm.prank(owner);
    e.registry.requestSetTier(address(lp), 8600, 9100, 400);
    vm.prank(owner);
    vm.expectRevert(Err.NotReady.selector);
    e.registry.executeSetTier(address(lp));
    _warpGov();
    vm.prank(owner);
    e.registry.executeSetTier(address(lp));
    ICdp.CollateralConfig memory c = e.registry.get(address(lp));
    assertEq(c.ltvBps, 8600);
    assertEq(c.ltBps, 9100);
    assertEq(c.bonusBps, 400);
  }

  function test_tier_stillRejects95() public {
    vm.prank(owner);
    vm.expectRevert(ICdp.BadParams.selector);
    e.registry.requestSetTier(address(lp), 9500, 9700, 200);
  }

  function test_disableImmediate_guardian() public {
    vm.prank(guardian);
    e.registry.disable(address(lp));
    assertFalse(e.registry.get(address(lp)).enabled);
    lp.mint(address(this), 100e18);
    lp.approve(address(e.engine), type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(ICdp.CollateralDisabled.selector, address(lp)));
    e.engine.open(address(lp), 100e18, 1);
  }

  function test_enableMustQueue() public {
    vm.prank(owner);
    e.registry.disable(address(lp));
    vm.prank(owner);
    e.registry.requestEnable(address(lp));
    _warpGov();
    vm.prank(owner);
    e.registry.executeEnable(address(lp));
    assertTrue(e.registry.get(address(lp)).enabled);
  }

  function test_collateralCeiling_bindsMint() public {
    vm.prank(owner);
    e.registry.setCeiling(address(lp), 300e18);
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    e.engine.open(address(lp), 500e18, 300e18);
    vm.expectRevert(abi.encodeWithSelector(ICdp.CeilingExceeded.selector, 301e18, 300e18));
    e.engine.adjust(address(lp), int256(0), int256(1e18));
  }

  function test_collateralCeiling_raiseQueues() public {
    vm.prank(owner);
    vm.expectRevert(ICdp.MustQueue.selector);
    e.registry.setCeiling(address(lp), 1000e18);
    vm.prank(owner);
    e.registry.requestSetCeiling(address(lp), 1000e18);
    _warpGov();
    vm.prank(owner);
    e.registry.executeSetCeiling(address(lp));
    assertEq(e.registry.get(address(lp)).ceiling, 1000e18);
  }

  function test_collateralCeiling_lowerImmediate() public {
    vm.prank(owner);
    e.registry.setCeiling(address(lp), 200e18);
    assertEq(e.registry.get(address(lp)).ceiling, 200e18);
  }

  function test_syntheticCeiling_bindsAcrossCollaterals() public {
    _listUsd(e.registry, owner, address(lp2), address(pool), asset, address(btrUSD), 0);
    vm.prank(owner);
    e.engine.setSyntheticCeiling(address(btrUSD), 300e18);
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    e.engine.open(address(lp), 400e18, 250e18);
    lp2.mint(address(this), 1000e18);
    lp2.approve(address(e.engine), type(uint256).max);
    vm.expectRevert(
      abi.encodeWithSelector(ICdp.SyntheticCeilingExceeded.selector, 350e18, 300e18)
    );
    e.engine.open(address(lp2), 400e18, 100e18);
    e.engine.open(address(lp2), 400e18, 50e18);
    assertEq(e.engine.totalDebtBySynthetic(address(btrUSD)), 300e18);
  }

  function test_syntheticCeiling_raiseQueues() public {
    vm.prank(owner);
    e.engine.setSyntheticCeiling(address(btrUSD), 100e18);
    vm.prank(owner);
    vm.expectRevert(ICdp.MustQueue.selector);
    e.engine.setSyntheticCeiling(address(btrUSD), 200e18);
    vm.prank(owner);
    e.engine.requestSetSyntheticCeiling(address(btrUSD), 200e18);
    _warpGov();
    vm.prank(owner);
    e.engine.executeSetSyntheticCeiling(address(btrUSD));
    assertEq(e.engine.syntheticCeiling(address(btrUSD)), 200e18);
  }

  function test_haircut_raiseImmediate_lowerQueues() public {
    vm.prank(owner);
    e.engine.setHaircuts(200, 100);
    assertEq(e.engine.hlBps(), 200);
    vm.prank(owner);
    vm.expectRevert(ICdp.MustQueue.selector);
    e.engine.setHaircuts(100, 100);
    vm.prank(owner);
    e.engine.requestSetHaircuts(100, 50);
    _warpGov();
    vm.prank(owner);
    e.engine.executeSetHaircuts();
    assertEq(e.engine.hlBps(), 100);
    assertEq(e.engine.hoBps(), 50);
  }

  function test_basis_lowerImmediate_raiseQueues() public {
    vm.prank(owner);
    e.engine.setBasisWad(address(lp), 0.99e18);
    assertEq(e.engine.basisWad(address(lp)), 0.99e18);
    vm.prank(owner);
    vm.expectRevert(ICdp.MustQueue.selector);
    e.engine.setBasisWad(address(lp), 0);
    vm.prank(owner);
    e.engine.requestSetBasisWad(address(lp), 0);
    _warpGov();
    vm.prank(owner);
    e.engine.executeSetBasisWad(address(lp));
    assertEq(e.engine.basisWad(address(lp)), 0);
  }

  function test_repayBadDebt() public {
    lp.mint(address(this), 100e18);
    lp.approve(address(e.engine), type(uint256).max);
    e.engine.open(address(lp), 100e18, 85e18);
    stdstore.target(address(e.engine)).sig("badDebt(address)").with_key(address(btrUSD))
      .checked_write(65e18);
    assertEq(e.engine.badDebt(address(btrUSD)), 65e18);
    e.engine.repayBadDebt(address(btrUSD), 65e18);
    assertEq(e.engine.badDebt(address(btrUSD)), 0);
  }

  function test_repayBadDebt_revertsIfNone() public {
    vm.expectRevert(ICdp.NoBadDebt.selector);
    e.engine.repayBadDebt(address(btrUSD), 1);
  }

  function test_guardian_cancelTimelock() public {
    vm.prank(owner);
    e.registry.requestSetTier(address(lp), 8600, 9100, 300);
    vm.prank(guardian);
    e.registry.cancel(CdpTimelock.OP_SET_TIER, address(lp));
    assertEq(e.registry.pendingOps(CdpTimelock.key(CdpTimelock.OP_SET_TIER, address(lp))), 0);
  }

  function test_guardian_cancelEngineTimelock() public {
    vm.prank(owner);
    e.engine.setHaircuts(200, 100);
    vm.prank(owner);
    e.engine.requestSetHaircuts(0, 0);
    bytes32 id = CdpTimelock.keyHaircuts();
    assertTrue(e.engine.pendingOps(id) != 0);
    vm.prank(guardian);
    e.engine.cancel(CdpTimelock.OP_SET_HAIRCUTS, address(0));
    assertEq(e.engine.pendingOps(id), 0);
  }

  function test_guardian_freezeOnly_ownerUnfreezes() public {
    vm.prank(guardian);
    e.engine.setMintFrozen(address(btrUSD), true);
    assertTrue(e.engine.mintFrozen(address(btrUSD)));
    vm.prank(guardian);
    vm.expectRevert(Err.NotOwner.selector);
    e.engine.setMintFrozen(address(btrUSD), false);
    vm.prank(owner);
    e.engine.setMintFrozen(address(btrUSD), false);
    assertFalse(e.engine.mintFrozen(address(btrUSD)));
  }
}
