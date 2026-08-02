// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Pricing} from "./Pricing.sol";
import {Constants as C} from "./Constants.sol";
import {PoolDecay} from "./PoolDecay.sol";
import {PoolIO} from "./PoolIO.sol";
import {PoolHooks} from "./PoolHooks.sol";

/// @title PoolSwap — single-leg swap orchestration.
library PoolSwap {
  function swap(
    IPool.PoolStorage storage $,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address recipient
  ) external returns (uint256 out) {
    address inTk = PoolIO.wrap($, tokenIn);
    address outTk = PoolIO.wrap($, tokenOut);
    if (inTk == outTk) revert Err.InvalidInput();
    if (amountIn == 0) revert Err.ZeroValue();

    IPool.Asset storage aIn = $.assets[inTk];
    IPool.Asset storage aOut = $.assets[outTk];

    // One risk SLOAD per token: halt/swap gate + decay early-out (G-4).
    IPool.RiskConfig storage rIn = $.riskConfigs[inTk];
    IPool.RiskConfig storage rOut = $.riskConfigs[outTk];
    PoolIO.checkRiskFlags(rIn, C.SWAP_ENABLED_BIT);
    PoolIO.checkRiskFlags(rOut, C.SWAP_ENABLED_BIT);
    PoolDecay.applyDecay(aIn, rIn, inTk);
    PoolDecay.applyDecay(aOut, rOut, outTk);

    uint256 actualIn = PoolIO.pull($, tokenIn, amountIn);
    IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, inTk, outTk, actualIn);

    out = q.amountOut;
    // Cov-wall full drain can yield amountOut==0; never settle a zero-delivery swap (A-02).
    if (out == 0) revert Err.ZeroValue();
    PoolIO.settle($, inTk, outTk, actualIn, q, aIn, aOut);

    if (out < minAmountOut) revert Err.ThresholdViolation(out, minAmountOut);

    PoolIO.push($, tokenOut, recipient, out);
    emit IPool.Swapped(
      msg.sender, recipient, inTk, outTk, actualIn, out, q.spreadPbps, q.protoFee, q.lpFee
    );
  }
}
