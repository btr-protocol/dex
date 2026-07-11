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
        address[2] memory tk = [PoolIO.wrap($, tokenIn), PoolIO.wrap($, tokenOut)];
        if (tk[0] == tk[1]) revert Err.InvalidInput();
        if (amountIn == 0) revert Err.ZeroValue();

        IPool.Asset storage aIn = $.assets[tk[0]];
        IPool.Asset storage aOut = $.assets[tk[1]];

        // One risk SLOAD per token: halt/swap gate + decay early-out (G-4).
        IPool.RiskConfig storage rIn = $.riskConfigs[tk[0]];
        IPool.RiskConfig storage rOut = $.riskConfigs[tk[1]];
        PoolIO.checkRiskFlags(rIn, C.SWAP_ENABLED_BIT);
        PoolIO.checkRiskFlags(rOut, C.SWAP_ENABLED_BIT);
        PoolDecay.applyDecay(aIn, rIn);
        PoolDecay.applyDecay(aOut, rOut);

        uint256 actualIn = PoolIO.pull($, tokenIn, amountIn);
        IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, tk[0], tk[1], actualIn);

        out = q.amountOut;
        // Hard recall on tokenOut only when R_liq shortfall (0 CALL if buffer OK).
        uint256 need = out + q.protoFee + aOut.minLiquidity;
        PoolHooks.beforeOutflow($, tk[1], msg.sender, need);

        PoolIO.exec($, tk[0], tk[1], actualIn, q, aIn, aOut);

        if (out < minAmountOut) revert Err.ThresholdViolation(out, minAmountOut);

        PoolIO.push($, tokenOut, recipient, out);
        emit IPool.Swapped(msg.sender, recipient, tk[0], tk[1], actualIn, out, q.spreadBps, q.protoFee, q.lpFee);
    }
}
