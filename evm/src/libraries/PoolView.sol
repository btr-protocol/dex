// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {PoolLiquidity} from "./PoolLiquidity.sol";
import {PoolIO} from "./PoolIO.sol";
import {Pricing} from "./Pricing.sol";

/// @title PoolView - non-trivial read helpers extracted from Pool.sol
library PoolView {
  function previewWithdraw(IPool.PoolStorage storage $, address tk, uint256 lp)
    external
    view
    returns (uint256 amountOut, uint256 haircut)
  {
    IPool.Asset storage a = $.assets[PoolIO.wrap($, tk)];
    uint256 wv = (lp * uint256(a.liquidityIndex)) / SC.WAD;
    (amountOut, haircut) =
      PoolLiquidity.applyHaircut(wv, a.reserves, a.liabilities, a.haircutSuppressor);
  }

  function getCoverageRatio(IPool.PoolStorage storage $, address tk)
    external
    view
    returns (uint256)
  {
    IPool.Asset storage a = $.assets[PoolIO.wrap($, tk)];
    if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tk);
    return Pricing.calculateCoverage(a.reserves, a.liabilities);
  }
}
