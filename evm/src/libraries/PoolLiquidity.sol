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

/// @title PoolLiquidity -deposit/donate/withdraw/swapLiability extracted from Pool.sol
/// @notice Wave-2 bytecode reduction. Pure refactor; behavior preserved.
///         External lib fns DELEGATECALL'd from Pool trampolines; reentrancy
///         + whenInitialized enforced at the trampoline.
library PoolLiquidity {
    using SafeTransferLib for address;

    uint256 internal constant INIT_LIQUIDITY_INDEX = 1e12;

    // Events canonical @ IPool (Deposited / Withdrawn / LiabilitySwapped / Donated).
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

    function _checkCooldown(IPool.PoolStorage storage $, uint32 lastTs) private view {
        uint16 cooldown = $.flowCooldownSeconds;
        if (cooldown == 0 || lastTs == 0) return;
        unchecked {
            if (block.timestamp < lastTs + cooldown) {
                revert Err.CooldownActive(lastTs + cooldown - uint32(block.timestamp));
            }
        }
    }

    function applyHaircut(
        uint256 amount,
        uint128 reserves,
        uint128 liabilities,
        uint16 suppression
    ) internal pure returns (uint256 actualAmount, uint256 haircutAmount) {
        if (liabilities == 0 || reserves >= liabilities) return (amount, 0);
        uint256 deficit = ((uint256(liabilities) - uint256(reserves)) * 1e18) / uint256(liabilities);
        uint256 factor = suppression >= 20000 ? 0 : 1e18 - (uint256(suppression) * 1e18 / 20000);
        uint256 haircutRatio = (deficit * factor) / 1e18;
        if (haircutRatio > 1e18) haircutRatio = 1e18;
        haircutAmount = (amount * haircutRatio) / 1e18;
        actualAmount = amount - haircutAmount;
    }

    function deposit(
        IPool.PoolStorage storage $,
        address token,
        uint256 amount
    ) external returns (IPool.DepositResult memory) {
        if (amount == 0) revert Err.ZeroValue();

        address tkn = _wrap($, token);
        IPool.Asset storage asset = $.assets[tkn];
        if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tkn);

        PoolDecay.applyDecay($, tkn, asset);
        if (($.riskConfigs[tkn].flags & C.FROZEN_BIT) != 0) revert Err.FeatureDisabled(Err.Resource.ASSET);

        uint256 amt = _pull($, token, amount);
        if (amt > type(uint128).max) revert Err.ExcessiveAmount(amt, type(uint128).max);

        uint256 lpAmt = (amt * SC.WAD) / (asset.liquidityIndex == 0 ? INIT_LIQUIDITY_INDEX : asset.liquidityIndex);

        asset.reserves += uint128(amt);
        asset.liabilities += uint128(amt);
        $.lpBalances[msg.sender][tkn] += lpAmt;
        $.lastDepositTime[msg.sender][tkn] = uint32(block.timestamp);

        emit IPool.Deposited(msg.sender, tkn, amt, lpAmt);
        return IPool.DepositResult({lpAmount: lpAmt, actualDeposit: amt});
    }

    function donate(
        IPool.PoolStorage storage $,
        address token,
        uint256 amount
    ) external {
        if (amount == 0) revert Err.ZeroValue();

        address tkn = _wrap($, token);
        IPool.Asset storage asset = $.assets[tkn];
        if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tkn);

        PoolDecay.applyDecay($, tkn, asset);
        _checkRisk($, tkn, 0);

        uint256 amt = _pull($, token, amount);
        if (amt > type(uint128).max) revert Err.ExcessiveAmount(amt, type(uint128).max);

        uint256 liabBefore = uint256(asset.liabilities);
        asset.reserves += uint128(amt);
        asset.liabilities += uint128(amt);

        uint256 idx = asset.liquidityIndex == 0 ? INIT_LIQUIDITY_INDEX : asset.liquidityIndex;
        asset.liquidityIndex = uint64(liabBefore == 0 ? idx : (idx * (liabBefore + amt)) / liabBefore);

        emit IPool.Donated(msg.sender, token, amt);
    }

    struct WithdrawCtx {
        address fromTk;
        address toTk;
        uint256 withdrawValue;
        uint256 amt;
        uint256 haircut;
    }

    function withdrawTo(
        IPool.PoolStorage storage $,
        address tokenFrom,
        address tokenTo,
        uint256 lpAmount,
        uint256 minAmountOut
    ) external returns (IPool.WithdrawResult memory) {
        if (lpAmount == 0) revert Err.ZeroValue();

        WithdrawCtx memory ctx;
        ctx.fromTk = _wrap($, tokenFrom);
        ctx.toTk = _wrap($, tokenTo);

        _checkCooldown($, $.lastDepositTime[msg.sender][ctx.fromTk]);
        if ($.lpBalances[msg.sender][ctx.fromTk] < lpAmount) {
            revert Err.InsufficientAmount($.lpBalances[msg.sender][ctx.fromTk], lpAmount);
        }

        {
            IPool.Asset storage assetFrom = $.assets[ctx.fromTk];
            IPool.Asset storage assetTo = $.assets[ctx.toTk];
            if (assetFrom.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, ctx.fromTk);
            if (assetTo.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, ctx.toTk);
            PoolDecay.applyDecay($, ctx.fromTk, assetFrom);
            PoolDecay.applyDecay($, ctx.toTk, assetTo);

            ctx.withdrawValue = (lpAmount * (assetFrom.liquidityIndex == 0 ? INIT_LIQUIDITY_INDEX : assetFrom.liquidityIndex)) / SC.WAD;
        }

        if (ctx.fromTk == ctx.toTk) {
            _withdrawSame($, ctx);
        } else {
            _withdrawCross($, ctx);
        }

        $.lpBalances[msg.sender][ctx.fromTk] -= lpAmount;
        {
            IPool.Asset storage assetTo = $.assets[ctx.toTk];
            if (assetTo.reserves < assetTo.minLiquidity) {
                revert Err.ThresholdViolation(assetTo.reserves, assetTo.minLiquidity);
            }
        }
        if (ctx.amt < minAmountOut) revert Err.ThresholdViolation(ctx.amt, minAmountOut);
        _push($, tokenTo, msg.sender, ctx.amt);

        if (ctx.fromTk == ctx.toTk) {
            emit IPool.Withdrawn(msg.sender, ctx.fromTk, ctx.amt, lpAmount);
        } else {
            emit IPool.LiabilitySwapped(msg.sender, ctx.fromTk, ctx.toTk, lpAmount, 0, ctx.haircut);
            emit IPool.Withdrawn(msg.sender, ctx.toTk, ctx.amt, lpAmount);
        }
        return IPool.WithdrawResult({amountOut: ctx.amt, lpBurned: lpAmount});
    }

    function _withdrawSame(IPool.PoolStorage storage $, WithdrawCtx memory ctx) private {
        IPool.Asset storage assetFrom = $.assets[ctx.fromTk];
        (ctx.amt, ctx.haircut) = applyHaircut(ctx.withdrawValue, assetFrom.reserves, assetFrom.liabilities, assetFrom.haircutSuppressor);
        if (assetFrom.reserves < ctx.amt) revert Err.InsufficientAmount(assetFrom.reserves, ctx.amt);
        if (ctx.amt > type(uint128).max) revert Err.ExcessiveAmount(ctx.amt, type(uint128).max);

        uint256 liabRed = ctx.withdrawValue > assetFrom.liabilities ? assetFrom.liabilities : ctx.withdrawValue;
        assetFrom.reserves -= uint128(ctx.amt);
        assetFrom.liabilities -= uint128(liabRed);
    }

    function _withdrawCross(IPool.PoolStorage storage $, WithdrawCtx memory ctx) private {
        IPool.Asset storage assetFrom = $.assets[ctx.fromTk];
        IPool.Asset storage assetTo = $.assets[ctx.toTk];
        IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, ctx.fromTk, ctx.toTk, ctx.withdrawValue);
        (ctx.amt, ctx.haircut) = applyHaircut(q.amountOut, assetTo.reserves, assetTo.liabilities, assetTo.haircutSuppressor);
        if (assetTo.reserves < ctx.amt + q.protoFee) revert Err.InsufficientAmount(assetTo.reserves, ctx.amt + q.protoFee);

        uint256 liabRed = ctx.withdrawValue > assetFrom.liabilities ? assetFrom.liabilities : ctx.withdrawValue;
        assetFrom.liabilities -= uint128(liabRed);

        if (q.protoFee > 0) $.protocolFees[ctx.toTk] += q.protoFee;
        assetTo.reserves -= uint128(ctx.amt + q.protoFee);
    }

    function swapLiability(
        IPool.PoolStorage storage $,
        address tokenIn,
        address tokenOut,
        uint256 lpAmountIn,
        uint256 minLpAmountOut
    ) external returns (uint256 lpAmountOut) {
        if (lpAmountIn == 0) revert Err.ZeroValue();

        address inTk = _wrap($, tokenIn);
        address outTk = _wrap($, tokenOut);
        if (inTk == outTk) revert Err.InvalidInput();

        IPool.Asset storage assetIn = $.assets[inTk];
        IPool.Asset storage assetOut = $.assets[outTk];
        if (assetIn.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, inTk);
        if (assetOut.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, outTk);

        PoolDecay.applyDecay($, inTk, assetIn);
        PoolDecay.applyDecay($, outTk, assetOut);
        _checkRisk($, inTk, C.LIABILITY_SWAP_ENABLED_BIT);
        _checkRisk($, outTk, C.LIABILITY_SWAP_ENABLED_BIT);

        if ($.lpBalances[msg.sender][inTk] < lpAmountIn) {
            revert Err.InsufficientAmount($.lpBalances[msg.sender][inTk], lpAmountIn);
        }

        uint256 liabIn = (lpAmountIn * (assetIn.liquidityIndex == 0 ? INIT_LIQUIDITY_INDEX : assetIn.liquidityIndex)) / SC.WAD;
        if (liabIn > assetIn.liabilities) revert Err.InsufficientAmount(assetIn.liabilities, liabIn);

        IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, inTk, outTk, liabIn);
        uint256 liabOut = q.amountOut;
        uint256 haircut;

        if (assetOut.reserves < assetOut.liabilities) {
            (liabOut, haircut) = applyHaircut(liabOut, assetOut.reserves, assetOut.liabilities, assetOut.haircutSuppressor);
        }

        lpAmountOut = (liabOut * SC.WAD) / (assetOut.liquidityIndex == 0 ? INIT_LIQUIDITY_INDEX : assetOut.liquidityIndex);

        assetIn.liabilities -= uint128(liabIn);
        assetOut.liabilities += uint128(liabOut);
        if (lpAmountOut < minLpAmountOut) revert Err.ThresholdViolation(lpAmountOut, minLpAmountOut);

        $.lpBalances[msg.sender][inTk] -= lpAmountIn;
        $.lpBalances[msg.sender][outTk] += lpAmountOut;

        emit IPool.LiabilitySwapped(msg.sender, inTk, outTk, lpAmountIn, lpAmountOut, haircut);
        return lpAmountOut;
    }
}
