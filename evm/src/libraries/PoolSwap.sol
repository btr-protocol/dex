// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Pricing} from "./Pricing.sol";
import {Constants as C} from "./Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {PoolDecay} from "./PoolDecay.sol";
import {PoolSwapQuote} from "./PoolSwapQuote.sol";

/// @title PoolSwap -single-leg swap orchestration (entry + I/O wrap/pull/push).
/// @notice Phase 42K.10D.B2: post-quote pipeline (hook fees, _exec, oracle push) moved to
///         PoolSwapQuote (external library, DELEGATECALL'd) so PoolSwap's standalone bytecode
///         fits under EIP-170. Behavior preserved; adds ~700 gas/swap for the extra delegate hop
///         on the cold path through PoolSwapQuote.
library PoolSwap {
    using SafeTransferLib for address;

    function _wrap(IPool.PoolStorage storage $, address token) private view returns (address) {
        return token == SC.NATIVE ? $.wnative : token;
    }

    function _balanceOf(address token) private view returns (uint256) {
        return SafeTransferLib.balanceOf(token, address(this));
    }

    function _pull(IPool.PoolStorage storage $, address token, uint256 amount) private returns (uint256) {
        if (token == SC.NATIVE) {
            if (msg.value < amount) revert Err.InsufficientAmount(msg.value, amount);
            IWETH9($.wnative).deposit{value: amount}();
            unchecked {
                uint256 excess = msg.value - amount;
                if (excess > 0) SafeTransferLib.safeTransferETH(msg.sender, excess);
            }
            return amount;
        }
        uint256 balBefore = _balanceOf(token);
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        return _balanceOf(token) - balBefore;
    }

    function _push(IPool.PoolStorage storage $, address token, address to, uint256 amount) private {
        if (token == SC.NATIVE) {
            IWETH9($.wnative).withdraw(amount);
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            SafeTransferLib.safeTransfer(token, to, amount);
        }
    }

    function _checkRisk(IPool.PoolStorage storage $, address token, uint16 requiredFlag) private view {
        IPool.RiskConfig storage risk = $.riskConfigs[token];
        if ((risk.flags & C.FROZEN_BIT) != 0) revert Err.FeatureDisabled(Err.Resource.ASSET);
        if (requiredFlag != 0 && (risk.flags & requiredFlag) == 0) {
            if (requiredFlag == C.SWAP_ENABLED_BIT) revert Err.FeatureDisabled(Err.Resource.SWAP);
            if (requiredFlag == C.LIABILITY_SWAP_ENABLED_BIT) revert Err.FeatureDisabled(Err.Resource.LIABILITY_SWAP);
            if (requiredFlag == C.FLASH_ENABLED_BIT) revert Err.FeatureDisabled(Err.Resource.FLASH);
        }
    }

    function swap(
        IPool.PoolStorage storage $,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 out) {
        address[2] memory tk = [_wrap($, tokenIn), _wrap($, tokenOut)];
        if (tk[0] == tk[1]) revert Err.InvalidInput();
        if (amountIn == 0) revert Err.ZeroValue();

        IPool.Asset storage aIn  = $.assets[tk[0]];
        IPool.Asset storage aOut = $.assets[tk[1]];

        _checkRisk($, tk[0], C.SWAP_ENABLED_BIT);
        _checkRisk($, tk[1], C.SWAP_ENABLED_BIT);
        PoolDecay.applyDecay($, tk[0], aIn);
        PoolDecay.applyDecay($, tk[1], aOut);

        uint256 actualIn = _pull($, tokenIn, amountIn);
        IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, tk[0], tk[1], actualIn);

        out = PoolSwapQuote.processSwap($, tk, actualIn, q);

        if (aOut.reserves < aOut.minLiquidity) {
            revert Err.ThresholdViolation(aOut.reserves, aOut.minLiquidity);
        }

        PoolSwapQuote.pushOracle($, q);
        if (out < minAmountOut) revert Err.ThresholdViolation(out, minAmountOut);

        _push($, tokenOut, recipient, out);
        emit IPool.Swapped(msg.sender, recipient, tk[0], tk[1], actualIn, out, q.spreadBps, q.protoFee, q.lpFee);
    }
}
