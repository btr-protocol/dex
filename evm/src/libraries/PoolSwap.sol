// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Pricing} from "./Pricing.sol";
import {Constants as C} from "./Constants.sol";
import {PoolDecay} from "./PoolDecay.sol";
import {PoolIO} from "./PoolIO.sol";

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

        // Inline former PoolSwapQuote trampoline (G-1/L-1) — exec already enforces minLiquidity (G-5).
        out = q.amountOut;
        PoolIO.exec($, tk[0], tk[1], actualIn, q);

        if (out < minAmountOut) revert Err.ThresholdViolation(out, minAmountOut);

        PoolIO.push($, tokenOut, recipient, out);
        emit IPool.Swapped(msg.sender, recipient, tk[0], tk[1], actualIn, out, q.spreadBps, q.protoFee, q.lpFee);
    }
}
