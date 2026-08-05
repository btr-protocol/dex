// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {ICdp} from "../../src/interfaces/ICdp.sol";
import {CdpConstants} from "../../src/libraries/CdpConstants.sol";
import {DebtToken} from "../../src/DebtToken.sol";
import {MockCdpPool, MockLpToken} from "./mocks/CdpMocks.sol";
import {CdpTestBase} from "./CdpTestBase.sol";

contract CdpSameDenomTest is CdpTestBase {
  address owner = address(0xA11CE);
  CdpEnv e;
  MockCdpPool pool;
  MockLpToken lp;
  address asset = address(0x1111);

  function setUp() public {
    e = _deployCdp(owner);
    pool = new MockCdpPool();
    lp = new MockLpToken();
  }

  function test_list_defaultsStableCoreCanonical() public {
    _listUsd(e.registry, owner, address(lp), address(pool), asset, address(e.btrUSD), 1e27);
    ICdp.CollateralConfig memory c = e.registry.get(address(lp));
    assertEq(c.ltvBps, CdpConstants.STABLE_CORE_CANONICAL_LTV_BPS);
    assertEq(c.ltBps, CdpConstants.STABLE_CORE_CANONICAL_LT_BPS);
    assertEq(c.bonusBps, CdpConstants.STABLE_CORE_CANONICAL_BONUS_BPS);
    assertTrue(c.enabled);
    assertFalse(c.hooked);
  }

  function test_list_rejectsDenomMismatch() public {
    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(ICdp.SameDenomRequired.selector, ICdp.Denom.USD, ICdp.Denom.BTC)
    );
    e.registry.listWithParams(
      address(lp), address(pool), asset, address(e.btrBTC), ICdp.Denom.USD, false, 0, 8500, 9000, 300
    );
  }

  function test_list_rejectsHookedFlag() public {
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(ICdp.HookedCollateralForbidden.selector, address(lp)));
    e.registry.listWithParams(
      address(lp), address(pool), asset, address(e.btrUSD), ICdp.Denom.USD, true, 0, 8500, 9000, 300
    );
  }

  function test_list_rejectsLivePoolHook() public {
    pool.setHook(address(0x2222), 1);
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(ICdp.HookedCollateralForbidden.selector, address(lp)));
    e.registry.listWithParams(
      address(lp), address(pool), asset, address(e.btrUSD), ICdp.Denom.USD, false, 0, 8500, 9000, 300
    );
  }

  function test_open_mintsMatchingSynthetic() public {
    _listUsd(e.registry, owner, address(lp), address(pool), asset, address(e.btrUSD), 1e27);
    lp.mint(address(this), 1000e18);
    lp.approve(address(e.engine), type(uint256).max);
    e.engine.open(address(lp), 1000e18, 850e18);
    assertEq(e.btrUSD.balanceOf(address(this)), 850e18);
    assertEq(e.btrBTC.balanceOf(address(this)), 0);
  }

  function test_debtToken_onlyEngineMints() public {
    vm.expectRevert();
    e.btrUSD.mint(address(this), 1);
  }
}
