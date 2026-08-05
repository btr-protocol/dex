// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {MockAC} from "../fixtures/BaseTestSetup.sol";
import {CDPEngine} from "../../src/CDPEngine.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {DebtToken} from "../../src/DebtToken.sol";
import {ICdp} from "../../src/interfaces/ICdp.sol";
import {CdpConstants} from "../../src/libraries/CdpConstants.sol";
import {DebtTokenFactory} from "./mocks/DebtTokenFactory.sol";

abstract contract CdpTestBase is Test {
  struct CdpEnv {
    MockAC ac;
    CollateralRegistry registry;
    CDPEngine engine;
    DebtToken btrUSD;
    DebtToken btrBTC;
  }

  function _deployCdp(address owner) internal returns (CdpEnv memory e) {
    e.ac = new MockAC(owner);
    e.registry = new CollateralRegistry(address(e.ac));
    e.engine = new CDPEngine(address(e.ac), address(e.registry));
    (address usd, address btc,,) = (new DebtTokenFactory()).deploySuite(address(e.engine));
    e.btrUSD = DebtToken(usd);
    e.btrBTC = DebtToken(btc);
    _zeroHaircuts(e.engine, owner);
  }

  function _listUsd(
    CollateralRegistry registry,
    address owner,
    address lpToken,
    address pool,
    address asset,
    address debtToken,
    uint128 ceiling
  ) internal {
    vm.prank(owner);
    registry.listWithParams(
      lpToken,
      pool,
      asset,
      debtToken,
      ICdp.Denom.USD,
      false,
      ceiling,
      CdpConstants.STABLE_CORE_CANONICAL_LTV_BPS,
      CdpConstants.STABLE_CORE_CANONICAL_LT_BPS,
      CdpConstants.STABLE_CORE_CANONICAL_BONUS_BPS
    );
  }

  function _zeroHaircuts(CDPEngine engine, address owner) internal {
    vm.prank(owner);
    engine.requestSetHaircuts(0, 0);
    vm.warp(block.timestamp + SC.govDelay(SC.LOW_TIMELOCK));
    vm.prank(owner);
    engine.executeSetHaircuts();
  }

  function _warpGov() internal {
    vm.warp(block.timestamp + SC.govDelay(SC.LOW_TIMELOCK));
  }
}
