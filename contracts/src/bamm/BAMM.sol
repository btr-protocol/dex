// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1155} from "solady/tokens/ERC1155.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FPMaths as FPMath} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {LibStorage as S} from "../libraries/LibStorage.sol";
import {LibPricing as P} from "../libraries/LibPricing.sol";
import {LibMakimaPricing as MakimaP} from "../libraries/LibMakimaPricing.sol";
import {LibLiquiditySegments as SegLib} from "../libraries/LibLiquiditySegments.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";
import {LibUtils} from "../libraries/LibUtils.sol";
import {LibNativeToken} from "../libraries/LibNativeToken.sol";
import {LibLiability} from "../libraries/LibLiability.sol";
import {IBAMM} from "../interfaces/IBAMM.sol";
import {IBAMMHooks} from "../interfaces/IBAMMHooks.sol";
import {IInternalOracle} from "../interfaces/IInternalOracle.sol";
import {InternalOracle} from "./InternalOracle.sol";
import {BAMMManagement} from "./BAMMManagement.sol";
import {BAMMStorage} from "./BAMMStorage.sol";
import {BAMMFlashLender} from "./BAMMFlashLender.sol";
import {BAMMErrors as E} from "./BAMMErrors.sol";

/// @title BAMM - Bonding AMM with ALM and unified routing
contract BAMM is ERC1155, InternalOracle, BAMMManagement, BAMMFlashLender {
    using SafeTransferLib for address;
    using SafeCastLib for uint256;

    // ========== INTERNAL STRUCTS ==========

    struct TokenDelta {
        address token;
        int256 reserveDelta;
        uint256 lpFees;
        uint256 protocolFees;
    }

    // ========== MODIFIERS ==========

    modifier notFrozen(address token) {
        RiskConfig storage risk = _sb().riskConfigs[token];
        if (S._isFrozen(risk)) revert E.AssetFrozen();
        _;
    }

    // ========== STORAGE ACCESS OVERRIDES ==========

    /// @notice Flash lender storage accessor
    function _sf() internal pure override returns (IBAMM.BAMMStorage storage) {
        return S.bamm();
    }

    /// @notice Flash lender asset accessor
    function _getAssetFlash(address token) internal view override returns (IBAMM.Asset storage) {
        return S.bamm().assets[token];
    }

    // ========== PAUSABLE OVERRIDES ==========

    // Override conflicts from multiple inheritance
    function _requireNotPaused() internal view override(BAMMManagement) {
        if (_getPaused()) revert E.PoolPaused();
    }

    function _isPaused() internal view override returns (bool) {
        return _getPaused();
    }

    // Helper to compute feedId (since not stored in Asset)
    function _feedId(address token) private view returns (bytes32) {
        return S.computeOracleId(token, _sb().baseToken);
    }

    // ========== MAIN SWAP FUNCTION ==========

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) external payable override nonReentrant whenNotPaused returns (uint256 amountOut) {
        // Input validation (4 locals max)
        if (tokenIn == tokenOut) revert E.InvalidParameter();
        if (amountIn == 0) revert E.ZeroAmount();
        LibUtils.requireNonZero(receiver);

        // Storage access (1 pointer)
        IBAMM.BAMMStorage storage $ = _sb();

        // Blacklist check
        if ($.blacklisted[msg.sender] || $.blacklisted[receiver]) revert E.Blacklisted();

        // Derive base and branch (1 local)
        address base = $.baseToken;

        // Dispatch to specialized handlers (isolated stack frames)
        if (tokenIn != base && tokenOut != base) {
            amountOut = _swapTriangulated($, tokenIn, tokenOut, base, amountIn, receiver);
        } else {
            amountOut = _swapDirect($, tokenIn, tokenOut, base, amountIn, receiver);
        }

        // Slippage enforcement
        if (amountOut < minAmountOut) revert E.SlippageExceeded();
    }

    // ========== SWAP HELPERS (STACK-OPTIMIZED) ==========

    function _swapDirect(
        IBAMM.BAMMStorage storage $,
        address tokenIn,
        address tokenOut,
        address base,
        uint256 amountIn,
        address receiver
    ) private returns (uint256 amountOut) {
        // Asset fetching (2 storage pointers)
        Asset storage assetIn = $.assets[tokenIn];
        Asset storage assetOut = $.assets[tokenOut];

        // Reserve checks
        if (assetIn.reserves == 0 || assetOut.reserves == 0) revert E.InsufficientReserves();

        // Decay updates
        LibLiability.updateDecay(tokenIn);
        LibLiability.updateDecay(tokenOut);

        // Inline feed ID computation (avoids hidden _sb() calls in _feedId helper)
        bytes32 feedIn = S.computeOracleId(tokenIn, base);
        bytes32 feedOut = S.computeOracleId(tokenOut, base);
        bytes32 feedBase = S.computeOracleId(base, base);

        // Oracle fetching (scoped to minimize liveness)
        IInternalOracle.InternalFeedData storage oracleIn = $.internalFeeds[feedIn];
        IInternalOracle.InternalFeedData storage oracleOut = $.internalFeeds[feedOut];
        IInternalOracle.InternalFeedData storage oracleBase = $.internalFeeds[feedBase];

        // Oracle validation (storage refs can be dropped after)
        _checkOracleOrFallback(oracleIn, tokenIn);
        _checkOracleOrFallback(oracleOut, tokenOut);
        _checkOracleOrFallback(oracleBase, base);

        // Circuit breakers
        _checkCircuitBreaker(oracleIn, $.riskConfigs[tokenIn]);
        _checkCircuitBreaker(oracleOut, $.riskConfigs[tokenOut]);
        _checkCircuitBreaker(oracleBase, $.riskConfigs[base]);

        // Fetch base asset AFTER oracle checks (reduces concurrent live storage pointers)
        Asset storage assetBase = $.assets[base];

        // Route quote (single memory struct)
        P.RouteQuote memory rq = P.quoteRoute(
            tokenIn, tokenOut, base, amountIn,
            assetIn, assetOut, assetBase,
            $.liquidityProfiles[tokenIn], $.liquidityProfiles[tokenOut], $.liquidityProfiles[base],
            oracleIn, oracleOut, oracleBase,
            $.dynamicFeeConfigs[tokenIn]
        );

        amountOut = rq.amountOut;

        // Execute (delegates to existing implementation)
        _executeDirectSwap($, tokenIn, tokenOut, amountIn, rq, receiver);
    }

    function _swapTriangulated(
        IBAMM.BAMMStorage storage $,
        address tokenIn,
        address tokenOut,
        address base,
        uint256 amountIn,
        address receiver
    ) private returns (uint256 amountOut) {
        // Asset fetching
        Asset storage assetIn = $.assets[tokenIn];
        Asset storage assetOut = $.assets[tokenOut];

        if (assetIn.reserves == 0 || assetOut.reserves == 0) revert E.InsufficientReserves();

        // Decay for all three assets (base is virtual but still needs decay)
        LibLiability.updateDecay(tokenIn);
        LibLiability.updateDecay(tokenOut);
        LibLiability.updateDecay(base);

        // Inline feed ID computation
        bytes32 feedIn = S.computeOracleId(tokenIn, base);
        bytes32 feedOut = S.computeOracleId(tokenOut, base);
        bytes32 feedBase = S.computeOracleId(base, base);

        // Oracle fetching
        IInternalOracle.InternalFeedData storage oracleIn = $.internalFeeds[feedIn];
        IInternalOracle.InternalFeedData storage oracleOut = $.internalFeeds[feedOut];
        IInternalOracle.InternalFeedData storage oracleBase = $.internalFeeds[feedBase];

        // Oracle validation
        _checkOracleOrFallback(oracleIn, tokenIn);
        _checkOracleOrFallback(oracleOut, tokenOut);
        _checkOracleOrFallback(oracleBase, base);

        // Circuit breakers for all three assets
        _checkCircuitBreaker(oracleIn, $.riskConfigs[tokenIn]);
        _checkCircuitBreaker(oracleOut, $.riskConfigs[tokenOut]);
        _checkCircuitBreaker(oracleBase, $.riskConfigs[base]);

        // Fetch base asset after validation (scoped liveness)
        Asset storage assetBase = $.assets[base];

        // Route quote
        P.RouteQuote memory rq = P.quoteRoute(
            tokenIn, tokenOut, base, amountIn,
            assetIn, assetOut, assetBase,
            $.liquidityProfiles[tokenIn], $.liquidityProfiles[tokenOut], $.liquidityProfiles[base],
            oracleIn, oracleOut, oracleBase,
            $.dynamicFeeConfigs[tokenIn]
        );

        amountOut = rq.amountOut;

        _executeTriangulatedSwap($, tokenIn, tokenOut, base, amountIn, rq, receiver);
    }

    // ========== EXECUTION HELPERS ==========

    function _executeDirectSwap(
        IBAMM.BAMMStorage storage $,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        P.RouteQuote memory rq,
        address receiver
    ) private {
        Asset storage assetIn = $.assets[tokenIn];
        Asset storage assetOut = $.assets[tokenOut];

        // Check reserves
        if (rq.amountOut > assetOut.reserves) revert E.InsufficientReserves();
        if (assetOut.reserves - rq.amountOut < $.riskConfigs[tokenOut].minLiquidity) revert E.BelowMinimumLiquidity();

        // Split LP fees by liabilities
        (uint256 feeForInputLPs, uint256 feeForOutputLPs) = _splitLpFee(
            rq.lpFeeIn, assetIn.liabilities, assetOut.liabilities
        );

        // Convert output LP fee to tokenOut units
        uint256 feeForOutputLPsInOut = 0;
        if (feeForOutputLPs > 0) {
            uint256 priceFastIn = P.getFastPrice($.internalFeeds[_feedId(tokenIn)]);
            uint256 priceFastOut = P.getFastPrice($.internalFeeds[_feedId(tokenOut)]);
            if (priceFastIn > 0 && priceFastOut > 0) {
                feeForOutputLPsInOut = FPMath.mulDiv(feeForOutputLPs, priceFastIn, priceFastOut);
                feeForOutputLPsInOut = M.adjustDecimals(feeForOutputLPsInOut, assetIn.decimals, assetOut.decimals);
            }
        }

        // Store old reserves
        uint128 oldIn = assetIn.reserves;
        uint128 oldOut = assetOut.reserves;

        // Pre-hook
        if ($.hooks[tokenIn] != address(0)) {
            IBAMMHooks($.hooks[tokenIn]).preBuy(tokenIn, msg.sender, amountIn, tokenOut, rq.amountOut, "");
        }

        // Pull tokenIn with FOT handling
        uint256 actualAmountIn = _pullToken(tokenIn, msg.sender, amountIn);

        // Handle FOT scaling
        if (actualAmountIn != amountIn) {
            uint256 scale = FPMath.mulDiv(actualAmountIn, M.PRECISION, amountIn);
            feeForInputLPs = FPMath.mulDiv(feeForInputLPs, scale, M.PRECISION);
            feeForOutputLPsInOut = FPMath.mulDiv(feeForOutputLPsInOut, scale, M.PRECISION);
            rq.protocolFeeIn = FPMath.mulDiv(rq.protocolFeeIn, scale, M.PRECISION);

            uint256 deficit = amountIn - actualAmountIn;
            require(deficit <= assetIn.reserves, "FOT deficit exceeds reserves");
            assetIn.reserves -= uint128(deficit);
        }

        // Update reserves
        assetIn.reserves = (uint256(oldIn) + actualAmountIn - rq.protocolFeeIn).toUint128();
        assetOut.reserves = (uint256(oldOut) - rq.amountOut).toUint128();

        // Update LP indices
        _updateLPIndex(tokenIn, feeForInputLPs, oldIn);
        _updateLPIndex(tokenOut, feeForOutputLPsInOut, uint128(uint256(oldOut) - rq.amountOut));

        // Protocol fees
        if (rq.protocolFeeIn > 0) $.protocolFees[tokenIn] += rq.protocolFeeIn;

        // TODO: Re-enable total value caching if needed for analytics

        // Post-hook
        if ($.hooks[tokenIn] != address(0)) {
            IBAMMHooks($.hooks[tokenIn]).postBuy(tokenIn, msg.sender, actualAmountIn, tokenOut, rq.amountOut, "");
        }

        // Pre-sell hook
        if ($.hooks[tokenOut] != address(0)) {
            IBAMMHooks($.hooks[tokenOut]).preSell(tokenOut, msg.sender, actualAmountIn, tokenIn, rq.amountOut, "");
        }

        // Push tokenOut with FOT handling
        (uint256 actualAmountOut, uint256 retained) = _pushToken(tokenOut, receiver, rq.amountOut);

        // Handle output FOT
        if (retained > 0) {
            _reconcileOutputFOT(retained, assetOut, $.lpStates[tokenOut]);
        }

        // Post-sell hook
        if ($.hooks[tokenOut] != address(0)) {
            IBAMMHooks($.hooks[tokenOut]).postSell(tokenOut, msg.sender, actualAmountIn, tokenIn, actualAmountOut, "");
        }

        emit Swapped(msg.sender, receiver, tokenIn, tokenOut, actualAmountIn, actualAmountOut, rq.feeBps);
    }

    function _executeTriangulatedSwap(
        IBAMM.BAMMStorage storage $,
        address tokenIn,
        address tokenOut,
        address base,
        uint256 amountIn,
        P.RouteQuote memory rq,
        address receiver
    ) private {
        Asset storage assetIn = $.assets[tokenIn];
        Asset storage assetOut = $.assets[tokenOut];
        Asset storage assetBase = $.assets[base];

        // Check final output reserves
        if (rq.amountOut > assetOut.reserves) revert E.InsufficientReserves();
        if (assetOut.reserves - rq.amountOut < $.riskConfigs[tokenOut].minLiquidity) revert E.BelowMinimumLiquidity();

        // Store old reserves (base not modified in virtual routing)
        uint128 oldIn = assetIn.reserves;
        uint128 oldOut = assetOut.reserves;

        // Pre-hook
        if ($.hooks[tokenIn] != address(0)) {
            IBAMMHooks($.hooks[tokenIn]).preBuy(tokenIn, msg.sender, amountIn, tokenOut, rq.amountOut, "");
        }

        // Pull tokenIn with FOT handling
        uint256 actualAmountIn = _pullToken(tokenIn, msg.sender, amountIn);

        // Handle FOT - need to recalculate route if actual amount differs
        if (actualAmountIn != amountIn) {
            // Recalculate route with actual amount
            rq = P.quoteRoute(
                tokenIn, tokenOut, base, actualAmountIn,
                assetIn, assetOut, assetBase,
                $.liquidityProfiles[tokenIn], $.liquidityProfiles[tokenOut], $.liquidityProfiles[base],
                $.internalFeeds[_feedId(tokenIn)], $.internalFeeds[_feedId(tokenOut)], $.internalFeeds[_feedId(base)],
                $.dynamicFeeConfigs[tokenIn]
            );

            uint256 deficit = amountIn - actualAmountIn;
            require(deficit <= assetIn.reserves, "FOT deficit exceeds reserves");
            assetIn.reserves -= uint128(deficit);
        }

        // Update reserves (base is virtual, not modified)
        assetIn.reserves = (uint256(oldIn) + actualAmountIn - rq.protocolFeeIn).toUint128();
        assetOut.reserves = (uint256(oldOut) - rq.amountOut).toUint128();

        // Update LP indices (only for tokenIn and tokenOut, base earns no LP fees)
        _updateLPIndex(tokenIn, rq.lpFeeIn, oldIn);
        _updateLPIndex(tokenOut, rq.lpFeeOut, uint128(uint256(oldOut) - rq.amountOut));

        // Protocol fees (collect for all three)
        if (rq.protocolFeeIn > 0) $.protocolFees[tokenIn] += rq.protocolFeeIn;
        if (rq.protocolFeeOut > 0) $.protocolFees[tokenOut] += rq.protocolFeeOut;
        if (rq.protocolFeeBase > 0) $.protocolFees[base] += rq.protocolFeeBase;

        // TODO: Re-enable total value caching if needed for analytics

        // Post-buy + pre-sell hooks
        if ($.hooks[tokenIn] != address(0)) {
            IBAMMHooks($.hooks[tokenIn]).postBuy(tokenIn, msg.sender, actualAmountIn, tokenOut, rq.amountOut, "");
            IBAMMHooks($.hooks[tokenOut]).preSell(tokenOut, msg.sender, actualAmountIn, tokenIn, rq.amountOut, "");
        }

        // Push tokenOut with FOT handling
        (uint256 actualAmountOut, uint256 retained) = _pushToken(tokenOut, receiver, rq.amountOut);

        // Handle output FOT
        if (retained > 0) {
            _reconcileOutputFOT(retained, assetOut, $.lpStates[tokenOut]);
        }

        // Post-sell hook
        if ($.hooks[tokenOut] != address(0)) {
            IBAMMHooks($.hooks[tokenOut]).postSell(tokenOut, msg.sender, actualAmountIn, tokenIn, actualAmountOut, "");
        }

        emit SwappedTwoLeg(
            msg.sender, receiver, tokenIn, base, tokenOut,
            actualAmountIn, actualAmountOut, rq.leg1FeeBps, rq.leg2FeeBps
        );
    }

    // ========== QUOTE FUNCTION ==========

    function getSwapQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view override returns (uint256 amountOut, uint256 feeBps) {
        IBAMM.BAMMStorage storage $ = _sb();

        Asset storage assetIn = $.assets[tokenIn];
        Asset storage assetOut = $.assets[tokenOut];

        if (assetIn.reserves == 0 || assetOut.reserves == 0) return (0, 0);

        address base = $.baseToken;
        Asset storage assetBase = $.assets[base];

        P.RouteQuote memory rq = P.quoteRoute(
            tokenIn, tokenOut, base, amountIn,
            assetIn, assetOut, assetBase,
            $.liquidityProfiles[tokenIn], $.liquidityProfiles[tokenOut], $.liquidityProfiles[base],
            $.internalFeeds[_feedId(tokenIn)], $.internalFeeds[_feedId(tokenOut)], $.internalFeeds[_feedId(base)],
            $.dynamicFeeConfigs[tokenIn]
        );

        return (rq.amountOut, rq.feeBps);
    }

    // ========== BATCH SWAP (simplified) ==========

    function batchSwap(
        SwapStep[] calldata steps,
        address receiver
    ) external payable override nonReentrant whenNotPaused returns (uint256[] memory amounts) {
        if (steps.length == 0 || steps.length > 8) revert E.InvalidParameter();
        LibUtils.requireNonZero(receiver);

        IBAMM.BAMMStorage storage $ = _sb();

        if ($.blacklisted[msg.sender] || $.blacklisted[receiver]) revert E.Blacklisted();

        amounts = new uint256[](steps.length);

        // Track deltas in memory
        TokenDelta[16] memory deltas;
        uint256 deltaCount;

        // Execute swaps virtually
        for (uint256 i = 0; i < steps.length; i++) {
            SwapStep memory step = steps[i];

            Asset storage assetIn = $.assets[step.tokenIn];
            Asset storage assetOut = $.assets[step.tokenOut];

            // Use unified routing
            P.RouteQuote memory rq = P.quoteRoute(
                step.tokenIn, step.tokenOut, $.baseToken, step.amountIn,
                assetIn, assetOut, $.assets[$.baseToken],
                $.liquidityProfiles[step.tokenIn], $.liquidityProfiles[step.tokenOut], $.liquidityProfiles[$.baseToken],
                $.internalFeeds[_feedId(step.tokenIn)], $.internalFeeds[_feedId(step.tokenOut)], $.internalFeeds[_feedId($.baseToken)],
                $.dynamicFeeConfigs[step.tokenIn]
            );

            amounts[i] = rq.amountOut;

            // Track deltas
            deltaCount = _trackDelta(deltas, deltaCount, step.tokenIn, int256(step.amountIn) - int256(rq.protocolFeeIn), rq.lpFeeIn, rq.protocolFeeIn);
            deltaCount = _trackDelta(deltas, deltaCount, step.tokenOut, -int256(rq.amountOut), rq.lpFeeOut, rq.protocolFeeOut);
        }

        // Apply all deltas atomically
        for (uint256 i = 0; i < deltaCount; i++) {
            if (deltas[i].token == address(0)) continue;

            Asset storage asset = $.assets[deltas[i].token];
            uint128 oldReserves = asset.reserves;

            if (deltas[i].reserveDelta > 0) {
                asset.reserves = (uint256(asset.reserves) + uint256(deltas[i].reserveDelta)).toUint128();
            } else if (deltas[i].reserveDelta < 0) {
                uint256 decrease = uint256(-deltas[i].reserveDelta);
                require(decrease <= asset.reserves, "Insufficient reserves");
                asset.reserves = (uint256(asset.reserves) - decrease).toUint128();
            }

            if (deltas[i].lpFees > 0) {
                _updateLPIndex(deltas[i].token, deltas[i].lpFees, oldReserves);
            }

            if (deltas[i].protocolFees > 0) {
                $.protocolFees[deltas[i].token] += deltas[i].protocolFees;
            }
        }

        // Handle first input and last output transfers
        _pullToken(steps[0].tokenIn, msg.sender, steps[0].amountIn);
        _pushToken(steps[steps.length - 1].tokenOut, receiver, amounts[amounts.length - 1]);

        // Build path for event (tokenIn for each step + final tokenOut)
        address[] memory path = new address[](steps.length + 1);
        for (uint256 i = 0; i < steps.length; i++) {
            path[i] = steps[i].tokenIn;
        }
        path[steps.length] = steps[steps.length - 1].tokenOut;

        emit BatchSwapped(msg.sender, receiver, path, amounts);
    }

    // ========== LIABILITY SWAP ==========

    /// @notice Swap LP liability between assets (rebalancing without haircut when coverage neutral)
    /// @param tokenIn Asset to reduce liability from
    /// @param tokenOut Asset to add liability to
    /// @param lpAmountIn LP tokens to swap
    /// @param minLpAmountOut Minimum LP tokens to receive (slippage protection)
    /// @return lpAmountOut Actual LP tokens received (after haircut if any)
    function swapLiability(
        address tokenIn,
        address tokenOut,
        uint256 lpAmountIn,
        uint256 minLpAmountOut
    ) external nonReentrant whenNotPaused returns (uint256 lpAmountOut) {
        if (tokenIn == tokenOut) revert E.InvalidParameter();
        if (lpAmountIn == 0) revert E.ZeroAmount();

        IBAMM.BAMMStorage storage $ = _sb();

        // Get assets
        (Asset storage assetIn, Asset storage assetOut, address base) = ($.assets[tokenIn], $.assets[tokenOut], $.baseToken);

        // Asset checks
        if (assetIn.reserves == 0 || assetOut.reserves == 0) revert E.InsufficientReserves();
        if (S._isFrozen($.riskConfigs[tokenIn]) || S._isFrozen($.riskConfigs[tokenOut])) revert E.AssetFrozen();

        // Check swap enabled for both assets
        if (!S._liabilitySwapEnabled($.riskConfigs[tokenIn]) || !S._liabilitySwapEnabled($.riskConfigs[tokenOut])) revert E.LiabilitySwapDisabled();

        // TODO: Add minSwapAmount to RiskConfig if needed
        // For now, just require non-zero amount
        if (lpAmountIn == 0) revert E.ZeroAmount();

        IBAMM.RiskConfig storage configIn = $.riskConfigs[tokenIn];
        IBAMM.RiskConfig storage configOut = $.riskConfigs[tokenOut];

        // Check user has sufficient LP tokens
        uint256 tokenId_in = uint256(uint160(tokenIn));
        if (balanceOf(msg.sender, tokenId_in) < lpAmountIn) revert E.InsufficientBalance();

        // Update decay
        LibLiability.updateDecay(tokenIn);
        LibLiability.updateDecay(tokenOut);

        // Get oracles
        IInternalOracle.InternalFeedData storage oracleIn = $.internalFeeds[_feedId(tokenIn)];
        IInternalOracle.InternalFeedData storage oracleOut = $.internalFeeds[_feedId(tokenOut)];

        // Handle triangulated routing
        bool isTriangulated = (tokenIn != base && tokenOut != base);
        Asset storage assetBase = $.assets[base];
        IInternalOracle.InternalFeedData storage oracleBase = $.internalFeeds[_feedId(base)];

        if (isTriangulated) LibLiability.updateDecay(base);

        // Execute liability swap (reuses LibPricing for quote)
        uint256 haircut;
        (lpAmountOut, haircut) = LibLiability.executeSwap(
            tokenIn, tokenOut, lpAmountIn,
            assetIn, assetOut, assetBase,
            $.liquidityProfiles[tokenIn], $.liquidityProfiles[tokenOut], $.liquidityProfiles[base],
            oracleIn, oracleOut, oracleBase,
            $.dynamicFeeConfigs[tokenIn], configIn, configOut, base
        );

        // Slippage check
        if (lpAmountOut < minLpAmountOut) revert E.SlippageExceeded();

        // Burn source LP tokens
        _burn(msg.sender, tokenId_in, lpAmountIn);

        // Mint destination LP tokens
        uint256 tokenId_out = uint256(uint160(tokenOut));
        _mint(msg.sender, tokenId_out, lpAmountOut, "");

        // Emit event
        emit LiabilitySwapped(msg.sender, tokenIn, tokenOut, lpAmountIn, lpAmountOut, haircut);
    }

    // ========== DEPOSIT & WITHDRAW ==========

    function deposit(
        address token,
        uint256 amount,
        uint256 minLpTokens
    ) external payable override nonReentrant whenNotPaused notFrozen(token) returns (uint256 lpTokens) {
        LibUtils.requireNonZero(amount);
        IBAMM.BAMMStorage storage $ = _sb();

        LibLiability.updateDecay(token);

        if ($.blacklisted[msg.sender]) revert E.Blacklisted();
        Asset storage asset = $.assets[token];
        LPState storage lpState = $.lpStates[token];

        if (asset.reserves == 0 && amount < $.riskConfigs[token].minLiquidity) revert E.BelowMinimumLiquidity();
        if (lpState.liquidityIndex == 0) lpState.liquidityIndex = uint128(M.INDEX_PRECISION);

        if ($.hooks[token] != address(0)) IBAMMHooks($.hooks[token]).preDeposit(token, msg.sender, amount, "");

        uint128 oldReserves = asset.reserves;

        // Pull with FOT handling
        uint256 actualAmount = _pullToken(token, msg.sender, amount);

        // Deposit fee
        uint256 depositFee = (actualAmount * asset.fees.depositFeeBps) / M.BPS_PRECISION;
        uint256 amountAfterFee = actualAmount - depositFee;

        // Bump index with deposit fee
        if (depositFee > 0 && lpState.totalScaledSupply > 0 && oldReserves > 0) {
            uint256 newIndex = FPMath.mulDiv(
                uint256(lpState.liquidityIndex),
                uint256(oldReserves) + depositFee,
                uint256(oldReserves)
            );
            lpState.liquidityIndex = newIndex.toUint128();
        }

        // Calculate LP tokens
        lpTokens = lpState.totalScaledSupply == 0 ? amountAfterFee :
            (amountAfterFee * lpState.totalScaledSupply * M.PRECISION) / (uint256(oldReserves + depositFee) * lpState.liquidityIndex);

        if (lpTokens < minLpTokens) revert E.SlippageExceeded();

        uint256 scaledAmount = (lpTokens * M.PRECISION) / lpState.liquidityIndex;

        // Update state
        lpState.totalScaledSupply = (lpState.totalScaledSupply + scaledAmount).toUint128();
        asset.reserves = (asset.reserves + actualAmount).toUint128();
        asset.liabilities = (asset.liabilities + actualAmount).toUint128();

        // TODO: Re-enable total value caching if needed for analytics

        _mint(msg.sender, uint256(uint160(token)), lpTokens, "");

        if ($.hooks[token] != address(0)) IBAMMHooks($.hooks[token]).postDeposit(token, msg.sender, actualAmount, lpTokens, "");

        emit Deposited(msg.sender, token, actualAmount, lpTokens);
    }

    function withdraw(
        address token,
        uint256 lpTokens,
        uint256 minAmount
    ) external override nonReentrant whenNotPaused notFrozen(token) returns (uint256 amountOut) {
        LibUtils.requireNonZero(lpTokens);
        IBAMM.BAMMStorage storage $ = _sb();

        LibLiability.updateDecay(token);

        if ($.blacklisted[msg.sender]) revert E.Blacklisted();
        Asset storage asset = $.assets[token];
        LPState storage lpState = $.lpStates[token];

        if (lpState.totalScaledSupply == 0) revert E.InsufficientLiquidity();

        if ($.hooks[token] != address(0)) IBAMMHooks($.hooks[token]).preWithdraw(token, msg.sender, lpTokens, "");

        uint128 oldReserves = asset.reserves;

        // Calculate scaled amount
        uint256 scaledAmount = (lpTokens * M.PRECISION) / lpState.liquidityIndex;

        // Calculate withdrawal amount
        amountOut = (scaledAmount * lpState.liquidityIndex) / M.PRECISION;

        // Apply coverage ratio haircut
        if (asset.reserves < asset.liabilities) {
            uint256 coverageRatio = FPMath.mulDiv(asset.reserves, M.BPS_PRECISION, asset.liabilities);
            amountOut = FPMath.mulDiv(amountOut, coverageRatio, M.BPS_PRECISION);
        }

        // Withdrawal fee
        uint256 withdrawalFee = (amountOut * asset.fees.withdrawalFeeBps) / M.BPS_PRECISION;
        amountOut -= withdrawalFee;

        if (amountOut < minAmount) revert E.SlippageExceeded();
        if (amountOut > asset.reserves) revert E.InsufficientReserves();
        if (asset.reserves - amountOut < $.riskConfigs[token].minLiquidity) revert E.BelowMinimumLiquidity();

        // Update state
        lpState.totalScaledSupply = (lpState.totalScaledSupply - scaledAmount).toUint128();
        asset.reserves = (asset.reserves - amountOut).toUint128();
        asset.liabilities = (asset.liabilities - scaledAmount * lpState.liquidityIndex / M.PRECISION).toUint128();

        // Bump index with withdrawal fee
        IInternalOracle.InternalFeedData storage oracle = $.internalFeeds[_feedId(token)];
        if (withdrawalFee > 0 && lpState.totalScaledSupply > 0 && oldReserves - amountOut > 0) {
            uint256 newIndex = FPMath.mulDiv(
                uint256(lpState.liquidityIndex),
                uint256(oldReserves - amountOut) + withdrawalFee,
                uint256(oldReserves - amountOut)
            );
            lpState.liquidityIndex = newIndex.toUint128();
        }

        // TODO: Re-enable total value caching if needed for analytics

        _burn(msg.sender, uint256(uint160(token)), lpTokens);

        (uint256 actualOut, uint256 retained) = _pushToken(token, msg.sender, amountOut);

        if (retained > 0) {
            _reconcileOutputFOT(retained, asset, lpState);
        }

        if ($.hooks[token] != address(0)) IBAMMHooks($.hooks[token]).postWithdraw(token, msg.sender, actualOut, lpTokens, "");

        emit Withdrawn(msg.sender, token, lpTokens, actualOut, asset.fees.withdrawalFeeBps);
    }

    // ========== SHARED FOT HELPERS ==========

    function _pullToken(address token, address from, uint256 amount) private returns (uint256 actual) {
        // Track balance before transfer to detect FOT
        uint256 balBefore = token == address(0) ? 0 : token.balanceOf(address(this));

        // Use LibNativeToken to handle both ERC20 and native ETH
        LibNativeToken.pullToken(token, from, address(this), amount, _sb().weth);

        // Calculate actual received amount for FOT detection
        uint256 balAfter = token == address(0) ? 0 : token.balanceOf(address(this));
        actual = balAfter - balBefore;
    }

    function _pushToken(address token, address to, uint256 amount) private returns (uint256 actual, uint256 retained) {
        uint256 balBefore = token.balanceOf(to);

        // Use LibNativeToken to handle both ERC20 and native ETH unwrapping
        LibNativeToken.pushToken(token, address(this), to, amount, _sb().weth);

        actual = token.balanceOf(to) - balBefore;
        retained = actual < amount ? amount - actual : 0;
    }

    function _reconcileOutputFOT(
        uint256 retained,
        Asset storage asset,
        LPState storage lpState
    ) private {
        if (retained == 0) return;

        uint128 oldReserves = asset.reserves;
        asset.reserves = (uint256(oldReserves) + retained).toUint128();

        if (lpState.totalScaledSupply > 0 && oldReserves > 0) {
            uint256 newIndex = FPMath.mulDiv(
                lpState.liquidityIndex,
                uint256(oldReserves) + retained,
                oldReserves
            );
            lpState.liquidityIndex = newIndex.toUint128();
        }

        IBAMM.BAMMStorage storage $ = _sb();
    }

    // ========== ORACLE FALLBACK ==========

    function _checkOracleOrFallback(IInternalOracle.InternalFeedData storage oracle, address token) private view {
        // staleAfter is returned by oracle itself (dynamic), use reasonable default
        bool mainStale = block.timestamp - oracle.base.updatedAt > 24 hours;

        if (!mainStale) return;

        // Main oracle stale, require fallback oracle configured
        IBAMM.BAMMStorage storage $ = _sb();
        LibUtils.requireNonZero($.oracleConfigs[token].fallbackOracle);

        // In the simplified model, we just revert if main is stale and fallback exists
        // The actual fallback data fetch would require external call infrastructure
        // For now, this prevents swaps when oracle is stale
        revert E.OracleInvalid();
    }

    // ========== CIRCUIT BREAKER ==========

    function _checkCircuitBreaker(
        IInternalOracle.InternalFeedData storage oracle,
        IBAMM.RiskConfig storage risk
    ) private view {
        // Check reserve price floor (Circuit Breaker #1)
        if (risk.reservePrice != 0) {
            uint256 currentPrice = M.b64ToPrice(oracle.currentPrice);
            uint256 reserveFloor = M.b64ToPrice(risk.reservePrice);
            if (currentPrice < reserveFloor) {
                revert E.ReservePriceViolation();
            }
        }
        // Note: Other circuit breakers (maxFastDeviation, maxSlowDeviation, maxBetaDeviation)
        // are checked off-chain by guardian before calling checkCircuitBreaker()
    }

    // ========== LP INDEX HELPERS ==========

    function _updateLPIndex(address token, uint256 lpFee, uint128 oldReserves) private {
        if (lpFee == 0) return;

        IBAMM.BAMMStorage storage $ = _sb();
        LPState storage lpState = $.lpStates[token];
        Asset storage asset = $.assets[token];

        if (lpState.totalScaledSupply > 0 && oldReserves > 0) {
            uint256 newIndex = FPMath.mulDiv(
                uint256(lpState.liquidityIndex),
                uint256(oldReserves) + lpFee,
                uint256(oldReserves)
            );
            lpState.liquidityIndex = newIndex.toUint128();
            asset.liabilities = (uint256(asset.liabilities) + lpFee).toUint128();

            IInternalOracle.InternalFeedData storage oracle = $.internalFeeds[_feedId(token)];
        }
    }

    function _splitLpFee(uint256 lpFee, uint256 liabIn, uint256 liabOut) private pure returns (uint256 feeIn, uint256 feeOut) {
        uint256 total = liabIn + liabOut;
        if (total == 0) {
            unchecked { feeIn = lpFee >> 1; feeOut = lpFee - feeIn; }
        } else {
            feeIn = FPMath.mulDiv(lpFee, liabIn, total);
            feeOut = lpFee - feeIn;
        }
    }

    function _trackDelta(
        TokenDelta[16] memory deltas,
        uint256 count,
        address token,
        int256 reserveDelta,
        uint256 lpFees,
        uint256 protocolFees
    ) private pure returns (uint256) {
        for (uint256 i = 0; i < count; i++) {
            if (deltas[i].token == token) {
                deltas[i].reserveDelta += reserveDelta;
                deltas[i].lpFees += lpFees;
                deltas[i].protocolFees += protocolFees;
                return count;
            }
        }
        deltas[count] = TokenDelta(token, reserveDelta, lpFees, protocolFees);
        return count + 1;
    }

    // ========== VIEW FUNCTIONS ==========

    function baseToken() public view returns (address) {
        return _sb().baseToken;
    }

    function getAsset(address token) external view returns (Asset memory) {
        return _sb().assets[token];
    }

    /// @notice Get token decimals (internal implementation)
    function _getDecimals(address token) internal view override returns (uint8) {
        // Return cached decimals from asset (set during addAsset)
        return _sb().assets[token].decimals;
    }

    function getLPState(address token) external view returns (LPState memory) {
        return _sb().lpStates[token];
    }

    /// @notice ERC1155 URI (required by interface, returns empty for LP tokens)
    function uri(uint256) public view virtual override returns (string memory) {
        return "";
    }

    function getCachedTotals() external pure returns (uint256 totalValue, uint256 totalLiabilities) {
        // TODO: Implement if caching is re-enabled
        return (0, 0);
    }

    // ========== INTERFACE VIEW FUNCTIONS ==========

    /// @inheritdoc IBAMM
    function lpStates(address token) external view returns (LPState memory) {
        return _sb().lpStates[token];
    }

    /// @inheritdoc IBAMM
    function calculateSwapFee(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (FeeComponents memory) {
        IBAMM.BAMMStorage storage $ = _sb();
        Asset storage assetIn = _getAsset(tokenIn);
        Asset storage assetOut = _getAsset(tokenOut);
        Asset storage assetBase = _getAsset($.baseToken);

        // Get quote which includes fee breakdown
        P.RouteQuote memory rq = P.quoteRoute(
            tokenIn, tokenOut, $.baseToken, amountIn,
            assetIn, assetOut, assetBase,
            $.liquidityProfiles[tokenIn], $.liquidityProfiles[tokenOut], $.liquidityProfiles[$.baseToken],
            $.internalFeeds[_feedId(tokenIn)], $.internalFeeds[_feedId(tokenOut)], $.internalFeeds[_feedId($.baseToken)],
            $.dynamicFeeConfigs[tokenIn]
        );

        // Build fee components (simplified - you may want more detail)
        return FeeComponents({
            baseFee: 0, // Not exposed in RouteQuote
            volatilityMultiplier: 0,
            inventoryMultiplier: 0,
            divergenceMultiplier: 0,
            totalFeeBps: rq.feeBps,
            leg1FeeBps: rq.leg1FeeBps,
            leg2FeeBps: rq.leg2FeeBps
        });
    }

    /// @inheritdoc IBAMM
    function getLPValue(
        address token,
        uint256 lpTokens
    ) external view returns (uint256 underlyingAmount) {
        LPState storage lpState = _sb().lpStates[token];
        if (lpState.totalScaledSupply == 0) return 0;

        // LP value = (lpTokens / totalScaledSupply) * reserves
        Asset storage asset = _getAsset(token);
        return (lpTokens * uint256(asset.reserves)) / uint256(lpState.totalScaledSupply);
    }

    /// @inheritdoc IBAMM
    function getTotalValue() external view returns (uint256 tvl) {
        // TODO: Implement if caching is re-enabled or compute on-the-fly
        return 0;
    }

    /// @inheritdoc IBAMM
    function getFeedData(address token) external view returns (
        uint64 fastTWAP,
        uint64 slowTWAP,
        uint32 fastVolEMA,
        uint32 slowVolEMA,
        uint32 lastUpdate
    ) {
        IInternalOracle.InternalFeedData storage oracle = _sb().internalFeeds[_feedId(token)];

        // TODO: Compute TWAP from accumulators
        // For now return current price as both TWAPs
        return (
            oracle.currentPrice,
            oracle.currentPrice,
            oracle.base.fastVolEMA,
            oracle.base.slowVolEMA,
            oracle.base.updatedAt
        );
    }

    /// @inheritdoc IBAMM
    function getAssetState(address token) external view returns (
        uint64 fastTWAP,
        uint64 slowTWAP,
        uint128 reserves,
        uint128 liabilities,
        uint256 reservesValue,
        uint256 liabilitiesValue
    ) {
        IBAMM.BAMMStorage storage $ = _sb();
        Asset storage asset = _getAsset(token);
        IInternalOracle.InternalFeedData storage oracle = $.internalFeeds[_feedId(token)];

        // TODO: Use actual slow TWAP computation
        // Get price in 1e18
        uint256 price1e18 = M.decodePriceTo1e18(oracle.currentPrice);

        // Calculate values
        reservesValue = (uint256(asset.reserves) * price1e18) / (10 ** asset.decimals);
        liabilitiesValue = (uint256(asset.liabilities) * price1e18) / (10 ** asset.decimals);

        // TODO: Compute TWAP from accumulators
        return (
            oracle.currentPrice,
            oracle.currentPrice,
            asset.reserves,
            asset.liabilities,
            reservesValue,
            liabilitiesValue
        );
    }

    // ========== STUBS ==========

    /// @inheritdoc IBAMM
    function checkCircuitBreaker(address /* token */) external returns (bool triggered) {
        // TODO: Implement circuit breaker logic
        return false;
    }

    /// @inheritdoc IBAMM
    function collectProtocolFees(address[] calldata tokens) external {
        // TODO: Implement protocol fee collection
    }

    /// @inheritdoc IBAMM
    function getHooks(address token) external view returns (address hookAddress) {
        return _sb().hooks[token];
    }

    /// @notice Check if oracle feed is fresh (updated within 1 hour)
    function isFreshDefault(bytes32 feedId) external view returns (bool) {
        IInternalOracle.InternalFeedData storage oracle = _sb().internalFeeds[feedId];
        return block.timestamp - oracle.base.updatedAt < 1 hours;
    }

    /// @inheritdoc IBAMM
    function updateHooks(address token, address hooks) external onlyOwner {
        _sb().hooks[token] = hooks;
        emit HooksUpdated(token, hooks);
    }
}