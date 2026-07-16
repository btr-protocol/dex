// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as C} from "./Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {PoolLiquidity} from "./PoolLiquidity.sol";
import {PoolIO} from "./PoolIO.sol";

/// @title PoolView — non-trivial read helpers extracted from Pool.sol
library PoolView {
  function previewWithdraw(IPool.PoolStorage storage $, address tk, uint256 lp)
    external
    view
    returns (uint256 amountOut, uint256 haircut)
  {
    IPool.Asset storage a = $.assets[PoolIO.wrap($, tk)];
    uint256 li = a.liquidityIndex == 0 ? C.LIQUIDITY_INDEX_INIT : a.liquidityIndex;
    uint256 wv = (lp * li) / SC.WAD;
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
    if (a.liabilities == 0) return type(uint256).max;
    return (uint256(a.reserves) * SC.WAD) / uint256(a.liabilities);
  }
}
