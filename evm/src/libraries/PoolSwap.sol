// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Pricing} from "./Pricing.sol";
import {Constants as C} from "./Constants.sol";
import {PoolDecay} from "./PoolDecay.sol";
import {PoolSwapQuote} from "./PoolSwapQuote.sol";
import {PoolIO} from "./PoolIO.sol";

/// @title PoolSwap -single-leg swap orchestration (entry + I/O wrap/pull/push).
/// @notice Phase 42K.10D.B2: post-quote pipeline (_exec, oracle push) moved to
///         PoolSwapQuote (external library, DELEGATECALL'd) so PoolSwap's standalone bytecode
///         fits under EIP-170. Behavior preserved; adds ~700 gas/swap for the extra delegate hop
///         on the cold path through PoolSwapQuote.
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

        IPool.Asset storage aIn  = $.assets[tk[0]];
        IPool.Asset storage aOut = $.assets[tk[1]];

        PoolIO.checkRisk($, tk[0], C.SWAP_ENABLED_BIT);
        PoolIO.checkRisk($, tk[1], C.SWAP_ENABLED_BIT);
        PoolDecay.applyDecay($, tk[0], aIn);
        PoolDecay.applyDecay($, tk[1], aOut);

        uint256 actualIn = PoolIO.pull($, tokenIn, amountIn);
        IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, tk[0], tk[1], actualIn);

        out = PoolSwapQuote.processSwap($, tk, actualIn, q);

        if (aOut.reserves < aOut.minLiquidity) {
            revert Err.ThresholdViolation(aOut.reserves, aOut.minLiquidity);
        }

        if (out < minAmountOut) revert Err.ThresholdViolation(out, minAmountOut);

        PoolIO.push($, tokenOut, recipient, out);
        emit IPool.Swapped(msg.sender, recipient, tk[0], tk[1], actualIn, out, q.spreadBps, q.protoFee, q.lpFee);
    }
}
