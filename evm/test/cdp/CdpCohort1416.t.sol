// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {ICdp} from "../../src/interfaces/ICdp.sol";
import {CdpConstants} from "../../src/libraries/CdpConstants.sol";
import {DebtToken} from "../../src/DebtToken.sol";
import {MockCdpPool, MockLpToken} from "./mocks/CdpMocks.sol";
import {CdpTestBase} from "./CdpTestBase.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

contract CdpCohort1416Test is CdpTestBase {
  using stdStorage for StdStorage;

  address owner = address(0xA11CE);
  address guardian = address(0x4444);
  address backstop = address(0xBACE);
  CdpEnv e;
  DebtToken btrUSD;
  MockCdpPool pool;
  MockLpToken lp;
  address asset = address(0x1111);

  function setUp() public {
    e = _deployCdp(owner);
    e.ac.setTreasury(backstop);
    e.ac.setGuardian(guardian, true);
    btrUSD = e.btrUSD;
    pool = new MockCdpPool();
    lp = new MockLpToken();
    _listUsd(e.registry, owner, address(lp), address(pool), asset, address(btrUSD), 500e18);
  }

  function test_C14_01_badDebtBlocksRemintUntilRepaid() public {
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    e.engine.open(address(lp), 600e18, 400e18);
    stdstore.target(address(e.engine)).sig("badDebt(address)").with_key(address(btrUSD))
      .checked_write(200e18);
    vm.expectRevert(abi.encodeWithSelector(ICdp.CeilingExceeded.selector, 400e18 + 1 + 200e18, 500e18));
    e.engine.adjust(address(lp), 0, int256(1));

    MockLpToken lp2 = new MockLpToken();
    _listUsd(e.registry, owner, address(lp2), address(pool), asset, address(btrUSD), 1e27);
    lp2.mint(address(this), 1000e18);
    lp2.approve(address(e.engine), type(uint256).max);
    vm.prank(owner);
    e.engine.setSyntheticCeiling(address(btrUSD), 500e18);
    vm.expectRevert(
      abi.encodeWithSelector(ICdp.SyntheticCeilingExceeded.selector, 400e18 + 200e18 + 1, 500e18)
    );
    e.engine.open(address(lp2), 200e18, 1);
    e.engine.repayBadDebt(address(btrUSD), 200e18);
    assertEq(e.engine.badDebt(address(btrUSD)), 0);
    e.engine.open(address(lp2), 200e18, 100e18);
    assertEq(e.engine.totalDebtBySynthetic(address(btrUSD)), 500e18);
  }

  function test_C14_02_wipeOneWeiReverts() public {
    address liq = address(0x3333);
    lp.mint(liq, 2000e18);
    vm.startPrank(liq);
    lp.approve(address(e.engine), type(uint256).max);
    e.engine.open(address(lp), 1200e18, 200e18);
    vm.stopPrank();
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    e.engine.open(address(lp), 1000e18, 300e18);
    pool.setLiquidityIndex(0);
    vm.prank(liq);
    vm.expectRevert(abi.encodeWithSelector(ICdp.ExhaustRequiresFullCover.selector, 1, 300e18));
    e.engine.liquidate(address(this), address(lp), 1);
  }

  function test_GOV_01_sealBlocksImmediateList() public {
    vm.prank(owner);
    e.registry.sealBootstrap();
    MockLpToken lpX = new MockLpToken();
    vm.prank(owner);
    vm.expectRevert(ICdp.BootstrapSealed.selector);
    e.registry.listWithParams(
      address(lpX), address(pool), asset, address(btrUSD), ICdp.Denom.USD, false, 0, 8500, 9000, 300
    );
    vm.prank(owner);
    e.registry.requestList(
      address(lpX),
      address(pool),
      asset,
      address(btrUSD),
      ICdp.Denom.USD,
      false,
      0,
      CdpConstants.STABLE_CORE_CANONICAL_LTV_BPS,
      CdpConstants.STABLE_CORE_CANONICAL_LT_BPS,
      CdpConstants.STABLE_CORE_CANONICAL_BONUS_BPS
    );
    _warpGov();
    vm.prank(owner);
    e.registry.executeList(address(lpX));
    assertEq(e.registry.get(address(lpX)).pool, address(pool));
  }

  function test_GOV_01_requestListBeforeSealReverts() public {
    MockLpToken lpX = new MockLpToken();
    vm.prank(owner);
    vm.expectRevert(ICdp.BootstrapOpen.selector);
    e.registry.requestList(
      address(lpX), address(pool), asset, address(btrUSD), ICdp.Denom.USD, false, 0, 8500, 9000, 300
    );
  }
}
