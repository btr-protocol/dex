// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IInternalOracle} from "../interfaces/IInternalOracle.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {LibMaths as M} from "./LibMaths.sol";
import {LibUtils as Cast} from "./LibUtils.sol";
import {LibStorage as S} from "./LibStorage.sol";
import {LibMakimaPricing as MakimaP} from "./LibMakimaPricing.sol";
import {BAMMErrors as E} from "../bamm/BAMMErrors.sol";
import {FPMaths as FPMath} from "solady/utils/FixedPointMathLib.sol";

/// @title LibPricing - Tri-factor ALM with coverage-based routing
/// @notice Implements tri-factor fee model: coverage × volatility × deviation
/// @dev Dynamic piecewise bonding curve + liability time decay
library LibPricing {
    using Cast for uint256;

    // ========== STRUCTS ==========

    // FeeParams moved to IBAMM.sol for single source of truth

    // Type aliases for external structs (avoid duplication)
    // Use IOracle.DecodedFeedData directly - single source of truth
    // See IOracle.sol for struct definition

    struct RouteQuote {
        uint256 amountOut;
        uint256 feeBps;           // Total path fee (visible to trader)
        uint256 lpFeeIn;          // LP fee for leg1 (in tokenIn units)
        uint256 lpFeeOut;         // LP fee for leg2 (in tokenOut units)
        uint256 protocolFeeIn;    // Protocol fee for leg1
        uint256 protocolFeeOut;   // Protocol fee for leg2
        bool isTriangulated;      // true = A→base→B, false = A↔base (direct)
        uint256 leg1FeeBps;       // Fee bps for leg1 (always totalFeeBps/2)
        uint256 leg2FeeBps;       // Fee bps for leg2 (always totalFeeBps/2)
        uint256 amountBase;       // Intermediate amount (triangulated only)
        uint256 protocolFeeBase;  // Protocol fee in base units (triangulated only)
    }

    // ========== MAIN ROUTING FUNCTION ==========

    function quoteRoute(
        address tokenIn,
        address tokenOut,
        address baseToken,
        uint256 amountIn,
        IBAMM.Asset storage assetIn,
        IBAMM.Asset storage assetOut,
        IBAMM.Asset storage assetBase,
        IBAMM.LiquidityProfile storage profIn,
        IBAMM.LiquidityProfile storage profOut,
        IBAMM.LiquidityProfile storage profBase,
        IInternalOracle.InternalFeedData storage oracleIn,
        IInternalOracle.InternalFeedData storage oracleOut,
        IInternalOracle.InternalFeedData storage oracleBase,
        IBAMM.DynamicFeeConfig storage params
    ) internal view returns (RouteQuote memory rq) {
        rq.isTriangulated = (tokenIn != baseToken && tokenOut != baseToken);

        if (!rq.isTriangulated) {
            // Direct swap: A ↔ base (two legs, but one is base)
            IOracle.DecodedFeedData memory dataIn = decodeOracle(oracleIn);
            IOracle.DecodedFeedData memory dataOut = decodeOracle(oracleOut);

            // Get spot prices for deviation calculation (with coverage-aware depth)
            uint256 priceIn = _segmentPrice(tokenIn, assetIn, profIn, dataIn, amountIn);
            uint256 priceOut = _segmentPrice(tokenOut, assetOut, profOut, dataOut, 0);

            // Inherit vol/deviation from non-base token
            bool inIsBase = (tokenIn == baseToken);
            IOracle.DecodedFeedData memory effectiveDataIn = inIsBase ? dataOut : dataIn;
            IOracle.DecodedFeedData memory effectiveDataOut = inIsBase ? dataOut : dataIn;

            // Compute path fee with coverage timing
            (uint256 totalFeeBps, uint256 amountAfterFee) = _computePathFee(
                assetIn, assetOut, effectiveDataIn, effectiveDataOut,
                priceIn, priceOut, params, amountIn
            );

            rq.amountOut = FPMath.mulDiv(amountAfterFee, priceIn, priceOut);
            rq.amountOut = M.adjustDecimals(rq.amountOut, assetIn.decimals, assetOut.decimals);

            // Split fee 50/50 between legs (apply totalFeeBps/2 to each)
            rq.feeBps = totalFeeBps;
            rq.leg1FeeBps = totalFeeBps / 2;
            rq.leg2FeeBps = totalFeeBps - rq.leg1FeeBps;  // Handle rounding

            // Fees in token units
            uint256 feeIn = amountIn * rq.leg1FeeBps / M.BPS_PRECISION;
            uint256 feeOut = rq.amountOut * rq.leg2FeeBps / M.BPS_PRECISION;

            rq.protocolFeeIn = feeIn * assetIn.fees.protocolFeeBps / M.BPS_PRECISION;
            rq.protocolFeeOut = feeOut * assetOut.fees.protocolFeeBps / M.BPS_PRECISION;
            rq.lpFeeIn = feeIn - rq.protocolFeeIn;
            rq.lpFeeOut = feeOut - rq.protocolFeeOut;
        } else {
            // Triangulated swap: A → base (virtual) → B

            // Decode oracles
            IOracle.DecodedFeedData memory dataIn = decodeOracle(oracleIn);
            IOracle.DecodedFeedData memory dataBase = decodeOracle(oracleBase);
            IOracle.DecodedFeedData memory dataOut = decodeOracle(oracleOut);

            // ✅ CRITICAL FIX #2: Virtual depth using geometric mean for path independence
            // Compute effective depths for both legs
            uint256 depthIn = _depthForPricing(tokenIn);
            uint256 depthOut = _depthForPricing(tokenOut);

            // Use geometric mean: sqrt(depthIn * depthOut)
            // This ensures path independence: A→base→B has same pricing as direct A↔B routes
            uint256 virtualDepthBase = FPMath.sqrt(depthIn * depthOut);

            // Get spot prices (with virtual depth for base)
            uint256 priceIn = _segmentPrice(tokenIn, assetIn, profIn, dataIn, amountIn);
            uint256 priceBase1 = _segmentPriceWithDepth(baseToken, assetBase, profBase, dataBase, 0, virtualDepthBase);
            uint256 priceOut = _segmentPrice(tokenOut, assetOut, profOut, dataOut, 0);

            // Compute total path fee with coverage timing
            (uint256 totalFeeBps,) = _computePathFee(
                assetIn, assetOut, dataIn, dataOut,
                priceIn, priceOut, params, amountIn
            );

            // Split fee 50/50 between legs
            rq.feeBps = totalFeeBps;
            rq.leg1FeeBps = totalFeeBps / 2;
            rq.leg2FeeBps = totalFeeBps - rq.leg1FeeBps;

            // Leg 1: Apply fee to input
            uint256 feeAmount1 = amountIn * rq.leg1FeeBps / M.BPS_PRECISION;
            uint256 amountAfterFee1 = amountIn - feeAmount1;

            rq.amountBase = FPMath.mulDiv(amountAfterFee1, priceIn, priceBase1);
            rq.amountBase = M.adjustDecimals(rq.amountBase, assetIn.decimals, assetBase.decimals);

            // Leg 2: Get price with actual base amount, apply fee to output
            // ✅ Use same virtualDepthBase for consistency
            uint256 priceBase2 = _segmentPriceWithDepth(baseToken, assetBase, profBase, dataBase, rq.amountBase, virtualDepthBase);
            uint256 rawAmountOut = FPMath.mulDiv(rq.amountBase, priceBase2, priceOut);
            rawAmountOut = M.adjustDecimals(rawAmountOut, assetBase.decimals, assetOut.decimals);

            uint256 feeAmount2 = rawAmountOut * rq.leg2FeeBps / M.BPS_PRECISION;
            rq.amountOut = rawAmountOut - feeAmount2;

            // Protocol fees
            rq.protocolFeeIn = feeAmount1 * assetIn.fees.protocolFeeBps / M.BPS_PRECISION;
            rq.protocolFeeOut = feeAmount2 * assetOut.fees.protocolFeeBps / M.BPS_PRECISION;

            // LP fees
            rq.lpFeeIn = feeAmount1 - rq.protocolFeeIn;
            rq.lpFeeOut = feeAmount2 - rq.protocolFeeOut;

            // Base protocol fee (no LP fees for base in triangulated swaps)
            // Base doesn't charge fee since it's virtual, but we track for accounting
            rq.protocolFeeBase = 0;
        }
    }

    // ========== ORACLE DECODING (internal helper functions) ==========

    /// @notice Decode oracle entry to compute TWAPs and prices
    /// @dev Single source of truth eliminates duplication across codebase
    /// @dev Shared logic with BAMMInternalOracle (see _decodeOracle there)
    function decodeOracle(IInternalOracle.InternalFeedData storage oracle) internal view returns (IOracle.DecodedFeedData memory data) {
        // Compute current accumulator with elapsed time
        uint256 elapsed = block.timestamp - oracle.base.updatedAt;
        uint256 accum = oracle.priceAccumulator + uint256(oracle.currentPrice) * elapsed;

        // Fast TWAP
        uint256 dtFast = block.timestamp - oracle.fastSnapshotTime;
        data.fastTWAP = dtFast == 0
            ? oracle.currentPrice
            : uint64((accum - oracle.fastAccumSnapshot) / dtFast);

        // Slow TWAP
        uint256 dtSlow = block.timestamp - oracle.slowSnapshotTime;
        data.slowTWAP = dtSlow == 0
            ? oracle.currentPrice
            : uint64((accum - oracle.slowAccumSnapshot) / dtSlow);

        // Convert B64 to 1e18 prices
        data.priceFast = M.b64ToPrice(data.fastTWAP);
        data.priceSlow = M.b64ToPrice(data.slowTWAP);

        // Volatility (no clamping for baseline)
        data.volFast = oracle.base.fastVolEMA;
        data.volSlow = oracle.base.slowVolEMA;
        data.volBaseline = oracle.base.slowVolEMA;
    }

    function getFastPrice(IInternalOracle.InternalFeedData storage oracle) internal view returns (uint256 fastPrice) {
        uint256 elapsed = block.timestamp - oracle.base.updatedAt;
        uint256 accum = oracle.priceAccumulator + uint256(oracle.currentPrice) * elapsed;

        uint256 dtFast = block.timestamp - oracle.fastSnapshotTime;
        uint64 fastTWAP = dtFast == 0
            ? oracle.currentPrice
            : uint64((accum - oracle.fastAccumSnapshot) / dtFast);

        fastPrice = M.b64ToPrice(fastTWAP);
    }

    // ========== FEE CALCULATION ==========

    /// @notice Compute total path fee using tri-factor model with geometric mean
    /// @dev Tri-factor: coverage × volatility × deviation
    /// @dev Uses geometric mean of asset multipliers for balanced incentives
    /// @dev 50/50 fee split between legs ensures LP reward fairness
    /// @param amount Input amount (for coverage timing adjustment)
    /// @return totalFeeBps Total path fee in basis points (split 50/50 per leg)
    /// @return amountAfterFee Amount after deducting total fee
    function _computePathFee(
        IBAMM.Asset storage assetIn,
        IBAMM.Asset storage assetOut,
        IOracle.DecodedFeedData memory dataIn,
        IOracle.DecodedFeedData memory dataOut,
        uint256 poolPriceIn,
        uint256 poolPriceOut,
        IBAMM.DynamicFeeConfig storage params,
        uint256 amount
    ) private view returns (uint256 totalFeeBps, uint256 amountAfterFee) {
        // Coverage timing (ALM incentives):
        // - assetIn: post-swap (after adding amountIn) → penalizes imbalance
        // - assetOut: pre-swap (before removing) → rewards rebalancing

        // Per-asset tri-factor multipliers with proper coverage timing
        uint256 multIn = _assetMultiplierWithTiming(
            assetIn, dataIn, poolPriceIn, params, amount, true  // post-swap (inflow)
        );
        uint256 multOut = _assetMultiplierWithTiming(
            assetOut, dataOut, poolPriceOut, params, 0, false  // pre-swap (outflow)
        );

        // Geometric mean of multipliers with overflow protection
        // Max multipliers capped at maxVolMult, maxDevMult, maxCovMult (~100x each)
        // Worst case: 100 * 100 = 10,000 (well within uint256)
        // Additional guard: ensure individual multipliers don't exceed 1e20
        if (multIn > 1e20 || multOut > 1e20) revert E.InvalidParameter();
        uint256 pathMult = FPMath.sqrt(multIn * multOut);

        // Base fee (from baseline volatility average)
        uint256 baseFee = _baseFee((dataIn.volBaseline + dataOut.volBaseline) / 2, params);

        // Total path fee
        totalFeeBps = baseFee * pathMult / M.PRECISION;
        if (totalFeeBps < params.minBaseFee) totalFeeBps = params.minBaseFee;
        if (totalFeeBps > M.MAX_FEE_BPS) totalFeeBps = M.MAX_FEE_BPS;

        amountAfterFee = amount * (M.BPS_PRECISION - totalFeeBps) / M.BPS_PRECISION;
    }

    function _assetMultiplierWithTiming(
        IBAMM.Asset storage asset,
        IOracle.DecodedFeedData memory data,
        uint256 poolPrice,
        IBAMM.DynamicFeeConfig storage params,
        uint256 deltaAmount,
        bool isInflow
    ) private view returns (uint256) {
        // Coverage timing:
        // - Inflow (selling into pool): use post-swap reserves for penalties
        // - Outflow (buying from pool): use pre-swap reserves for rebates
        uint256 adjustedReserves = isInflow
            ? uint256(asset.reserves) + deltaAmount
            : uint256(asset.reserves);

        // 1. Coverage factor with timing
        uint256 covMult = _coverageFactor(uint128(adjustedReserves), asset.liabilities, params);

        // 2. Volatility shock multiplier
        uint256 volMult = _volShock(data.volFast, data.volSlow, params);

        // 3. Price deviation multiplier
        uint256 devMult = _deviationFactor(poolPrice, data.priceFast, data.fastTWAP, data.slowTWAP, params);

        // Combine: m_asset = m_cov * m_vol * m_dev / 1e36
        uint256 mult = covMult * volMult / M.PRECISION;
        mult = mult * devMult / M.PRECISION;

        // No explicit min/max clamps - handled by individual factor limits
        // Coverage: minCovMult to maxCovMult (implicit min via rebate)
        // Volatility: capped by maxVolMult
        // Deviation: capped by maxDevMult
        return mult;
    }

    /// @notice Per-asset coverage factor (NOT global pool coverage)
    /// @dev Coverage = reserves / liabilities (in token units, not value)
    /// @dev Global pool coverage is NOT used in fee calculation, only for analytics
    /// @param reserves Asset reserves (with timing adjustment from caller)
    /// @param liabilities Asset liabilities (LP claims in token units)
    /// @param params Fee parameters
    /// @return Coverage multiplier in 1e18 precision
    function _coverageFactor(
        uint128 reserves,
        uint128 liabilities,
        IBAMM.DynamicFeeConfig storage params
    ) private view returns (uint256) {
        // Per-asset coverage ratio (NOT value-weighted global coverage)
        if (liabilities == 0) return M.PRECISION;

        uint256 coverage = uint256(reserves) * M.PRECISION / uint256(liabilities);

        if (coverage < M.PRECISION) {
            // Under-collateralized (< 100%): linear rebate to attract deposits
            uint256 deltaUnder = (M.PRECISION - coverage) * M.PRECISION / params.maxCovUnder;
            if (deltaUnder > M.PRECISION) deltaUnder = M.PRECISION;

            uint256 minMult = params.minCovMult * M.PRECISION / 100;
            return M.PRECISION - (M.PRECISION - minMult) * deltaUnder / M.PRECISION;
        } else {
            // Over-collateralized (> 100%): linear penalty to discourage deposits
            uint256 deltaOver = (coverage - M.PRECISION) * M.PRECISION / params.maxCovOver;
            if (deltaOver > M.PRECISION) deltaOver = M.PRECISION;

            uint256 maxMult = params.maxCovMult * M.PRECISION / 100;
            return M.PRECISION + (maxMult - M.PRECISION) * deltaOver / M.PRECISION;
        }
    }

    function _volShock(uint32 fast, uint32 slow, IBAMM.DynamicFeeConfig storage params) private view returns (uint256) {
        // Ensure minimum baseline volatility (prevents division issues and unrealistic ratios)
        uint256 slowSafe = slow > params.volEpsilon ? slow : params.volEpsilon;

        // Calculate shock ratio: r = fast / slowSafe
        uint256 r = fast * M.PRECISION / slowSafe;

        uint256 rMax = params.maxVolR * M.PRECISION / 100;
        if (r > rMax) r = rMax;

        if (r <= M.PRECISION) return M.PRECISION;

        uint256 shock = M.PRECISION + (r - M.PRECISION) * params.volBeta / 100;
        uint256 volMax = params.maxVolMult * M.PRECISION / 100;
        return shock > volMax ? volMax : shock;
    }

    function _baseFee(uint32 volBaseline, IBAMM.DynamicFeeConfig storage params) private view returns (uint256) {
        // Linear scaling: baseFee = max(minBaseFee, slowVol * baseK / 1e6)
        // volBaseline in 1e6 base (1_000_000 = 1%)
        // No upper clamp - global MAX_FEE_BPS applied at final fee calculation
        uint256 volFee = (uint256(volBaseline) * params.baseK) / 1_000_000;
        return volFee > params.minBaseFee ? volFee : params.minBaseFee;
    }

    /// @notice Accrue LP fees by increasing reserves (rebasing mechanism)
    /// @dev Used by swaps, flash loans, and other fee-generating operations
    function accrueFeesToLPs(
        IBAMM.Asset storage asset,
        IBAMM.LPState storage lpState,
        uint256 feeAmount
    ) internal {
        if (lpState.totalScaledSupply == 0 || feeAmount == 0) return;

        // Add fee to reserves (increases LP token value)
        uint256 newReserves = uint256(asset.reserves) + feeAmount;

        // Protect against uint128 overflow
        if (newReserves > type(uint128).max) {
            newReserves = type(uint128).max;
        }

        asset.reserves = uint128(newReserves);
    }

    function _deviationFactor(
        uint256 poolPrice,
        uint256 oracleFast,
        uint64 fastTWAP,
        uint64 slowTWAP,
        IBAMM.DynamicFeeConfig storage params
    ) private view returns (uint256) {
        // Dual deviation: pool vs oracle + oracle drift

        // 1. Pool execution price vs fast oracle (LVR risk)
        uint256 poolDev = 0;
        if (oracleFast > 0) {
            uint256 diff = poolPrice > oracleFast ? poolPrice - oracleFast : oracleFast - poolPrice;
            poolDev = (diff * M.BPS_PRECISION) / oracleFast;
        }

        // 2. Fast TWAP vs slow TWAP (oracle uncertainty)
        uint256 oracleDev = 0;
        if (slowTWAP > 0) {
            uint256 diff = fastTWAP > slowTWAP ? fastTWAP - slowTWAP : slowTWAP - fastTWAP;
            oracleDev = (diff * M.BPS_PRECISION) / slowTWAP;
        }

        // Combine additively
        uint256 totalDev = poolDev + oracleDev;

        // Apply threshold and scaling
        if (totalDev <= params.maxDevD1) return M.PRECISION;

        uint256 excessDev = totalDev - params.maxDevD1;
        if (excessDev > params.maxDevD2) excessDev = params.maxDevD2;

        uint256 mult = M.PRECISION + (excessDev * params.devAlpha) / 100;
        uint256 maxMult = M.PRECISION * params.maxDevMult / 100;
        if (mult > maxMult) mult = maxMult;

        return mult;
    }

    // ========== SEGMENT PRICING ==========

    /// @notice Calculate effective depth using coverage-aware amplification
    /// @dev Uses decayed liabilities (caller must call LibLiability.updateDecay first)
    /// @dev When L > R: amplifies depth by D = R + (L - R) × C, capped at alphaMax × R
    /// @dev When L ≤ R: no amplification, D = R
    /// @param asset Asset storage (contains reserves and liabilities)
    /// @return D Effective depth for pricing
    function _effectiveDepthToken(
        IBAMM.Asset storage asset
    ) private view returns (uint256 D) {
        // Use post-decay liabilities; BAMM.swap calls LibLiability.updateDecay() first
        uint256 R = uint256(asset.reserves);
        uint256 L = uint256(asset.liabilities);

        // No liabilities or no reserves → no amplification
        if (L == 0 || R == 0) return R;

        // Over-collateralized (C ≥ 1) → no virtual liquidity
        if (L <= R) return R;

        // Under-collateralized (C < 1) → amplify based on coverage ratio
        // Coverage C = R/L in WAD (1e18)
        uint256 C = FPMath.mulDiv(R, 1e18, L);

        // Smooth amplification: D = R + (L - R) × C
        // This gives linear interpolation: at C=1, D=L; at C→0, D→R
        uint256 extra = FPMath.mulDiv(L - R, C, 1e18);
        uint256 rawD = R + extra;

        // Hard cap on amplification (alphaMax = 12000 bps → 1.2x reserves)
        // TODO: Make alphaMax configurable per-asset via risk.maxAmplificationBps
        uint256 alphaMaxBps = 12000;
        uint256 maxD = FPMath.mulDiv(R, alphaMaxBps, 10000);

        D = rawD > maxD ? maxD : rawD;
    }

    /// @notice Wrapper to compute effective depth for pricing (adds token lookup)
    /// @dev Used for both direct swaps and virtual depth in triangulated swaps
    function _depthForPricing(address token) private view returns (uint256) {
        IBAMM.BAMMStorage storage $ = S.bamm();
        IBAMM.Asset storage asset = $.assets[token];

        return _effectiveDepthToken(asset);
    }

    function _segmentPrice(
        address token,
        IBAMM.Asset storage asset,
        IBAMM.LiquidityProfile storage prof,
        IOracle.DecodedFeedData memory data,
        uint256 amount
    ) private view returns (uint256) {
        return _segmentPriceWithDepth(token, asset, prof, data, amount, 0);
    }

    /// @notice Calculate segment-based price using Makima cubic splines
    /// @dev Virtual depth achieves path independence for triangulated swaps:
    /// @dev - A→base→B should have same slippage as direct A↔B
    /// @dev - virtualDepth makes base appear as deep/shallow as the real asset
    /// @dev Example: If A has 1000 reserves, base has 100, depthMult = 10 → base appears 10x deeper
    /// @param token Token address (used to compute effective depth)
    /// @param virtualDepth If non-zero, overrides effective depth calculation
    function _segmentPriceWithDepth(
        address token,
        IBAMM.Asset storage asset,
        IBAMM.LiquidityProfile storage prof,
        IOracle.DecodedFeedData memory data,
        uint256 amount,
        uint256 virtualDepth
    ) private view returns (uint256) {
        if (data.priceSlow == 0) return M.PRICE_PRECISION;
        if (asset.segmentCount <= 1 || asset.reserves == 0) return data.priceSlow;

        // Limit amount to prevent DoS
        uint256 maxAmount = uint256(asset.reserves) * 100;
        if (amount > maxAmount) amount = maxAmount;

        // Calculate effective depth:
        // - If virtualDepth specified (triangulated swaps), use it
        // - Otherwise, use coverage-aware effective depth based on decayed liabilities
        uint256 effectiveDepth = virtualDepth > 0 ? virtualDepth : _depthForPricing(token);

        // Use Makima pricing with effective depth
        (, uint256 avgPrice) = MakimaP.quoteSwap(
            amount,
            effectiveDepth,
            prof,
            data.priceSlow,
            data.volBaseline,
            asset.segmentCount
        );

        return avgPrice;
    }

    // ========== PORTFOLIO CALCULATIONS ==========

    function calculateTotalValue(
        address[] storage registeredAssets,
        mapping(address => IBAMM.Asset) storage assets,
        mapping(bytes32 => IInternalOracle.InternalFeedData) storage oracleEntries,
        address baseToken
    ) internal view returns (uint256 total) {
        uint256 length = registeredAssets.length;
        for (uint256 i = 0; i < length; i++) {
            address token = registeredAssets[i];
            IBAMM.Asset storage asset = assets[token];
            bytes32 feedId = S.computeOracleId(token, baseToken);
            IInternalOracle.InternalFeedData storage oracle = oracleEntries[feedId];

            if (block.timestamp - oracle.base.updatedAt > 1 hours) continue;

            uint256 price = getFastPrice(oracle);
            if (price > 0) {
                total += FPMath.fullMulDiv(asset.reserves, price, M.PRICE_PRECISION);
            }
        }
    }

    function calculateTotalLiabilities(
        address[] storage registeredAssets,
        mapping(address => IBAMM.Asset) storage assets,
        mapping(bytes32 => IInternalOracle.InternalFeedData) storage oracleEntries,
        address baseToken
    ) internal view returns (uint256 total) {
        uint256 length = registeredAssets.length;
        for (uint256 i = 0; i < length; i++) {
            address token = registeredAssets[i];
            IBAMM.Asset storage asset = assets[token];
            bytes32 feedId = S.computeOracleId(token, baseToken);
            IInternalOracle.InternalFeedData storage oracle = oracleEntries[feedId];

            if (block.timestamp - oracle.base.updatedAt > 1 hours) continue;

            uint256 price = getFastPrice(oracle);
            if (price > 0) {
                total += FPMath.fullMulDiv(asset.liabilities, price, M.PRICE_PRECISION);
            }
        }
    }

    function updateTotalValueDelta(
        uint256 totalValue,
        IBAMM.Asset storage, // asset
        IInternalOracle.InternalFeedData storage oracle,
        int256 delta
    ) internal view returns (uint256) {
        if (delta == 0) return totalValue;

        uint256 price = getFastPrice(oracle);
        if (price == 0) return totalValue;

        int256 valueDelta = int256(FPMath.fullMulDiv(uint256(delta > 0 ? delta : -delta), price, M.PRICE_PRECISION));

        if (delta < 0) valueDelta = -valueDelta;

        int256 newValue = int256(totalValue) + valueDelta;
        return newValue > 0 ? uint256(newValue) : 0;
    }

    function updateTotalLiabilitiesDelta(
        uint256 totalLiabilities,
        IBAMM.Asset storage, // asset
        IInternalOracle.InternalFeedData storage oracle,
        int256 delta
    ) internal view returns (uint256) {
        if (delta == 0) return totalLiabilities;

        uint256 price = getFastPrice(oracle);
        if (price == 0) return totalLiabilities;

        int256 liabDelta = int256(FPMath.fullMulDiv(uint256(delta > 0 ? delta : -delta), price, M.PRICE_PRECISION));

        if (delta < 0) liabDelta = -liabDelta;

        int256 newLiab = int256(totalLiabilities) + liabDelta;
        return newLiab > 0 ? uint256(newLiab) : 0;
    }

    function calculateWithdrawalFee(IBAMM.Asset storage asset) internal view returns (uint256) {
        return asset.fees.withdrawalFeeBps;
    }
}
