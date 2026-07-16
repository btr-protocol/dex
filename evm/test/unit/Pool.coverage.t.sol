// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {PoolView} from "../../src/libraries/PoolView.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";

/// @notice Harness exposing PoolView.getCoverageRatio over a slot-0 PoolStorage.
contract CoverageHarness {
  IPool.PoolStorage internal $;

  function setAssetReserves(address tk, uint128 r, uint128 l, uint8 decimals) external {
    $.assets[tk].reserves = r;
    $.assets[tk].liabilities = l;
    $.assets[tk].decimals = decimals;
  }

  function callGetCoverageRatio(address tk) external view returns (uint256) {
    return PoolView.getCoverageRatio($, tk);
  }
}

/// @title PoolCoverageTest
/// @notice Wave-3b Cohort-2 follow-up: direct coverage tests for getCoverageRatio.
contract PoolCoverageTest is Test {
  CoverageHarness h;
  address constant TKA = address(0xA1);

  function setUp() public {
    h = new CoverageHarness();
  }

  function test_getCoverageRatio_unregistered_reverts() public {
    // decimals=0 → asset unregistered → NotFound(ASSET, tk)
    vm.expectRevert(abi.encodeWithSelector(Err.NotFound.selector, Err.Resource.ASSET, TKA));
    h.callGetCoverageRatio(TKA);
  }

  function test_getCoverageRatio_zeroLiabilities_returnsMax() public {
    h.setAssetReserves(TKA, 100, 0, 18);
    assertEq(h.callGetCoverageRatio(TKA), type(uint256).max);
  }

  function test_getCoverageRatio_normalCase() public {
    h.setAssetReserves(TKA, 100, 200, 18);
    // reserves * WAD / liabilities = 100 * 1e18 / 200 = 5e17 (50%)
    assertEq(h.callGetCoverageRatio(TKA), 5e17);
  }

  function test_getCoverageRatio_fullCoverage() public {
    h.setAssetReserves(TKA, 1000, 1000, 18);
    assertEq(h.callGetCoverageRatio(TKA), SC.WAD); // 1e18 = 100%
  }

  function test_getCoverageRatio_overCollateralized() public {
    h.setAssetReserves(TKA, 200, 100, 18);
    // 200 * 1e18 / 100 = 2e18 (200%)
    assertEq(h.callGetCoverageRatio(TKA), 2e18);
  }
}
