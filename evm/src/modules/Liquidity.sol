// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Base} from "./Base.sol";
import {Err} from "../Errors.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IExchange} from "../interfaces/modules/IExchange.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";

interface IExchangeQuote {
    function getSwapQuote(address tokenIn, address tokenOut, uint256 amountIn) external returns (IExchange.SwapQuote memory);
}

/// @title Liquidity — deposit, withdraw, donate, swapLiability
/// @dev Pulls swap quotes from Exchange via module registry (avoids LibPricing import).
contract Liquidity is Base {
    /// @dev Initial liquidity index (1e12 → ~18M× growth before uint64 overflow)
    uint256 private constant INIT_LIQUIDITY_INDEX = 1e12;

    // Events (mirrored from ICore to avoid import)
    event Deposited(address indexed sender, address indexed token, uint256 amount, uint256 lpAmount);
    event Withdrawn(address indexed sender, address indexed token, uint256 amount, uint256 lpAmount);
    event LiabilitySwapped(address indexed sender, address indexed tokenIn, address indexed tokenOut, uint256 lpAmountIn, uint256 lpAmountOut, uint256 haircut);
    event Donated(address indexed sender, address indexed token, uint256 amount);

    function deposit(
        address token,
        uint256 amount
    ) external payable nonReentrant whenInitialized returns (IPool.DepositResult memory result) {
        if (amount == 0) revert Err.ZeroValue();

        IPool.PoolStorage storage $ = _s();
        address tkn = _wrap($, token);
        IPool.Asset storage asset = _asset($, tkn);

        _applyDecay($, tkn, asset);
        if (($.riskConfigs[tkn].flags & C.FROZEN_BIT) != 0) revert Err.FeatureDisabled(Err.Resource.ASSET);

        uint256 amt = _pull(token, amount);
        if (amt > type(uint128).max) revert Err.ExcessiveAmount(amt, type(uint128).max);

        uint256 lpAmt = (amt * C.WAD) / (asset.liquidityIndex == 0 ? INIT_LIQUIDITY_INDEX : asset.liquidityIndex);

        asset.reserves += uint128(amt);
        asset.liabilities += uint128(amt);
        $.lpBalances[msg.sender][tkn] += lpAmt;
        _recordDeposit(msg.sender, tkn);

        emit Deposited(msg.sender, tkn, amt, lpAmt);
        return IPool.DepositResult({lpAmount: lpAmt, actualDeposit: amt});
    }

    function donate(address token, uint256 amount) external payable nonReentrant whenInitialized {
        if (amount == 0) revert Err.ZeroValue();

        IPool.PoolStorage storage $ = _s();
        address tkn = _wrap($, token);
        IPool.Asset storage asset = _asset($, tkn);

        _applyDecay($, tkn, asset);
        _checkRisk($, tkn, 0);

        uint256 amt = _pull(token, amount);
        if (amt > type(uint128).max) revert Err.ExcessiveAmount(amt, type(uint128).max);

        uint256 liabBefore = uint256(asset.liabilities);
        asset.reserves += uint128(amt);
        asset.liabilities += uint128(amt);

        uint256 idx = asset.liquidityIndex == 0 ? INIT_LIQUIDITY_INDEX : asset.liquidityIndex;
        asset.liquidityIndex = uint64(liabBefore == 0 ? idx : (idx * (liabBefore + amt)) / liabBefore);

        emit Donated(msg.sender, token, amt);
    }

    function withdraw(
        address token,
        uint256 lpAmount,
        uint256 minAmountOut
    ) external nonReentrant whenInitialized returns (IPool.WithdrawResult memory) {
        return _withdrawTo(token, token, lpAmount, minAmountOut);
    }

    function withdrawTo(
        address tokenFrom,
        address tokenTo,
        uint256 lpAmount,
        uint256 minAmountOut
    ) public nonReentrant whenInitialized returns (IPool.WithdrawResult memory) {
        return _withdrawTo(tokenFrom, tokenTo, lpAmount, minAmountOut);
    }

    function _withdrawTo(
        address tokenFrom,
        address tokenTo,
        uint256 lpAmount,
        uint256 minAmountOut
    ) private returns (IPool.WithdrawResult memory) {
        if (lpAmount == 0) revert Err.ZeroValue();

        IPool.PoolStorage storage $ = _s();
        address fromTk = _wrap($, tokenFrom);
        address toTk = _wrap($, tokenTo);

        _checkWithdrawCooldown(msg.sender, fromTk);
        if ($.lpBalances[msg.sender][fromTk] < lpAmount) {
            revert Err.InsufficientAmount($.lpBalances[msg.sender][fromTk], lpAmount);
        }

        IPool.Asset storage assetFrom = _asset($, fromTk);
        IPool.Asset storage assetTo = _asset($, toTk);
        _applyDecay($, fromTk, assetFrom);
        _applyDecay($, toTk, assetTo);

        uint256 withdrawValue = (lpAmount * (assetFrom.liquidityIndex == 0 ? INIT_LIQUIDITY_INDEX : assetFrom.liquidityIndex)) / C.WAD;
        uint256 amt;
        uint256 haircut;

        if (fromTk == toTk) {
            (amt, haircut) = _applyHaircut(withdrawValue, assetFrom.reserves, assetFrom.liabilities, assetFrom.haircutSuppressor);
            if (assetFrom.reserves < amt) revert Err.InsufficientAmount(assetFrom.reserves, amt);
            if (amt > type(uint128).max) revert Err.ExcessiveAmount(amt, type(uint128).max);

            uint256 liabRed = withdrawValue > assetFrom.liabilities ? assetFrom.liabilities : withdrawValue;
            assetFrom.reserves -= uint128(amt);
            assetFrom.liabilities -= uint128(liabRed);
        } else {
            IPool.SwapQuote memory q = _getQuote($, fromTk, toTk, withdrawValue);
            (amt, haircut) = _applyHaircut(q.amountOut, assetTo.reserves, assetTo.liabilities, assetTo.haircutSuppressor);
            if (assetTo.reserves < amt) revert Err.InsufficientAmount(assetTo.reserves, amt);

            uint256 liabRed = withdrawValue > assetFrom.liabilities ? assetFrom.liabilities : withdrawValue;
            assetFrom.liabilities -= uint128(liabRed);

            if (q.protoFee > 0) $.protocolFees[toTk] += q.protoFee;
            assetTo.reserves -= uint128(amt + q.protoFee);
        }

        $.lpBalances[msg.sender][fromTk] -= lpAmount;
        if (assetTo.reserves < assetTo.minLiquidity) {
            revert Err.ThresholdViolation(assetTo.reserves, assetTo.minLiquidity);
        }
        if (amt < minAmountOut) revert Err.ThresholdViolation(amt, minAmountOut);
        _push(tokenTo, msg.sender, amt);

        if (fromTk == toTk) {
            emit Withdrawn(msg.sender, fromTk, amt, lpAmount);
        } else {
            emit LiabilitySwapped(msg.sender, fromTk, toTk, lpAmount, 0, haircut);
            emit Withdrawn(msg.sender, toTk, amt, lpAmount);
        }
        return IPool.WithdrawResult({amountOut: amt, lpBurned: lpAmount});
    }

    function swapLiability(
        address tokenIn,
        address tokenOut,
        uint256 lpAmountIn,
        uint256 minLpAmountOut
    ) external nonReentrant whenInitialized returns (uint256 lpAmountOut) {
        if (lpAmountIn == 0) revert Err.ZeroValue();

        IPool.PoolStorage storage $ = _s();
        address inTk = _wrap($, tokenIn);
        address outTk = _wrap($, tokenOut);
        if (inTk == outTk) revert Err.InvalidInput();

        IPool.Asset storage assetIn = $.assets[inTk];
        IPool.Asset storage assetOut = $.assets[outTk];
        if (assetIn.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, inTk);
        if (assetOut.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, outTk);

        _applyDecay($, inTk, assetIn);
        _applyDecay($, outTk, assetOut);
        _checkRisk($, inTk, C.LIABILITY_SWAP_ENABLED_BIT);
        _checkRisk($, outTk, C.LIABILITY_SWAP_ENABLED_BIT);

        if ($.lpBalances[msg.sender][inTk] < lpAmountIn) {
            revert Err.InsufficientAmount($.lpBalances[msg.sender][inTk], lpAmountIn);
        }

        uint256 liabIn = (lpAmountIn * (assetIn.liquidityIndex == 0 ? INIT_LIQUIDITY_INDEX : assetIn.liquidityIndex)) / C.WAD;
        if (liabIn > assetIn.liabilities) revert Err.InsufficientAmount(assetIn.liabilities, liabIn);

        IPool.SwapQuote memory q = _getQuote($, inTk, outTk, liabIn);
        uint256 liabOut = q.amountOut;
        uint256 haircut;

        if (assetOut.reserves < assetOut.liabilities) {
            (liabOut, haircut) = _applyHaircut(liabOut, assetOut.reserves, assetOut.liabilities, assetOut.haircutSuppressor);
        }

        lpAmountOut = (liabOut * C.WAD) / (assetOut.liquidityIndex == 0 ? INIT_LIQUIDITY_INDEX : assetOut.liquidityIndex);

        assetIn.liabilities -= uint128(liabIn);
        assetOut.liabilities += uint128(liabOut);
        if (lpAmountOut < minLpAmountOut) revert Err.ThresholdViolation(lpAmountOut, minLpAmountOut);

        $.lpBalances[msg.sender][inTk] -= lpAmountIn;
        $.lpBalances[msg.sender][outTk] += lpAmountOut;

        emit LiabilitySwapped(msg.sender, inTk, outTk, lpAmountIn, lpAmountOut, haircut);
        return lpAmountOut;
    }

    /// @dev Quote via Exchange module registry (avoids LibPricing import here)
    function _getQuote(
        IPool.PoolStorage storage $,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) private returns (IExchange.SwapQuote memory) {
        address mod = $.modules[IExchangeQuote.getSwapQuote.selector];
        if (mod == address(0)) revert Err.InvalidState();
        (bool ok, bytes memory data) = mod.delegatecall(
            abi.encodeCall(IExchangeQuote.getSwapQuote, (tokenIn, tokenOut, amountIn))
        );
        if (!ok) { assembly { revert(add(data, 32), mload(data)) } }
        return abi.decode(data, (IExchange.SwapQuote));
    }

    /// @dev Linear haircut w/ suppression: deficit × (1 - suppression/20000), capped 100%.
    function _applyHaircut(
        uint256 amount,
        uint128 reserves,
        uint128 liabilities,
        uint16 suppression
    ) private pure returns (uint256 actualAmount, uint256 haircutAmount) {
        if (liabilities == 0 || reserves >= liabilities) return (amount, 0);

        uint256 deficit = ((uint256(liabilities) - uint256(reserves)) * 1e18) / uint256(liabilities);
        uint256 factor = suppression >= 20000 ? 0 : 1e18 - (uint256(suppression) * 1e18 / 20000);
        uint256 haircutRatio = (deficit * factor) / 1e18;
        if (haircutRatio > 1e18) haircutRatio = 1e18;
        haircutAmount = (amount * haircutRatio) / 1e18;
        actualAmount = amount - haircutAmount;
    }
}
