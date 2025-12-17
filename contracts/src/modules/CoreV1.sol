// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseV1} from "./BaseV1.sol";
import {InternalOracleV1} from "./InternalOracleV1.sol";
import {IErrors} from "../interfaces/IErrors.sol";
import {ICoreV1} from "../interfaces/modules/ICoreV1.sol";
import {IPoolV1} from "../interfaces/IPoolV1.sol";
import {IOracleV1} from "../interfaces/IOracleV1.sol";
import {IPoolHooks} from "../interfaces/IPoolHooks.sol";
import {IERC3156FlashBorrower} from "../interfaces/external/IERC3156FlashBorrower.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {LibPricing as Pricing} from "../libraries/LibPricing.sol";
import {LibBatchPricing as BatchPricing} from "../libraries/LibBatchPricing.sol";
import {LibOracle} from "../libraries/LibOracle.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";
import {LibTransientCache as TCache} from "../libraries/LibTransientCache.sol";

/// @title Core
/// @notice Core AMM operations: swap, deposit, withdraw, liability swap, donate
contract CoreV1 is BaseV1, ICoreV1 {
    using SafeTransferLib for address;
    using {M.b64To1e18} for uint64;


    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external payable override nonReentrant whenInitialized returns (uint256 amountOut) {
        IPoolV1.PoolStorage storage $ = _s();

        address tokenInNorm = _wrap($, tokenIn);
        address tokenOutNorm = _wrap($, tokenOut);

        if (tokenInNorm == tokenOutNorm) revert IErrors.InvalidInput();
        if (amountIn == 0) revert IErrors.ZeroValue();

        _checkRisk($, tokenInNorm, C.SWAP_ENABLED_BIT);
        _checkRisk($, tokenOutNorm, C.SWAP_ENABLED_BIT);

        IPoolV1.Asset storage assetIn = $.assets[tokenInNorm];
        IPoolV1.Asset storage assetOut = $.assets[tokenOutNorm];
        _applyDecay($, tokenInNorm, assetIn);
        _applyDecay($, tokenOutNorm, assetOut);

        uint256 actualIn = _pull(tokenIn, amountIn);

        // Route all swaps through anchor path pricing for correct anchor path logic
        IPoolV1.SwapQuote memory quote = Pricing.getAnchorPathQuote($, tokenInNorm, tokenOutNorm, actualIn);

        (uint256 extraFee, uint16 feeOverride) = _callSwapHookPre($, tokenInNorm, tokenOutNorm, actualIn, quote.amountOut);

        uint256 finalAmountOut = quote.amountOut;

        if (feeOverride > 0) {
            uint256 rawAmountOut = quote.amountOut + quote.protoFee + quote.lpFee;
            uint256 totalFee = (rawAmountOut * uint256(feeOverride)) / 1_000_000;
            (uint256 protoFee, uint256 lpFee) = Pricing.splitFee(totalFee, $.feeParams.protoShare);
            quote.spreadBps = feeOverride;
            quote.protoFee = protoFee;
            quote.lpFee = lpFee;
            quote.amountOut = rawAmountOut - totalFee;
            finalAmountOut = quote.amountOut;
        }

        finalAmountOut = _trackHookFee($, tokenOutNorm, extraFee, quote, finalAmountOut);

        _executeSwap($, tokenInNorm, tokenOutNorm, actualIn, quote);

        int256 hookDelta = _callSwapHookPost($, tokenInNorm, tokenOutNorm, actualIn, finalAmountOut);

        if (hookDelta > 0) {
            finalAmountOut = _trackHookFee($, tokenOutNorm, uint256(hookDelta), quote, finalAmountOut);
        } else if (hookDelta < 0) {
            finalAmountOut += uint256(-hookDelta);
        }

        _reconcileReserves(assetOut, finalAmountOut, quote.amountOut);

        // Check minLiquidity after reconciliation (hooks can affect reserves)
        if (assetOut.reserves < assetOut.minLiquidity) {
            revert IErrors.ThresholdViolation(assetOut.reserves, assetOut.minLiquidity);
        }

        // Oracle update AFTER all state finalized (prevents recording prices from invalid states)
        // Update the actual finalAmountOut in quote for accurate oracle prices
        quote.hopAmounts[quote.hopAmounts.length - 1] = finalAmountOut;
        _updateOracleFromSwap($, quote);

        if (finalAmountOut < minAmountOut) {
            revert IErrors.ThresholdViolation(finalAmountOut, minAmountOut);
        }

        _push(tokenOut, recipient, finalAmountOut);

        emit ICoreV1.Swapped(
            msg.sender,
            recipient,
            tokenInNorm,
            tokenOutNorm,
            actualIn,
            finalAmountOut,
            quote.spreadBps,
            quote.protoFee,
            quote.lpFee
        );

        return finalAmountOut;
    }

    function getSwapQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external override returns (IPoolV1.SwapQuote memory quote) {
        IPoolV1.PoolStorage storage $ = _s();
        address tokenInNorm = _wrap($, tokenIn);
        address tokenOutNorm = _wrap($, tokenOut);
        // Use same anchor-path pricing as swap() for consistency
        return Pricing.getAnchorPathQuote($, tokenInNorm, tokenOutNorm, amountIn);
    }

    /// @notice Quote batch swap: all inputs → base → weighted outputs
    /// @dev Both sells and buys use full anchor path traversal with price impact
    /// @param inputs Packed, 32 bytes each: [address(20) | uint64 amountB64(8) | reserved(4)]
    /// @param outputs Packed, 32 bytes each: [address(20) | uint16 weightBps(2) | uint16 slippageBps(2) | reserved(8)]
    /// @return quote Batch quote with expected outputs
    function quoteBatchSwap(
        bytes calldata inputs,
        bytes calldata outputs
    ) external returns (BatchPricing.BatchQuote memory quote) {
        return BatchPricing.quoteBatch(_s(), inputs, outputs);
    }

    /// @notice Execute batch swap: all inputs → base → weighted outputs
    /// @dev Single atomic operation - all swaps succeed or all fail
    /// @param inputs Packed, 32 bytes each: [address(20) | uint64 amountB64(8) | reserved(4)]
    /// @param outputs Packed, 32 bytes each: [address(20) | uint16 weightBps(2) | reserved(2) | uint64 minOutB64(8)]
    /// @param recipient Address to receive output tokens
    /// @return amountsOut Actual output amounts
    function batchSwap(
        bytes calldata inputs,
        bytes calldata outputs,
        address recipient
    ) external payable nonReentrant whenInitialized returns (uint256[] memory amountsOut) {
        IPoolV1.PoolStorage storage $ = _s();

        uint256 inLen = inputs.length / 32;
        uint256 outLen = outputs.length / 32;

        if (inputs.length % 32 != 0 || inLen == 0 || inLen > 8) revert IErrors.InvalidInput();
        if (outputs.length % 32 != 0 || outLen == 0 || outLen > 8) revert IErrors.InvalidInput();

        address base = $.baseToken;
        amountsOut = new uint256[](outLen);

        // ═══════════════════════════════════════════════════════════════════
        // PHASE 1: Pull all inputs and execute sells (input → base)
        // ═══════════════════════════════════════════════════════════════════

        uint256 totalBaseReceived;

        for (uint256 i; i < inLen;) {
            (address token, uint64 amountB64) = BatchPricing.unpackInput(inputs, i);
            token = _wrap($, token);

            IPoolV1.Asset storage asset = $.assets[token];
            if (asset.decimals == 0) revert IErrors.NotFound(IErrors.Resource.ASSET, token);

            uint256 amount = M.decodeB64(amountB64, asset.decimals);

            _checkRisk($, token, C.SWAP_ENABLED_BIT);
            _applyDecay($, token, asset);

            uint256 actualIn = _pull(token == $.wnative ? C.NATIVE : token, amount);

            if (token == base) {
                totalBaseReceived += actualIn;
            } else {
                IPoolV1.SwapQuote memory sellQuote = Pricing.getAnchorPathQuote($, token, base, actualIn);
                _executeSwap($, token, base, actualIn, sellQuote);
                _updateOracleFromSwap($, sellQuote);
                totalBaseReceived += sellQuote.amountOut;
            }

            unchecked { ++i; }
        }

        if (totalBaseReceived == 0) revert IErrors.ZeroValue();

        // ═══════════════════════════════════════════════════════════════════
        // PHASE 2: Execute buys (base → outputs) by weight, check slippage
        // ═══════════════════════════════════════════════════════════════════

        uint256 weightSum;

        for (uint256 j; j < outLen;) {
            (address token, uint16 weightBps, uint64 minOutB64) = BatchPricing.unpackSwapOutput(outputs, j);
            token = _wrap($, token);

            IPoolV1.Asset storage asset = $.assets[token];
            if (asset.decimals == 0) revert IErrors.NotFound(IErrors.Resource.ASSET, token);

            weightSum += weightBps;
            uint256 baseAmountIn = (totalBaseReceived * weightBps) / 10000;

            _checkRisk($, token, C.SWAP_ENABLED_BIT);
            _applyDecay($, token, asset);

            if (token == base) {
                amountsOut[j] = baseAmountIn;
            } else {
                IPoolV1.SwapQuote memory buyQuote = Pricing.getAnchorPathQuote($, base, token, baseAmountIn);
                _executeSwap($, base, token, baseAmountIn, buyQuote);
                _updateOracleFromSwap($, buyQuote);
                amountsOut[j] = buyQuote.amountOut;
            }

            // Decode minOut and check slippage
            uint256 minOut = M.decodeB64(minOutB64, asset.decimals);
            if (amountsOut[j] < minOut) {
                revert IErrors.ThresholdViolation(amountsOut[j], minOut);
            }

            unchecked { ++j; }
        }

        if (weightSum != 10000) revert IErrors.InvalidInput();

        // ═══════════════════════════════════════════════════════════════════
        // PHASE 3: Push all outputs to recipient
        // ═══════════════════════════════════════════════════════════════════

        for (uint256 j; j < outLen;) {
            (address token,,) = BatchPricing.unpackSwapOutput(outputs, j);
            token = _wrap($, token);
            _push(token == $.wnative ? C.NATIVE : token, recipient, amountsOut[j]);
            unchecked { ++j; }
        }

        emit BatchSwapped(msg.sender, recipient, inLen, outLen, totalBaseReceived);
    }

    function deposit(
        address token,
        uint256 amount
    ) external payable override nonReentrant whenInitialized returns (IPoolV1.DepositResult memory result) {
        if (amount == 0) revert IErrors.ZeroValue();

        IPoolV1.PoolStorage storage $ = _s();
        address tokenNorm = _wrap($, token);
        IPoolV1.Asset storage asset = _asset($, tokenNorm);

        _applyDecay($, tokenNorm, asset);

        if (($.riskConfigs[tokenNorm].flags & C.FROZEN_BIT) != 0) {
            revert IErrors.FeatureDisabled(IErrors.Resource.ASSET);
        }

        address hook = _hook($, tokenNorm, C.HOOK_PRE_DEPOSIT);
        if (hook != address(0)) {
            IPoolHooks(hook).preDeposit(address(this), msg.sender, tokenNorm, amount);
        }

        uint256 actualDeposit = _pull(token, amount);
        uint256 lpAmount = (actualDeposit * M.PRECISION) / _getAssetIndex(asset);

        // Check uint128 bounds before casting
        if (actualDeposit > type(uint128).max) revert IErrors.ExcessiveAmount(actualDeposit, type(uint128).max);

        asset.reserves += uint128(actualDeposit);
        asset.liabilities += uint128(actualDeposit);

        uint256 finalLpAmount = lpAmount;
        hook = _hook($, tokenNorm, C.HOOK_POST_DEPOSIT);
        if (hook != address(0)) {
            (uint256 hookFeeOut, uint256 hookIncentiveOut) = IPoolHooks(hook).postDeposit(
                address(this), msg.sender, tokenNorm, actualDeposit, lpAmount
            );
            finalLpAmount = lpAmount + hookIncentiveOut - hookFeeOut;
        }

        $.lpBalances[msg.sender][tokenNorm] += finalLpAmount;

        // Record deposit time for flow guard (JIT protection)
        _recordDeposit(msg.sender, tokenNorm);

        emit ICoreV1.Deposited(msg.sender, tokenNorm, actualDeposit, finalLpAmount);

        return IPoolV1.DepositResult({lpAmount: finalLpAmount, actualDeposit: actualDeposit});
    }

    function withdraw(
        address token,
        uint256 lpAmount,
        uint256 minAmountOut
    ) external override nonReentrant whenInitialized returns (IPoolV1.WithdrawResult memory result) {
        // Direct withdrawal to same asset
        return _withdrawTo(token, token, lpAmount, minAmountOut);
    }

    function withdrawTo(
        address tokenFrom,
        address tokenTo,
        uint256 lpAmount,
        uint256 minAmountOut
    ) public override nonReentrant whenInitialized returns (IPoolV1.WithdrawResult memory result) {
        return _withdrawTo(tokenFrom, tokenTo, lpAmount, minAmountOut);
    }

    function _withdrawTo(
        address tokenFrom,
        address tokenTo,
        uint256 lpAmount,
        uint256 minAmountOut
    ) private returns (IPoolV1.WithdrawResult memory result) {
        if (lpAmount == 0) revert IErrors.ZeroValue();

        IPoolV1.PoolStorage storage $ = _s();
        address tokenFromNorm = _wrap($, tokenFrom);
        address tokenToNorm = _wrap($, tokenTo);

        // Check flow guard cooldown (JIT protection)
        _checkWithdrawCooldown(msg.sender, tokenFromNorm);

        // Validate LP balance
        if ($.lpBalances[msg.sender][tokenFromNorm] < lpAmount) {
            revert IErrors.InsufficientAmount($.lpBalances[msg.sender][tokenFromNorm], lpAmount);
        }

        IPoolV1.Asset storage assetFrom = _asset($, tokenFromNorm);
        IPoolV1.Asset storage assetTo = _asset($, tokenToNorm);

        _applyDecay($, tokenFromNorm, assetFrom);
        _applyDecay($, tokenToNorm, assetTo);

        // Pre-withdraw hook for source token
        address hook = _hook($, tokenFromNorm, C.HOOK_PRE_WITHDRAW);
        if (hook != address(0)) {
            IPoolHooks(hook).preWithdraw(address(this), msg.sender, tokenFromNorm, lpAmount);
        }

        // Calculate withdrawal value in source token units
        uint256 withdrawValue = (lpAmount * _getAssetIndex(assetFrom)) / M.PRECISION;
        uint256 finalAmount;
        uint256 haircutAmount;

        if (tokenFromNorm == tokenToNorm) {
            // Same-asset withdrawal: apply quadratic haircut directly
            (finalAmount, haircutAmount) = Pricing.applyWithdrawalHaircut(
                withdrawValue,
                assetFrom.reserves,
                assetFrom.liabilities,
                assetFrom.haircutSuppressor
            );

            if (assetFrom.reserves < finalAmount) {
                revert IErrors.InsufficientAmount(assetFrom.reserves, finalAmount);
            }

            // Update state
            uint256 liabReduction = withdrawValue > assetFrom.liabilities ? assetFrom.liabilities : withdrawValue;

            // Check uint128 bounds
            if (finalAmount > type(uint128).max) revert IErrors.ExcessiveAmount(finalAmount, type(uint128).max);
            if (liabReduction > type(uint128).max) revert IErrors.ExcessiveAmount(liabReduction, type(uint128).max);

            assetFrom.reserves -= uint128(finalAmount);
            assetFrom.liabilities -= uint128(liabReduction);
        } else {
            // Cross-asset withdrawal: atomic swap + withdraw
            // 1. Get swap quote for the withdrawal value
            IPoolV1.SwapQuote memory quote = Pricing.getAnchorPathQuote($, tokenFromNorm, tokenToNorm, withdrawValue);

            // 2. Apply quadratic haircut on destination asset (use net amount after fees)
            // Important: haircut applies to what user would receive, not gross swap output
            (finalAmount, haircutAmount) = Pricing.applyWithdrawalHaircut(
                quote.amountOut,  // This is already net of swap fees
                assetTo.reserves,
                assetTo.liabilities,
                assetTo.haircutSuppressor
            );

            if (assetTo.reserves < finalAmount) {
                revert IErrors.InsufficientAmount(assetTo.reserves, finalAmount);
            }

            // 3. Update state atomically
            // Reduce source liabilities
            uint256 liabReduction = withdrawValue > assetFrom.liabilities ? assetFrom.liabilities : withdrawValue;
            if (liabReduction > type(uint128).max) revert IErrors.ExcessiveAmount(liabReduction, type(uint128).max);
            assetFrom.liabilities -= uint128(liabReduction);

            // Account for protocol fees from the swap
            if (quote.protoFee > 0) {
                $.protocolFees[tokenToNorm] += quote.protoFee;
            }

            // Reduce destination reserves (no liability change on destination)
            // Note: finalAmount + protoFee should be deducted from reserves
            uint256 totalReduction = finalAmount + quote.protoFee;
            if (totalReduction > type(uint128).max) revert IErrors.ExcessiveAmount(totalReduction, type(uint128).max);
            assetTo.reserves -= uint128(totalReduction);
        }

        // Update LP balance
        $.lpBalances[msg.sender][tokenFromNorm] -= lpAmount;

        // Check minimum liquidity
        if (assetTo.reserves < assetTo.minLiquidity) {
            revert IErrors.ThresholdViolation(assetTo.reserves, assetTo.minLiquidity);
        }

        // Post-withdraw hook for destination token
        hook = _hook($, tokenToNorm, C.HOOK_POST_WITHDRAW);
        if (hook != address(0)) {
            (uint256 exitFee, uint256 incentiveOut) = IPoolHooks(hook).postWithdraw(
                address(this), msg.sender, tokenToNorm, finalAmount, lpAmount
            );
            if (exitFee > finalAmount) revert IErrors.OperationFailed();
            finalAmount = finalAmount + incentiveOut - exitFee;
        }

        _reconcileReserves(assetTo, finalAmount, finalAmount);

        // Final checks
        if (assetTo.reserves < assetTo.minLiquidity) {
            revert IErrors.ThresholdViolation(assetTo.reserves, assetTo.minLiquidity);
        }

        if (finalAmount < minAmountOut) {
            revert IErrors.ThresholdViolation(finalAmount, minAmountOut);
        }

        // Transfer tokens
        _push(tokenTo, msg.sender, finalAmount);

        // Emit appropriate event
        if (tokenFromNorm == tokenToNorm) {
            emit ICoreV1.Withdrawn(msg.sender, tokenFromNorm, finalAmount, lpAmount);
        } else {
            // For cross-asset, emit both the liability swap and withdrawal
            emit ICoreV1.LiabilitySwapped(msg.sender, tokenFromNorm, tokenToNorm, lpAmount, 0, haircutAmount);
            emit ICoreV1.Withdrawn(msg.sender, tokenToNorm, finalAmount, lpAmount);
        }

        return IPoolV1.WithdrawResult({amountOut: finalAmount, lpBurned: lpAmount});
    }

    function swapLiability(
        address tokenIn,
        address tokenOut,
        uint256 lpAmountIn,
        uint256 minLpAmountOut
    ) external override nonReentrant whenInitialized returns (uint256 lpAmountOut) {
        if (lpAmountIn == 0) revert IErrors.ZeroValue();

        IPoolV1.PoolStorage storage $ = _s();
        address tokenInNorm = _wrap($, tokenIn);
        address tokenOutNorm = _wrap($, tokenOut);

        if (tokenInNorm == tokenOutNorm) revert IErrors.InvalidInput();

        IPoolV1.Asset storage assetIn = $.assets[tokenInNorm];
        IPoolV1.Asset storage assetOut = $.assets[tokenOutNorm];

        if (assetIn.decimals == 0) revert IErrors.NotFound(IErrors.Resource.ASSET, tokenInNorm);
        if (assetOut.decimals == 0) revert IErrors.NotFound(IErrors.Resource.ASSET, tokenOutNorm);

        _applyDecay($, tokenInNorm, assetIn);
        _applyDecay($, tokenOutNorm, assetOut);

        _checkRisk($, tokenInNorm, C.LIABILITY_SWAP_ENABLED_BIT);
        _checkRisk($, tokenOutNorm, C.LIABILITY_SWAP_ENABLED_BIT);

        if ($.lpBalances[msg.sender][tokenInNorm] < lpAmountIn) {
            revert IErrors.InsufficientAmount($.lpBalances[msg.sender][tokenInNorm], lpAmountIn);
        }

        // Calculate liability value to swap
        uint256 liabValueIn = (lpAmountIn * _getAssetIndex(assetIn)) / M.PRECISION;

        // Prevent underflow
        if (liabValueIn > assetIn.liabilities) {
            revert IErrors.InsufficientAmount(assetIn.liabilities, liabValueIn);
        }

        // Get swap quote using standard pricing (inventory skew already accounts for coverage)
        IPoolV1.SwapQuote memory quote = Pricing.getAnchorPathQuote($, tokenInNorm, tokenOutNorm, liabValueIn);

        uint256 liabValueOut = quote.amountOut;
        uint256 haircutAmount;

        // Apply haircut if destination asset is undercollateralized
        // This prevents users from bypassing withdrawal penalties
        if (assetOut.reserves < assetOut.liabilities) {
            (liabValueOut, haircutAmount) = Pricing.applyWithdrawalHaircut(
                liabValueOut,
                assetOut.reserves,
                assetOut.liabilities,
                assetOut.haircutSuppressor
            );
        }

        // Convert output to LP tokens after haircut
        lpAmountOut = (liabValueOut * M.PRECISION) / _getAssetIndex(assetOut);

        // Check uint128 bounds
        if (liabValueOut > type(uint128).max) revert IErrors.ExcessiveAmount(liabValueOut, type(uint128).max);

        // Update liabilities only (no reserve changes in pure liability swap)
        assetIn.liabilities -= uint128(liabValueIn);
        assetOut.liabilities += uint128(liabValueOut);

        // Check slippage
        if (lpAmountOut < minLpAmountOut) revert IErrors.ThresholdViolation(lpAmountOut, minLpAmountOut);

        // Update LP balances
        $.lpBalances[msg.sender][tokenInNorm] -= lpAmountIn;
        $.lpBalances[msg.sender][tokenOutNorm] += lpAmountOut;

        // Note: Haircut applied if destination is undercollateralized
        emit ICoreV1.LiabilitySwapped(msg.sender, tokenInNorm, tokenOutNorm, lpAmountIn, lpAmountOut, haircutAmount);
        return lpAmountOut;
    }

    function donate(address token, uint256 amount) external payable override nonReentrant whenInitialized {
        if (amount == 0) revert IErrors.ZeroValue();

        IPoolV1.PoolStorage storage $ = _s();
        address tokenNorm = _wrap($, token);
        IPoolV1.Asset storage asset = _asset($, tokenNorm);

        _applyDecay($, tokenNorm, asset);
        _checkRisk($, tokenNorm, 0);

        // Note: We allow donations even if reserves < minLiquidity
        // This allows emergency recapitalization of underfunded pools

        uint256 actual = _pull(token, amount);

        address hook = _hook($, tokenNorm, C.HOOK_PRE_DONATE);
        if (hook != address(0)) {
            IPoolHooks(hook).preDonate(address(this), msg.sender, tokenNorm, actual);
        }

        // Check uint128 bounds before casting
        if (actual > type(uint128).max) revert IErrors.ExcessiveAmount(actual, type(uint128).max);

        uint256 liabBefore = uint256(asset.liabilities);
        asset.reserves += uint128(actual);
        asset.liabilities += uint128(actual);

        uint256 oldIdx = asset.liquidityIndex == 0 ? M.INDEX_PRECISION : asset.liquidityIndex;
        uint256 newIdx = liabBefore == 0 ? oldIdx : (oldIdx * (liabBefore + actual)) / liabBefore;
        asset.liquidityIndex = uint64(newIdx);

        hook = _hook($, tokenNorm, C.HOOK_POST_DONATE);
        if (hook != address(0)) {
            IPoolHooks(hook).postDonate(address(this), msg.sender, tokenNorm, actual);
        }

        emit ICoreV1.Donated(msg.sender, token, actual);
    }

    // ========== VIEW FUNCTIONS ==========

    function owner() external view returns (address) {
        return _s().owner;
    }

    function baseToken() external view returns (address) {
        return _s().baseToken;
    }

    function wnative() external view returns (address) {
        return _s().wnative;
    }

    function getAsset(address token) external view returns (IPoolV1.Asset memory) {
        IPoolV1.PoolStorage storage $ = _s();
        return $.assets[_wrap($, token)];
    }

    function getFeedConfig(address token) external view returns (IPoolV1.OracleConfig memory) {
        IPoolV1.PoolStorage storage $ = _s();
        return $.oracleConfigs[_wrap($, token)];
    }

    function getRiskConfig(address token) external view returns (IPoolV1.RiskConfig memory) {
        IPoolV1.PoolStorage storage $ = _s();
        return $.riskConfigs[_wrap($, token)];
    }

    function getLiquidityProfile(address token) external view returns (IPoolV1.LiquidityProfile memory) {
        IPoolV1.PoolStorage storage $ = _s();
        return $.profiles[_wrap($, token)];
    }

    function getLPBalance(address user, address token) external view returns (uint256) {
        IPoolV1.PoolStorage storage $ = _s();
        return $.lpBalances[user][_wrap($, token)];
    }

    function getProtocolFees(address token) external view returns (uint256) {
        IPoolV1.PoolStorage storage $ = _s();
        return $.protocolFees[_wrap($, token)];
    }

    function getCoverageRatio(address token) external view returns (uint256) {
        IPoolV1.PoolStorage storage $ = _s();
        address tokenNorm = _wrap($, token);
        IPoolV1.Asset memory asset = $.assets[tokenNorm];
        return Pricing.calculateCoverage(asset.reserves, asset.liabilities);
    }

    function getMidPrice(address token) external returns (uint256 midPrice) {
        IPoolV1.PoolStorage storage $ = _s();
        address tokenNorm = _wrap($, token);

        IPoolV1.Asset memory asset = $.assets[tokenNorm];
        IOracleV1.FeedData memory feed = _readOracle($, tokenNorm);
        (uint256 twap,) = LibOracle.decodeB64s(feed);

        int8 inventorySkew = Pricing.computeInventorySkew(
            asset.reserves,
            asset.liabilities,
            $.riskConfigs[tokenNorm].coverageFloor,
            asset.gamma
        );

        // Get volatility σ and compute dispersion
        uint32 sigma = LibOracle.getSigma(feed);
        uint32 dispersion = Pricing._calculateDispersion(sigma, asset.vega, asset.minDispersion, asset.maxDispersion);
        return Pricing._getMidPriceFromProfile(twap, inventorySkew, dispersion, $.profiles[tokenNorm]);
    }

    // ========== INTERNAL HELPERS ==========
    // Note: _getSwapQuote and _getAnchorPathSwapQuote removed - use Pricing.getAnchorPathQuote directly

    function _executeSwap(
        IPoolV1.PoolStorage storage $,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        IPoolV1.SwapQuote memory quote
    ) private {
        IPoolV1.Asset storage assetIn = $.assets[tokenIn];
        IPoolV1.Asset storage assetOut = $.assets[tokenOut];

        // 50/50 fee split: half from input, half from output
        // This ensures symmetrical LP earnings in both tokens
        uint256 halfSpread = uint256(quote.spreadBps) / 2;
        uint256 feeIn = (amountIn * halfSpread) / 1_000_000;

        // Check uint128 bounds before casting
        if (amountIn > type(uint128).max) revert IErrors.ExcessiveAmount(amountIn, type(uint128).max);
        if (feeIn > type(uint128).max) revert IErrors.ExcessiveAmount(feeIn, type(uint128).max);
        uint256 totalOut = quote.amountOut + quote.protoFee + quote.lpFee;
        if (totalOut > type(uint128).max) revert IErrors.ExcessiveAmount(totalOut, type(uint128).max);

        // Check output reserves BEFORE subtraction to prevent underflow
        uint256 minRequired = quote.amountOut + assetOut.minLiquidity;
        if (assetOut.reserves < minRequired) {
            revert IErrors.InsufficientAmount(assetOut.reserves, minRequired);
        }

        // Update reserves with 50/50 fee split
        // Input: add net amount (fee stays out to become LP earnings)
        // Output: subtract net amount (fee retention improves coverage)
        assetIn.reserves += uint128(amountIn - feeIn);
        assetOut.reserves -= uint128(quote.amountOut);
        $.protocolFees[tokenOut] += quote.protoFee;

        // Check reservation price floor for output asset
        // Ensures swap doesn't crash the price below configured minimum
        _checkReservationPrice($, tokenOut, assetOut);

        // Oracle update moved to swap() after all state finalization
    }

    /// @notice Check that asset price is above reservation floor
    /// @dev Uses oracle mid-price vs anchor; reverts if below floor
    function _checkReservationPrice(
        IPoolV1.PoolStorage storage $,
        address token,
        IPoolV1.Asset storage asset
    ) private {
        uint64 reservationPrice = asset.reservationPrice;
        if (reservationPrice == 0) return; // No floor configured

        // Get current mid-price from oracle (vs anchor)
        IOracleV1.FeedData memory feed = _readOracle($, token);
        if (feed.lastPriceB64 < reservationPrice) {
            revert IErrors.PriceBelowReservation(feed.lastPriceB64, reservationPrice);
        }
    }

    /// @notice Calculate execution prices and update internal oracle for all hops in path
    /// @dev Computes implied prices from swap execution at each hop and pushes to oracle
    function _updateOracleFromSwap(
        IPoolV1.PoolStorage storage $,
        IPoolV1.SwapQuote memory quote
    ) private {
        // Skip if no routing path data (shouldn't happen but safety check)
        if (quote.routeHops.length == 0 || quote.hopAmounts.length == 0) {
            return;
        }

        // Update oracle for each hop in the routing path
        for (uint256 i = 0; i < quote.routeHops.length - 1; i++) {
            address tokenA = quote.routeHops[i];
            address tokenB = quote.routeHops[i + 1];
            uint256 amountIn = quote.hopAmounts[i];
            uint256 amountOut = quote.hopAmounts[i + 1];

            // Skip if amounts are zero (shouldn't happen)
            if (amountIn == 0 || amountOut == 0) continue;

            // Calculate implied price for this hop
            uint64 impliedPrice = _calculateImpliedPrice($, amountIn, amountOut, tokenB, tokenA);

            // Push price update to internal oracle
            // For direct hops to/from base, only update the non-base token
            // For triangulated hops, update both directions
            address base = $.baseToken;
            if (tokenA == base) {
                // Direct: tokenB priced in base
                InternalOracleV1(address(this)).pushFeedInternal(tokenB, address(0), impliedPrice, 0);
            } else if (tokenB == base) {
                // Inverse: tokenA priced in base
                InternalOracleV1(address(this)).pushFeedInternal(tokenA, address(0), impliedPrice, 0);
            } else {
                // Triangulated hop: update both token prices relative to their anchors
                // Calculate both prices from the execution data
                uint64 priceA = _calculateImpliedPrice($, amountIn, amountOut, tokenA, tokenB);
                uint64 priceB = _calculateImpliedPrice($, amountOut, amountIn, tokenB, tokenA);

                InternalOracleV1(address(this)).pushFeedInternal(tokenA, tokenB, priceA, priceB);
            }
        }
    }

    /// @notice Calculate implied price from swap amounts
    /// @param $ Pool storage
    /// @param amountIn Amount of input token
    /// @param amountOut Amount of output token
    /// @param tokenOut The output token
    /// @param tokenIn The input token
    /// @return Implied price in b64 format (price of tokenOut in terms of tokenIn)
    function _calculateImpliedPrice(
        IPoolV1.PoolStorage storage $,
        uint256 amountIn,
        uint256 amountOut,
        address tokenOut,
        address tokenIn
    ) private view returns (uint64) {
        // Price = amountIn / amountOut (adjusted for decimals)
        // This gives price of tokenOut in terms of tokenIn
        uint8 decimalsIn = $.assets[tokenIn].decimals;
        uint8 decimalsOut = $.assets[tokenOut].decimals;

        // Normalize both amounts to 18 decimal base for accurate price calculation
        // This avoids precision loss when dividing tokens with different decimals
        uint256 normalizedIn = amountIn * (10 ** uint256(18 - decimalsIn));
        uint256 normalizedOut = amountOut * (10 ** uint256(18 - decimalsOut));

        // Price in 18 decimal precision (price of 1 tokenOut in tokenIn)
        // Use extra precision then scale down
        uint256 price18 = (normalizedIn * 1e18) / normalizedOut;

        // Convert to output token's decimal base for B64 encoding
        uint256 price = price18 / (10 ** uint256(18 - decimalsOut));

        // Ensure non-zero price (shouldn't happen with valid swaps)
        if (price == 0) price = 1;

        return M.encodeB64(price, decimalsOut);
    }

    // Note: _checkCoverageImprovement removed - use Pricing.netCoverageImpact directly

    function _callSwapHookPre(
        IPoolV1.PoolStorage storage $,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    ) private returns (uint256 totalExtraFee, uint16 feeOverride) {
        address hookIn = $.hooks[tokenIn];
        address hookOut = $.hooks[tokenOut];

        if (hookIn != address(0) && ($.hookFlags[tokenIn] & C.HOOK_PRE_SWAP) != 0) {
            (uint256 extraFee, uint16 newFee) = IPoolHooks(hookIn).preSwap(
                address(this), msg.sender, tokenIn, tokenOut, amountIn, amountOut
            );
            totalExtraFee += extraFee;
            if (newFee > 0) feeOverride = newFee;
        }
        if (hookOut != address(0) && hookOut != hookIn && ($.hookFlags[tokenOut] & C.HOOK_PRE_SWAP) != 0) {
            (uint256 extraFee, uint16 newFee) = IPoolHooks(hookOut).preSwap(
                address(this), msg.sender, tokenIn, tokenOut, amountIn, amountOut
            );
            totalExtraFee += extraFee;
            if (newFee > 0) feeOverride = newFee;
        }
    }

    function _callSwapHookPost(
        IPoolV1.PoolStorage storage $,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    ) private returns (int256 totalDelta) {
        address hookIn = $.hooks[tokenIn];
        address hookOut = $.hooks[tokenOut];

        if (hookIn != address(0) && ($.hookFlags[tokenIn] & C.HOOK_POST_SWAP) != 0) {
            int256 delta = IPoolHooks(hookIn).postSwap(
                address(this), msg.sender, tokenIn, tokenOut, amountIn, amountOut
            );
            totalDelta += delta;
        }
        if (hookOut != address(0) && hookOut != hookIn && ($.hookFlags[tokenOut] & C.HOOK_POST_SWAP) != 0) {
            int256 delta = IPoolHooks(hookOut).postSwap(
                address(this), msg.sender, tokenIn, tokenOut, amountIn, amountOut
            );
            totalDelta += delta;
        }
    }

    function _trackHookFee(
        IPoolV1.PoolStorage storage $,
        address token,
        uint256 fee,
        IPoolV1.SwapQuote memory quote,
        uint256 amountOut
    ) private view returns (uint256) {
        if (fee == 0) return amountOut;

        (uint256 protoFee, uint256 lpFee) = Pricing.splitFee(fee, $.feeParams.protoShare);
        quote.protoFee += protoFee;
        quote.lpFee += lpFee;

        return amountOut > fee ? amountOut - fee : 0;
    }

    function _reconcileReserves(IPoolV1.Asset storage asset, uint256 finalAmount, uint256 expectedAmount) internal {
        if (finalAmount != expectedAmount) {
            uint256 delta = finalAmount > expectedAmount
                ? finalAmount - expectedAmount
                : expectedAmount - finalAmount;

            // Check uint128 bounds before casting
            if (delta > type(uint128).max) revert IErrors.ExcessiveAmount(delta, type(uint128).max);

            if (finalAmount > expectedAmount) {
                asset.reserves -= uint128(delta);
            } else {
                asset.reserves += uint128(delta);
            }
        }
    }

    function _getAssetIndex(IPoolV1.Asset storage asset) internal view returns (uint256) {
        return asset.liquidityIndex == 0 ? M.INDEX_PRECISION : asset.liquidityIndex;
    }

    // Note: _synthesizeBaseFeed moved to LibOracle.getBaseFeed() for reuse
    // Note: _getAnchorPathSwapQuote inlined - call Pricing.getAnchorPathQuote directly

}
