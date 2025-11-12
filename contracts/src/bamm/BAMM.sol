// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IBAMMHooks} from "../interfaces/IBAMMHooks.sol";
import {ERC1155} from "solady/tokens/ERC1155.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {BAMMErrors as E} from "./BAMMEvents.sol";
import {BAMMEvents as Events} from "./BAMMEvents.sol";
import {LibPricing as P} from "../libraries/LibPricing.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";
import {LibUtils} from "../libraries/LibUtils.sol";
import {LibStorage} from "../libraries/LibStorage.sol";
import {InternalOracle} from "./InternalOracle.sol";
import {BAMMManagement} from "./BAMMManagement.sol";
import {BAMMFlashLender} from "./BAMMFlashLender.sol";

/// @title BAMM
/// @notice Balanced Automated Market Maker with dynamic fees and internal oracle
contract BAMM is ERC1155, InternalOracle, BAMMManagement, BAMMFlashLender {
    using SafeTransferLib for address;
    using LibUtils for uint256;
    using LibUtils for address;

    // ========== STORAGE ACCESS IMPLEMENTATIONS ==========

    /// @notice Get full storage struct (required by BAMMManagement)
    function _s() internal pure override(BAMMManagement, BAMMFlashLender) returns (LibStorage.BAMMStorage storage) {
        return LibStorage.getStorage();
    }

    /// @notice Get asset storage for given token (required by InternalOracle & BAMMManagement & BAMMFlashLender)
    function _getAsset(address token) internal view override(InternalOracle, BAMMManagement, BAMMFlashLender) returns (IBAMM.Asset storage) {
        return _s().assets[token];
    }

    /// @notice Get fast TWAP for asset (required by BAMMManagement)
    function _getFastTWAP(address token, IBAMM.Asset storage asset) internal view override returns (uint64) {
        return super._getFastTWAP(token, asset);
    }

    /// @notice Get registered assets (required by InternalOracle & BAMMManagement)
    function _getRegisteredAssets() internal view override(InternalOracle, BAMMManagement) returns (address[] memory) {
        return _s().registeredAssets;
    }

    /// @notice Check if pool is paused (required by BAMMFlashLender)
    function _isPoolPaused() internal view override returns (bool) {
        return _s().isPoolPaused;
    }

    /// @notice Get fast TWAP weight (required by InternalOracle)
    function _getFastTWAPWeight() internal view override(InternalOracle) returns (uint8) {
        return _s().fastTWAPWeight;
    }

    /// @notice Get slow TWAP weight (required by InternalOracle)
    function _getSlowTWAPWeight() internal view override(InternalOracle) returns (uint8) {
        return _s().slowTWAPWeight;
    }

    /// @notice Get token decimals (required by BAMMManagement)
    function _getDecimals(address token) internal view override returns (uint8) {
        if (token.code.length == 0) revert E.InvalidParameter();
        // Use selector instead of signature for gas efficiency (0x313ce567 = decimals())
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(0x313ce567));
        return success && data.length >= 32 ? abi.decode(data, (uint8)) : 18;
    }

    /// @notice Get oracle entry for given oracle ID (required by InternalOracle)
    function _getOracleEntry(bytes32 oracleId) internal view override returns (LibStorage.OracleEntry storage) {
        return _s().oracleEntries[oracleId];
    }

    // ========== MODIFIERS ==========

    modifier notFrozen(address token) {
        if (_s().assets[token].isFrozen) revert E.AssetFrozen();
        _;
    }

    // ========== INITIALIZATION ==========

    // NOTE: _updateAlloc removed - ALM model uses coverage-based fees, not target allocations

    // ========== USER FUNCTIONS ==========

    function swap(
        address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address receiver
    ) external override nonReentrant notPaused returns (uint256 amountOut) {
        if (tokenIn == tokenOut) revert E.InvalidParameter();
        LibUtils.requireNonZero(amountIn);
        LibUtils.requireNonZero(receiver);

        LibStorage.BAMMStorage storage $ = _s();

        // Check blacklist for both sender and receiver
        if ($.blacklisted[msg.sender]) revert E.Blacklisted();
        if ($.blacklisted[receiver]) revert E.Blacklisted();

        Asset storage assetIn = $.assets[tokenIn];
        Asset storage assetOut = $.assets[tokenOut];

        LibUtils.requireActive(assetIn);
        LibUtils.requireActive(assetOut);

        address base = $.baseToken;

        // Hub-and-spoke routing: if neither token is base, route through base (inline two-leg execution)
        if (tokenIn != base && tokenOut != base) {
            Asset storage assetBase = $.assets[base];
            LibUtils.requireActive(assetBase);

            // Use cached total value
            uint256 totalValue = $.cachedTotalValue;
            if (totalValue == 0) {
                totalValue = P.calculateTotalValue($.registeredAssets, $.assets, $.oracleEntries);
                $.cachedTotalValue = totalValue;
            }

            // Get oracle entries for all three assets
            LibStorage.OracleEntry storage oracleIn = $.oracleEntries[assetIn.oracleId];
            LibStorage.OracleEntry storage oracleBase = $.oracleEntries[assetBase.oracleId];
            LibStorage.OracleEntry storage oracleOut = $.oracleEntries[assetOut.oracleId];

            // Calculate notionals for fee calculation (decode TWAPs inline)
            uint256 timeElapsedIn = block.timestamp - oracleIn.lastOracleUpdate;
            uint256 currentAccumIn = oracleIn.priceAccumulator + (uint256(oracleIn.currentPrice) * timeElapsedIn);
            uint256 timeDeltaIn = block.timestamp - oracleIn.fastSnapshotTime;
            uint64 fastTWAPIn = timeDeltaIn == 0 ? oracleIn.currentPrice : uint64((currentAccumIn - oracleIn.fastAccumSnapshot) / timeDeltaIn);
            uint256 inFast = M.b64ToPrice(fastTWAPIn);

            uint256 timeElapsedBase = block.timestamp - oracleBase.lastOracleUpdate;
            uint256 currentAccumBase = oracleBase.priceAccumulator + (uint256(oracleBase.currentPrice) * timeElapsedBase);
            uint256 timeDeltaBase = block.timestamp - oracleBase.fastSnapshotTime;
            uint64 fastTWAPBase = timeDeltaBase == 0 ? oracleBase.currentPrice : uint64((currentAccumBase - oracleBase.fastAccumSnapshot) / timeDeltaBase);
            uint256 baseFast = M.b64ToPrice(fastTWAPBase);

            uint256 timeElapsedOut = block.timestamp - oracleOut.lastOracleUpdate;
            uint256 currentAccumOut = oracleOut.priceAccumulator + (uint256(oracleOut.currentPrice) * timeElapsedOut);
            uint256 timeDeltaOut = block.timestamp - oracleOut.fastSnapshotTime;
            uint64 fastTWAPOut = timeDeltaOut == 0 ? oracleOut.currentPrice : uint64((currentAccumOut - oracleOut.fastAccumSnapshot) / timeDeltaOut);
            uint256 outFast = M.b64ToPrice(fastTWAPOut);

            uint256 leg1Notional = FixedPointMathLib.fullMulDiv(amountIn, inFast, M.PRICE_PRECISION);
            uint256 leg2Notional = FixedPointMathLib.fullMulDiv(leg1Notional, baseFast, outFast);

            // TWO-LEG HUB ROUTING: Calculate fees for each leg separately using tri-factor model

            // Leg 1: tokenIn → base (use cached liabilities)
            uint256 totalLiabilities = $.cachedTotalLiabilities;
            FeeComponents memory fees1 = P.calculateSwapFee(
                assetIn, assetBase,
                $.liquidityProfiles[tokenIn], $.liquidityProfiles[base],
                oracleIn, oracleBase,
                $.feeParams,
                amountIn,
                totalValue,
                totalLiabilities
            );

            // Leg 2: base → tokenOut (calculate notional after leg 1 fee)
            uint256 amountAfterFee1Temp = (amountIn * (M.BPS_PRECISION - fees1.totalFeeBps)) / M.BPS_PRECISION;
            uint256 priceInTemp = P.getSegmentPrice(assetIn, $.liquidityProfiles[tokenIn], $.feeParams, oracleIn, amountAfterFee1Temp);
            uint256 priceBaseTemp = P.getSegmentPrice(assetBase, $.liquidityProfiles[base], $.feeParams, oracleBase, 0);
            uint256 leg2InputNotional = priceBaseTemp > 0
                ? FixedPointMathLib.mulDiv(amountAfterFee1Temp, priceInTemp, priceBaseTemp)
                : 0;
            leg2InputNotional = M.adjustDecimals(leg2InputNotional, assetIn.decimals, assetBase.decimals);

            FeeComponents memory fees2 = P.calculateSwapFee(
                assetBase, assetOut,
                $.liquidityProfiles[base], $.liquidityProfiles[tokenOut],
                oracleBase, oracleOut,
                $.feeParams,
                leg2InputNotional,
                totalValue,
                totalLiabilities
            );

            // Aggregate fees (notional-weighted average approach)
            uint256 totalNotional = leg1Notional + leg2Notional;
            uint256 aggregatedFeeBps = totalNotional > 0
                ? (fees1.totalFeeBps * leg1Notional + fees2.totalFeeBps * leg2Notional) / totalNotional
                : (fees1.totalFeeBps + fees2.totalFeeBps) / 2;

            // Build aggregate fee components for return
            FeeComponents memory fees = FeeComponents({
                baseFee: (fees1.baseFee + fees2.baseFee) / 2,
                totalFeeBps: aggregatedFeeBps,
                volatilityMultiplier: (fees1.volatilityMultiplier + fees2.volatilityMultiplier) / 2,
                inventoryMultiplier: (fees1.inventoryMultiplier + fees2.inventoryMultiplier) / 2,
                divergenceMultiplier: (fees1.divergenceMultiplier + fees2.divergenceMultiplier) / 2,
                exitInventoryDivergence: 100,
                leg1FeeBps: fees1.totalFeeBps,
                leg2FeeBps: fees2.totalFeeBps,
                leg1Notional: leg1Notional,
                leg2Notional: leg2Notional
            });

            // === LEG 1: tokenIn → base ===
            uint256 amountAfterFee1 = (amountIn * (M.BPS_PRECISION - fees.leg1FeeBps)) / M.BPS_PRECISION;
            uint256 priceIn = P.getSegmentPrice(assetIn, $.liquidityProfiles[tokenIn], $.feeParams, oracleIn, amountAfterFee1);
            uint256 priceBase1 = P.getSegmentPrice(assetBase, $.liquidityProfiles[base], $.feeParams, oracleBase, 0);

            if (priceBase1 == 0) revert E.InvalidPrice();
            uint256 amountBase = FixedPointMathLib.mulDiv(amountAfterFee1, priceIn, priceBase1);
            amountBase = M.adjustDecimals(amountBase, assetIn.decimals, assetBase.decimals);

            // Leg 1 fee distribution
            uint256 totalFee1 = amountIn - amountAfterFee1;
            uint256 protocolFee1 = (totalFee1 * assetIn.protocolFeeBps) / M.BPS_PRECISION;
            uint256 lpFee1 = totalFee1 - protocolFee1;
            uint256 feeForInputLPs1 = lpFee1 >> 1;
            uint256 feeForOutputLPs1 = lpFee1 - feeForInputLPs1;

            // Convert feeForOutputLPs1 to base token
            uint256 feeInBase = 0;
            if (feeForOutputLPs1 > 0 && inFast > 0 && baseFast > 0) {
                uint256 feeValueRaw = FixedPointMathLib.mulDiv(feeForOutputLPs1, inFast, baseFast);
                feeInBase = M.adjustDecimals(feeValueRaw, assetIn.decimals, assetBase.decimals);
            }

            // === LEG 2: base → tokenOut ===
            uint256 amountAfterFee2 = (amountBase * (M.BPS_PRECISION - fees.leg2FeeBps)) / M.BPS_PRECISION;
            uint256 priceBase2 = P.getSegmentPrice(assetBase, $.liquidityProfiles[base], $.feeParams, oracleBase, amountAfterFee2);
            uint256 priceOut = P.getSegmentPrice(assetOut, $.liquidityProfiles[tokenOut], $.feeParams, oracleOut, amountAfterFee2);

            if (priceOut == 0) revert E.InvalidPrice();
            amountOut = FixedPointMathLib.mulDiv(amountAfterFee2, priceBase2, priceOut);
            amountOut = M.adjustDecimals(amountOut, assetBase.decimals, assetOut.decimals);

            if (amountOut < minAmountOut) revert E.SlippageExceeded();

            // Leg 2 fee distribution
            uint256 totalFee2 = amountBase - amountAfterFee2;
            uint256 protocolFee2 = (totalFee2 * assetBase.protocolFeeBps) / M.BPS_PRECISION;
            uint256 lpFee2 = totalFee2 - protocolFee2;
            uint256 feeForInputLPs2 = lpFee2 >> 1;
            uint256 feeForOutputLPs2 = lpFee2 - feeForInputLPs2;

            // Convert feeForOutputLPs2 to tokenOut
            uint256 feeInTokenOut = 0;
            if (feeForOutputLPs2 > 0 && baseFast > 0 && outFast > 0) {
                uint256 feeValueRaw = FixedPointMathLib.mulDiv(feeForOutputLPs2, baseFast, outFast);
                feeInTokenOut = M.adjustDecimals(feeValueRaw, assetBase.decimals, assetOut.decimals);
            }

            // Check reserves for leg 2
            uint256 totalOutRequired = amountOut + feeInTokenOut;
            if (totalOutRequired > assetOut.reserves) revert E.InsufficientReserves();
            if (assetOut.reserves - totalOutRequired < assetOut.minLiquidity) revert E.BelowMinimumLiquidity();

            // Store old reserves for delta calculations
            uint128 oldReservesIn = assetIn.reserves;
            uint128 oldReservesBase = assetBase.reserves;
            uint128 oldReservesOut = assetOut.reserves;

            // Update reserves and indices for all three assets
            // tokenIn: receives amountIn, pays protocol fee
            uint256 lpFeesForIn = feeForInputLPs1 + (feeInBase == 0 ? feeForOutputLPs1 : 0);
            uint256 finalReservesIn = uint256(oldReservesIn) + amountIn - protocolFee1 + lpFeesForIn;
            assetIn.reserves = finalReservesIn.toUint128();

            LPState storage lpStateIn = $.lpStates[tokenIn];
            if (lpFeesForIn > 0 && lpStateIn.totalScaledSupply > 0 && oldReservesIn > 0) {
                uint256 newIndex = FixedPointMathLib.mulDiv(
                    uint256(lpStateIn.liquidityIndex), finalReservesIn, uint256(oldReservesIn)
                );
                lpStateIn.liquidityIndex = newIndex.toUint128();
            }

            // base: receives amountBase, pays amountBase, gets fees from leg 1, pays fees to leg 2
            uint256 lpFeesForBase = feeInBase + feeForInputLPs2 + (feeInTokenOut == 0 ? feeForOutputLPs2 : 0);
            uint256 finalReservesBase = uint256(oldReservesBase) + amountBase - amountBase - protocolFee2 + lpFeesForBase;
            assetBase.reserves = finalReservesBase.toUint128();

            LPState storage lpStateBase = $.lpStates[base];
            if (lpFeesForBase > 0 && lpStateBase.totalScaledSupply > 0 && oldReservesBase > 0) {
                uint256 newIndex = FixedPointMathLib.mulDiv(
                    uint256(lpStateBase.liquidityIndex), finalReservesBase, uint256(oldReservesBase)
                );
                lpStateBase.liquidityIndex = newIndex.toUint128();
            }

            // tokenOut: pays amountOut and feeInTokenOut
            uint256 finalReservesOut = uint256(oldReservesOut) - amountOut - feeInTokenOut;
            assetOut.reserves = finalReservesOut.toUint128();

            if (feeInTokenOut > 0) {
                LPState storage lpStateOut = $.lpStates[tokenOut];
                if (lpStateOut.totalScaledSupply > 0 && oldReservesOut > 0) {
                    uint256 newIndex = FixedPointMathLib.mulDiv(
                        uint256(lpStateOut.liquidityIndex), finalReservesOut, uint256(oldReservesOut)
                    );
                    lpStateOut.liquidityIndex = newIndex.toUint128();
                }
            }

            // Accrue protocol fees
            if (protocolFee1 > 0) $.protocolFees[tokenIn] += protocolFee1;
            if (protocolFee2 > 0) $.protocolFees[base] += protocolFee2;

            // Update cached total value with deltas
            int256 deltaIn = int256(finalReservesIn) - int256(uint256(oldReservesIn));
            int256 deltaBase = int256(finalReservesBase) - int256(uint256(oldReservesBase));
            int256 deltaOut = int256(finalReservesOut) - int256(uint256(oldReservesOut));

            totalValue = P.updateTotalValueDelta(totalValue, assetIn, oracleIn, deltaIn);
            totalValue = P.updateTotalValueDelta(totalValue, assetBase, oracleBase, deltaBase);
            totalValue = P.updateTotalValueDelta(totalValue, assetOut, oracleOut, deltaOut);
            $.cachedTotalValue = totalValue;

            // INVARIANT: Two-leg swap fee conservation (development/testing only)
            assert(finalReservesIn >= oldReservesIn); // Leg 1 inflow
            assert(finalReservesOut <= oldReservesOut); // Leg 2 outflow
            // Base asset should be neutral (receives from leg1, sends to leg2, collects fees)
            // Note: baseReserves may increase/decrease depending on fees collected/paid

            // Pre-buy hook: Pool is about to RECEIVE tokenIn (optional: no-op if hooks not configured)
            if (assetIn.hooks != address(0)) {
                IBAMMHooks(assetIn.hooks).preBuy(tokenIn, msg.sender, amountIn, tokenOut, amountOut, "");
            }

            // Transfers with fee-on-transfer protection
            uint256 balanceInBefore = tokenIn.balanceOf(address(this));
            tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
            uint256 actualAmountIn = tokenIn.balanceOf(address(this)) - balanceInBefore;

            // Adjust reserves if transfer tax was applied
            if (actualAmountIn != amountIn) {
                int256 deficit = int256(amountIn) - int256(actualAmountIn);
                assetIn.reserves = uint128(int128(int256(uint256(assetIn.reserves)) - deficit));
                totalValue = P.updateTotalValueDelta(totalValue, assetIn, oracleIn, -deficit);
                $.cachedTotalValue = totalValue;
            }

            // Post-buy hook: Pool RECEIVED tokenIn (optional: no-op if hooks not configured)
            if (assetIn.hooks != address(0)) {
                IBAMMHooks(assetIn.hooks).postBuy(tokenIn, msg.sender, actualAmountIn, tokenOut, amountOut, "");
            }

            // Pre-sell hook: Pool is about to GIVE tokenOut (optional: no-op if hooks not configured)
            if (assetOut.hooks != address(0)) {
                IBAMMHooks(assetOut.hooks).preSell(tokenOut, msg.sender, actualAmountIn, tokenIn, amountOut, "");
            }

            uint256 balanceOutBefore = tokenOut.balanceOf(receiver);
            tokenOut.safeTransfer(receiver, amountOut);
            uint256 actualAmountOut = tokenOut.balanceOf(receiver) - balanceOutBefore;

            // Post-sell hook: Pool GAVE tokenOut (optional: no-op if hooks not configured)
            if (assetOut.hooks != address(0)) {
                IBAMMHooks(assetOut.hooks).postSell(tokenOut, msg.sender, actualAmountIn, tokenIn, actualAmountOut, "");
            }

            emit Events.Swap(msg.sender, receiver, tokenIn, tokenOut, actualAmountIn, actualAmountOut, fees.totalFeeBps);
            return actualAmountOut;
        }

        // Use cached total value (O(1) - no loop!)
        uint256 totalValue = $.cachedTotalValue;
        if (totalValue == 0) {
            // First operation - initialize cache
            totalValue = P.calculateTotalValue($.registeredAssets, $.assets, $.oracleEntries);
            $.cachedTotalValue = totalValue;
        }

        // Get oracle entries
        LibStorage.OracleEntry storage oracleIn = $.oracleEntries[assetIn.oracleId];
        LibStorage.OracleEntry storage oracleOut = $.oracleEntries[assetOut.oracleId];

        uint256 totalLiabilities = $.cachedTotalLiabilities;
        FeeComponents memory fees = P.calculateSwapFee(
            assetIn, assetOut, $.liquidityProfiles[tokenIn], $.liquidityProfiles[tokenOut],
            oracleIn, oracleOut, $.feeParams, amountIn, totalValue, totalLiabilities
        );
        uint256 amountAfterFee = (amountIn * (M.BPS_PRECISION - fees.totalFeeBps)) / M.BPS_PRECISION;
        uint256 priceIn = P.getSegmentPrice(assetIn, $.liquidityProfiles[tokenIn], $.feeParams, oracleIn, amountAfterFee);
        uint256 priceOut = P.getSegmentPrice(assetOut, $.liquidityProfiles[tokenOut], $.feeParams, oracleOut, 0);

        if (priceOut == 0) revert E.InvalidPrice();
        // Use mulDiv for precise calculation, avoiding intermediate overflow
        amountOut = FixedPointMathLib.mulDiv(amountAfterFee, priceIn, priceOut);

        // Adjust for decimal differences using LibMaths (avoids expensive EXP opcode)
        amountOut = M.adjustDecimals(amountOut, assetIn.decimals, assetOut.decimals);

        if (amountOut == 0) revert E.ZeroAmount();
        if (amountOut < minAmountOut) revert E.SlippageExceeded();

        uint256 totalFee = amountIn - amountAfterFee;

        // Split fee between protocol and LPs (per-asset protocol fee)
        uint256 protocolFee = (totalFee * assetIn.protocolFeeBps) / M.BPS_PRECISION;
        uint256 lpFee = totalFee - protocolFee;

        // Split LP fee 50/50 between input and output LPs
        uint256 feeForInputLPs;
        uint256 feeForOutputLPs;
        unchecked {
            // SAFE: Bit shift for division by 2
            feeForInputLPs = lpFee >> 1;
            feeForOutputLPs = lpFee - feeForInputLPs;
        }
        uint256 feeInTokenOut = 0;

        uint64 fastTWAPIn = _getFastTWAP(tokenIn, assetIn);
        uint64 fastTWAPOut = _getFastTWAP(tokenOut, assetOut);
        if (feeForOutputLPs > 0 && fastTWAPIn > 0 && fastTWAPOut > 0) {
            // Use mulDiv for precise fee conversion, then adjust decimals
            uint256 feeValueRaw = FixedPointMathLib.mulDiv(feeForOutputLPs, fastTWAPIn, fastTWAPOut);
            feeInTokenOut = M.adjustDecimals(feeValueRaw, assetIn.decimals, assetOut.decimals);
        }

        // Accrue protocol fee (tracked separately, not in reserves)
        if (protocolFee > 0) {
            $.protocolFees[tokenIn] += protocolFee;
        }

        uint256 totalOutRequired = amountOut + feeInTokenOut;
        if (totalOutRequired > assetOut.reserves) revert E.InsufficientReserves();
        if (assetOut.reserves - totalOutRequired < assetOut.minLiquidity) revert E.BelowMinimumLiquidity();

        // Store old reserves to calculate deltas
        uint128 oldReservesIn = assetIn.reserves;
        uint128 oldReservesOut = assetOut.reserves;

        // Optimization #1: Calculate final reserves once, write once (eliminates redundant SSTOREs)
        // Old approach: write reserves, then accrueFeesToLPs overwrites reserves (2-3 SSTOREs per asset)
        // New approach: calculate final reserves including all fees, write once (1 SSTORE per asset)

        uint256 lpFeesForIn = feeForInputLPs + (feeInTokenOut == 0 ? feeForOutputLPs : 0);
        uint256 finalReservesIn = uint256(oldReservesIn) + amountIn - protocolFee + lpFeesForIn;
        uint256 finalReservesOut = uint256(oldReservesOut) - amountOut - feeInTokenOut;

        // Single SSTORE per asset
        assetIn.reserves = finalReservesIn.toUint128();
        assetOut.reserves = finalReservesOut.toUint128();

        // Update liquidity indices (accrueFeesToLPs logic inlined without modifying reserves)
        LPState storage lpStateIn = $.lpStates[tokenIn];
        if (lpFeesForIn > 0 && lpStateIn.totalScaledSupply > 0 && oldReservesIn > 0) {
            uint256 newIndex = FixedPointMathLib.mulDiv(
                uint256(lpStateIn.liquidityIndex),
                finalReservesIn,
                uint256(oldReservesIn)
            );
            lpStateIn.liquidityIndex = newIndex.toUint128();
        }

        if (feeInTokenOut > 0) {
            LPState storage lpStateOut = $.lpStates[tokenOut];
            if (lpStateOut.totalScaledSupply > 0 && oldReservesOut > 0) {
                uint256 newIndex = FixedPointMathLib.mulDiv(
                    uint256(lpStateOut.liquidityIndex),
                    finalReservesOut,
                    uint256(oldReservesOut)
                );
                lpStateOut.liquidityIndex = newIndex.toUint128();
            }
        }

        // Update cached total value with deltas (O(1) - no loop!)
        int256 deltaIn = int256(uint256(assetIn.reserves)) - int256(uint256(oldReservesIn));
        int256 deltaOut = int256(uint256(assetOut.reserves)) - int256(uint256(oldReservesOut));

        totalValue = P.updateTotalValueDelta(totalValue, assetIn, oracleIn, deltaIn);
        totalValue = P.updateTotalValueDelta(totalValue, assetOut, oracleOut, deltaOut);
        $.cachedTotalValue = totalValue;

        // INVARIANT: Fee conservation check (development/testing only)
        // Total input = total output + protocol fees + LP fees
        // Note: In production, these assertions should be removed or gated by DEBUG flag
        uint256 totalFeesAccounted = protocolFee + lpFeesForIn;
        assert(finalReservesIn >= oldReservesIn); // Inflow check
        assert(finalReservesOut <= oldReservesOut); // Outflow check
        // Fee accounting: reserves increased by (amountIn - protocolFee + lpFees)
        // This is already enforced by the calculation, but we assert for safety
        assert(finalReservesIn == uint256(oldReservesIn) + amountIn - protocolFee + lpFeesForIn);
        assert(finalReservesOut == uint256(oldReservesOut) - amountOut - feeInTokenOut);

        // Pre-buy hook: Pool is about to RECEIVE tokenIn (optional: no-op if hooks not configured)
        if (assetIn.hooks != address(0)) {
            IBAMMHooks(assetIn.hooks).preBuy(tokenIn, msg.sender, amountIn, tokenOut, amountOut, "");
        }

        // Fee-on-transfer protection: measure actual received amount
        uint256 balanceInBefore = tokenIn.balanceOf(address(this));
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 actualAmountIn = tokenIn.balanceOf(address(this)) - balanceInBefore;

        // If actual received differs from requested, adjust reserves
        if (actualAmountIn != amountIn) {
            int256 deficit = int256(amountIn) - int256(actualAmountIn);
            assetIn.reserves = uint128(int128(int256(uint256(assetIn.reserves)) - deficit));
            $.cachedTotalValue = P.updateTotalValueDelta($.cachedTotalValue, assetIn, oracleIn, -deficit);
        }

        // Post-buy hook: Pool RECEIVED tokenIn (optional: no-op if hooks not configured)
        if (assetIn.hooks != address(0)) {
            IBAMMHooks(assetIn.hooks).postBuy(tokenIn, msg.sender, actualAmountIn, tokenOut, amountOut, "");
        }

        // Pre-sell hook: Pool is about to GIVE tokenOut (optional: no-op if hooks not configured)
        if (assetOut.hooks != address(0)) {
            IBAMMHooks(assetOut.hooks).preSell(tokenOut, msg.sender, actualAmountIn, tokenIn, amountOut, "");
        }

        // Fee-on-transfer protection: measure actual sent amount
        uint256 balanceOutBefore = tokenOut.balanceOf(receiver);
        tokenOut.safeTransfer(receiver, amountOut);
        uint256 actualAmountOut = tokenOut.balanceOf(receiver) - balanceOutBefore;

        // Post-sell hook: Pool GAVE tokenOut (optional: no-op if hooks not configured)
        if (assetOut.hooks != address(0)) {
            IBAMMHooks(assetOut.hooks).postSell(tokenOut, msg.sender, actualAmountIn, tokenIn, actualAmountOut, "");
        }

        emit Events.Swap(msg.sender, receiver, tokenIn, tokenOut, actualAmountIn, actualAmountOut, fees.totalFeeBps);
    }

    /// @notice Execute multiple swaps with optimized delta settlement
    /// @dev Accumulates all reserve/index changes in memory, applies once per token at end
    /// @dev Optimizations:
    ///      - Eliminates redundant SSTOREs (from 7-9 per swap to 2-3 per swap)
    ///      - When token repeats N times: saves ~3N SSTOREs (only 3 SSTOREs total)
    ///      - Single total value calc + batch transfers
    /// @param steps Array of swap steps
    /// @param receiver Address to receive final output
    /// @return amounts Output amounts for each step
    function batchSwap(
        SwapStep[] calldata steps,
        address receiver
    ) external override nonReentrant notPaused returns (uint256[] memory amounts) {
        if (steps.length == 0 || steps.length > 8) revert E.InvalidParameter();
        LibUtils.requireNonZero(receiver);

        LibStorage.BAMMStorage storage $ = _s();

        // Single blacklist check for sender and receiver
        if ($.blacklisted[msg.sender]) revert E.Blacklisted();
        if ($.blacklisted[receiver]) revert E.Blacklisted();

        amounts = new uint256[](steps.length);
        address[] memory path = new address[](steps.length + 1);

        // Cache total value (calculated once, reused for all swaps)
        uint256 totalValue = $.cachedTotalValue;
        if (totalValue == 0) {
            totalValue = P.calculateTotalValue($.registeredAssets, $.assets, $.oracleEntries);
            $.cachedTotalValue = totalValue;
        }

        // Track first input and last output for batch transfers
        address firstTokenIn = address(0);
        address lastTokenOut = address(0);
        uint256 totalFirstTokenIn = 0;

        // Optimization #2: Delta tracking for cross-swap batching (max 16 unique tokens per batch)
        // Use parallel arrays since Solidity doesn't support memory mappings
        address[16] memory touchedTokens;
        uint128[16] memory oldReserves;
        uint128[16] memory newReserves;
        uint128[16] memory oldIndices;
        uint128[16] memory newIndices;
        uint256 touchedCount = 0;

        // Execute swaps and accumulate deltas (deferred SSTOREs)
        for (uint256 i = 0; i < steps.length; i++) {
            SwapStep calldata step = steps[i];

            if (step.tokenIn == step.tokenOut) revert E.InvalidParameter();

            path[i] = step.tokenIn;
            if (i == steps.length - 1) path[i + 1] = step.tokenOut;

            // Determine input amount (0 = use previous output for chaining)
            uint256 amountIn = step.amountIn;
            if (amountIn == 0) {
                if (i == 0) revert E.ZeroAmount(); // First step must have explicit amount
                if (step.tokenIn != steps[i - 1].tokenOut) revert E.InvalidParameter(); // Chaining requires matching tokens
                amountIn = amounts[i - 1]; // Use previous output
            }

            if (i == 0) {
                firstTokenIn = step.tokenIn;
                totalFirstTokenIn = amountIn;
            }

            Asset storage assetIn = $.assets[step.tokenIn];
            Asset storage assetOut = $.assets[step.tokenOut];

            LibUtils.requireActive(assetIn);
            LibUtils.requireActive(assetOut);

            // Get or initialize token tracking
            uint256 idxIn = type(uint256).max;
            uint256 idxOut = type(uint256).max;

            for (uint256 j = 0; j < touchedCount; j++) {
                if (touchedTokens[j] == step.tokenIn) idxIn = j;
                if (touchedTokens[j] == step.tokenOut) idxOut = j;
            }

            // Initialize tracking for tokenIn if first time
            if (idxIn == type(uint256).max) {
                if (touchedCount >= 16) revert E.InvalidParameter(); // Max tokens exceeded
                idxIn = touchedCount;
                touchedTokens[touchedCount] = step.tokenIn;
                oldReserves[touchedCount] = assetIn.reserves;
                newReserves[touchedCount] = assetIn.reserves;
                oldIndices[touchedCount] = $.lpStates[step.tokenIn].liquidityIndex;
                newIndices[touchedCount] = $.lpStates[step.tokenIn].liquidityIndex;
                touchedCount++;
            }

            // Initialize tracking for tokenOut if first time
            if (idxOut == type(uint256).max) {
                if (touchedCount >= 16) revert E.InvalidParameter(); // Max tokens exceeded
                idxOut = touchedCount;
                touchedTokens[touchedCount] = step.tokenOut;
                oldReserves[touchedCount] = assetOut.reserves;
                newReserves[touchedCount] = assetOut.reserves;
                oldIndices[touchedCount] = $.lpStates[step.tokenOut].liquidityIndex;
                newIndices[touchedCount] = $.lpStates[step.tokenOut].liquidityIndex;
                touchedCount++;
            }

            // Use virtual reserves for calculations (accumulated state)
            uint128 currentReservesIn = newReserves[idxIn];
            uint128 currentReservesOut = newReserves[idxOut];

            // Get oracle entries
            LibStorage.OracleEntry storage oracleIn = $.oracleEntries[assetIn.oracleId];
            LibStorage.OracleEntry storage oracleOut = $.oracleEntries[assetOut.oracleId];

            // Calculate swap (using cached totalValue)
            uint256 totalLiabilities = $.cachedTotalLiabilities;
            FeeComponents memory fees = P.calculateSwapFee(
                assetIn, assetOut, $.liquidityProfiles[step.tokenIn], $.liquidityProfiles[step.tokenOut],
                oracleIn, oracleOut, $.feeParams, amountIn, totalValue, totalLiabilities
            );

            uint256 amountAfterFee = (amountIn * (M.BPS_PRECISION - fees.totalFeeBps)) / M.BPS_PRECISION;
            uint256 priceIn = P.getSegmentPrice(assetIn, $.liquidityProfiles[step.tokenIn], $.feeParams, oracleIn, amountAfterFee);
            uint256 priceOut = P.getSegmentPrice(assetOut, $.liquidityProfiles[step.tokenOut], $.feeParams, oracleOut, 0);

            if (priceOut == 0) revert E.InvalidPrice();
            // Use mulDiv for precise calculation, avoiding intermediate overflow
            uint256 amountOut = FixedPointMathLib.mulDiv(amountAfterFee, priceIn, priceOut);

            // Adjust for decimal differences using LibMaths (avoids expensive EXP opcode)
            amountOut = M.adjustDecimals(amountOut, assetIn.decimals, assetOut.decimals);

            if (amountOut == 0) revert E.ZeroAmount();
            if (amountOut < step.minAmountOut) revert E.SlippageExceeded();

            amounts[i] = amountOut;
            if (i == steps.length - 1) lastTokenOut = step.tokenOut;

            // Fee distribution
            uint256 totalFee = amountIn - amountAfterFee;
            uint256 protocolFee = (totalFee * assetIn.protocolFeeBps) / M.BPS_PRECISION;
            uint256 lpFee = totalFee - protocolFee;

            uint256 feeForInputLPs;
            uint256 feeForOutputLPs;
            unchecked {
                feeForInputLPs = lpFee >> 1;
                feeForOutputLPs = lpFee - feeForInputLPs;
            }

            uint256 feeInTokenOut = 0;
            uint64 fastTWAPIn = _getFastTWAP(step.tokenIn, assetIn);
            uint64 fastTWAPOut = _getFastTWAP(step.tokenOut, assetOut);
            if (feeForOutputLPs > 0 && fastTWAPIn > 0 && fastTWAPOut > 0) {
                // Use mulDiv for precise fee conversion, then adjust decimals
                uint256 feeValueRaw = FixedPointMathLib.mulDiv(feeForOutputLPs, fastTWAPIn, fastTWAPOut);
                feeInTokenOut = M.adjustDecimals(feeValueRaw, assetIn.decimals, assetOut.decimals);
            }

            // Protocol fees tracked separately
            if (protocolFee > 0) {
                $.protocolFees[step.tokenIn] += protocolFee;
            }

            // Check reserves using virtual state
            uint256 totalOutRequired = amountOut + feeInTokenOut;
            if (totalOutRequired > currentReservesOut) revert E.InsufficientReserves();
            if (currentReservesOut - totalOutRequired < assetOut.minLiquidity) revert E.BelowMinimumLiquidity();

            // Optimization #1 + #2: Calculate final reserves, accumulate in memory (NO SSTORE yet)
            uint256 lpFeesForIn = feeForInputLPs + (feeInTokenOut == 0 ? feeForOutputLPs : 0);
            uint256 finalReservesIn = uint256(currentReservesIn) + amountIn - protocolFee + lpFeesForIn;
            uint256 finalReservesOut = uint256(currentReservesOut) - amountOut - feeInTokenOut;

            // Update virtual reserves for next iteration (accumulate changes)
            newReserves[idxIn] = finalReservesIn.toUint128();
            newReserves[idxOut] = finalReservesOut.toUint128();

            // Calculate new liquidity indices (accumulate in memory)
            LPState storage lpStateIn = $.lpStates[step.tokenIn];
            if (lpFeesForIn > 0 && lpStateIn.totalScaledSupply > 0 && currentReservesIn > 0) {
                uint256 newIndex = FixedPointMathLib.mulDiv(
                    uint256(newIndices[idxIn]),
                    finalReservesIn,
                    uint256(currentReservesIn)
                );
                newIndices[idxIn] = newIndex.toUint128();
            }

            if (feeInTokenOut > 0) {
                LPState storage lpStateOut = $.lpStates[step.tokenOut];
                if (lpStateOut.totalScaledSupply > 0 && currentReservesOut > 0) {
                    uint256 newIndex = FixedPointMathLib.mulDiv(
                        uint256(newIndices[idxOut]),
                        finalReservesOut,
                        uint256(currentReservesOut)
                    );
                    newIndices[idxOut] = newIndex.toUint128();
                }
            }

            // Update total value with deltas (using virtual state)
            int256 deltaIn = int256(finalReservesIn) - int256(uint256(currentReservesIn));
            int256 deltaOut = int256(finalReservesOut) - int256(uint256(currentReservesOut));

            totalValue = P.updateTotalValueDelta(totalValue, assetIn, oracleIn, deltaIn);
            totalValue = P.updateTotalValueDelta(totalValue, assetOut, oracleOut, deltaOut);
        }

        // Phase 2: Settlement - apply all accumulated changes ONCE per unique token
        // This is where Optimization #2 provides massive savings when tokens repeat
        for (uint256 i = 0; i < touchedCount; i++) {
            address token = touchedTokens[i];
            Asset storage asset = $.assets[token];
            LPState storage lpState = $.lpStates[token];

            // Single SSTORE per asset for entire batch (vs N SSTOREs if token appeared N times)
            asset.reserves = newReserves[i];
            lpState.liquidityIndex = newIndices[i];
        }

        // Update cached total value after all swaps
        $.cachedTotalValue = totalValue;

        // Batch transfers with fee-on-transfer protection
        if (firstTokenIn != address(0)) {
            uint256 balanceInBefore = firstTokenIn.balanceOf(address(this));
            firstTokenIn.safeTransferFrom(msg.sender, address(this), totalFirstTokenIn);
            uint256 actualAmountIn = firstTokenIn.balanceOf(address(this)) - balanceInBefore;

            // Adjust reserves if transfer tax was applied
            if (actualAmountIn != totalFirstTokenIn) {
                Asset storage firstAsset = $.assets[firstTokenIn];
                LibStorage.OracleEntry storage oracleFirstAsset = $.oracleEntries[firstAsset.oracleId];
                int256 deficit = int256(totalFirstTokenIn) - int256(actualAmountIn);
                firstAsset.reserves = uint128(int128(int256(uint256(firstAsset.reserves)) - deficit));
                $.cachedTotalValue = P.updateTotalValueDelta($.cachedTotalValue, firstAsset, oracleFirstAsset, -deficit);
            }
        }

        if (lastTokenOut != address(0)) {
            uint256 finalAmountOut = amounts[amounts.length - 1];
            uint256 balanceOutBefore = lastTokenOut.balanceOf(receiver);
            lastTokenOut.safeTransfer(receiver, finalAmountOut);
            uint256 actualAmountOut = lastTokenOut.balanceOf(receiver) - balanceOutBefore;

            // Update final output amount in array
            if (actualAmountOut != finalAmountOut) {
                amounts[amounts.length - 1] = actualAmountOut;
            }
        }

        emit Events.BatchSwap(msg.sender, receiver, path, amounts);
    }

    function deposit(
        address token, uint256 amount, uint256 minLpTokens
    ) external override nonReentrant notPaused notFrozen(token) returns (uint256 lpTokens) {
        LibUtils.requireNonZero(amount);

        LibStorage.BAMMStorage storage $ = _s();

        // Check blacklist (consistent with swap)
        if ($.blacklisted[msg.sender]) revert E.Blacklisted();
        Asset storage asset = $.assets[token];
        LPState storage lpState = $.lpStates[token];

        if (asset.reserves == 0 && amount < asset.minLiquidity) revert E.BelowMinimumLiquidity();
        if (lpState.liquidityIndex == 0) lpState.liquidityIndex = uint128(M.PRECISION);

        // Pre-deposit hook (optional: no-op if hooks not configured)
        if (asset.hooks != address(0)) {
            IBAMMHooks(asset.hooks).preDeposit(token, msg.sender, amount, "");
        }

        // Apply deposit fee (for LP arbitrage mitigation, default 0)
        uint256 amountAfterFee = amount;
        if (asset.depositFeeBps > 0) {
            uint256 depositFee = (amount * asset.depositFeeBps) / M.BPS_PRECISION;
            amountAfterFee = amount - depositFee;
            // Deposit fees accrue to existing LPs
            P.accrueFeesToLPs(asset, lpState, depositFee);
        }

        lpTokens = lpState.totalScaledSupply == 0 ? amountAfterFee :
            (amountAfterFee * lpState.totalScaledSupply * M.PRECISION) / (uint256(asset.reserves) * lpState.liquidityIndex);

        if (lpTokens < minLpTokens) revert E.SlippageExceeded();

        uint256 scaledAmount = (lpTokens * M.PRECISION) / lpState.liquidityIndex;

        // Store old reserves and liabilities for delta calculation
        uint128 oldReserves = asset.reserves;
        uint128 oldLiabilities = asset.liabilities;

        unchecked {
            // SAFE: Both additions checked by toUint128() which reverts on overflow
            lpState.totalScaledSupply = (lpState.totalScaledSupply + scaledAmount).toUint128();
            asset.reserves = (asset.reserves + amount).toUint128();
            // Track liabilities for coverage ratio (Wombat-style ALM)
            asset.liabilities = (asset.liabilities + amount).toUint128();
        }

        // Update cached total value with delta (O(1) - no loop!)
        LibStorage.OracleEntry storage oracle = $.oracleEntries[asset.oracleId];
        uint256 totalValue = $.cachedTotalValue;
        if (totalValue == 0) {
            // First operation - initialize cache
            totalValue = P.calculateTotalValue($.registeredAssets, $.assets, $.oracleEntries);
        } else {
            int256 delta = int256(uint256(asset.reserves)) - int256(uint256(oldReserves));
            totalValue = P.updateTotalValueDelta(totalValue, asset, oracle, delta);
        }
        $.cachedTotalValue = totalValue;

        // Update cached liabilities with delta
        int256 liabilitiesDelta = int256(uint256(asset.liabilities)) - int256(uint256(oldLiabilities));
        $.cachedTotalLiabilities = P.updateTotalLiabilitiesDelta($.cachedTotalLiabilities, asset, oracle, liabilitiesDelta);

        // Fee-on-transfer protection: measure actual received amount
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 actualAmount = token.balanceOf(address(this)) - balanceBefore;

        // Adjust reserves and LP tokens if transfer tax was applied
        if (actualAmount != amount) {
            uint256 deficit = amount - actualAmount;
            asset.reserves = uint128(uint256(asset.reserves) - deficit);
            asset.liabilities = uint128(uint256(asset.liabilities) - deficit);

            // Recalculate LP tokens based on actual received amount
            uint256 actualLpTokens = lpState.totalScaledSupply == 0 ? actualAmount :
                (actualAmount * lpState.totalScaledSupply * M.PRECISION) / (uint256(asset.reserves) * lpState.liquidityIndex);

            if (actualLpTokens < minLpTokens) revert E.SlippageExceeded();

            // Update totalScaledSupply with corrected amount
            uint256 actualScaledAmount = (actualLpTokens * M.PRECISION) / lpState.liquidityIndex;
            lpState.totalScaledSupply = uint128(uint256(lpState.totalScaledSupply) - (lpTokens - actualLpTokens) * M.PRECISION / lpState.liquidityIndex);

            lpTokens = actualLpTokens;

            // Update cached total value and liabilities with deficit
            int256 deficitDelta = -int256(deficit);
            $.cachedTotalValue = P.updateTotalValueDelta($.cachedTotalValue, asset, oracle, deficitDelta);
            $.cachedTotalLiabilities = P.updateTotalLiabilitiesDelta($.cachedTotalLiabilities, asset, oracle, deficitDelta);
        }

        _mint(msg.sender, token.addressToTokenId(), lpTokens, "");

        // Post-deposit hook (optional: no-op if hooks not configured)
        if (asset.hooks != address(0)) {
            IBAMMHooks(asset.hooks).postDeposit(token, msg.sender, actualAmount, lpTokens, "");
        }

        emit Events.Deposit(msg.sender, token, actualAmount, lpTokens);
    }

    function withdraw(
        address token, uint256 lpTokens, uint256 minAmountOut
    ) external override nonReentrant returns (uint256 amountOut) {
        LibUtils.requireNonZero(lpTokens);

        LibStorage.BAMMStorage storage $ = _s();

        // Check blacklist (consistent with swap)
        if ($.blacklisted[msg.sender]) revert E.Blacklisted();
        Asset storage asset = $.assets[token];
        LPState storage lpState = $.lpStates[token];

        if (lpState.liquidityIndex == 0 || lpState.totalScaledSupply == 0) revert E.NotInitialized();

        // Pre-withdraw hook (optional: no-op if hooks not configured)
        if (asset.hooks != address(0)) {
            IBAMMHooks(asset.hooks).preWithdraw(token, msg.sender, lpTokens, "");
        }

        uint256 scaledAmount;
        unchecked {
            // SAFE: lpTokens * M.PRECISION cannot realistically overflow uint256
            scaledAmount = (lpTokens * M.PRECISION) / lpState.liquidityIndex;
        }
        if ($.scaledBalances[msg.sender][token] < scaledAmount) revert E.InsufficientBalance();

        // Calculate LP's proportional share of liabilities (their claim)
        uint256 liabilityShare = (scaledAmount * lpState.liquidityIndex * asset.liabilities) /
                                 (lpState.totalScaledSupply * M.PRECISION);

        // Calculate coverage ratio: C = reserves / liabilities, clamped to [0, 1]
        // If C >= 1: pool is healthy (over-collateralized), LP gets full claim
        // If C < 1: pool is under-collateralized, LP gets haircutted at coverage ratio
        uint256 coverageRatio = asset.liabilities > 0
            ? (uint256(asset.reserves) * M.PRECISION) / uint256(asset.liabilities)
            : M.PRECISION;

        // Clamp coverage ratio to [0, 1] for withdrawal calculation
        // Coverage > 1 doesn't give bonus, it accumulates as reserves for fees
        if (coverageRatio > M.PRECISION) coverageRatio = M.PRECISION;

        // Apply coverage ratio haircut to liability claim
        // amountOut = liabilityShare * min(C, 1.0)
        // Examples:
        // - C = 1.0 (100%): LP gets 100% of claim (no haircut)
        // - C = 0.5 (50%): LP gets 50% of claim (50% haircut, fair pro-rata loss)
        // - C = 1.5 (150%): LP gets 100% of claim (excess stays as reserves)
        amountOut = (liabilityShare * coverageRatio) / M.PRECISION;

        uint256 withdrawalFeeBps = P.calculateWithdrawalFee(asset);
        if (withdrawalFeeBps > 0) {
            uint256 feeAmount = (amountOut * withdrawalFeeBps) / M.BPS_PRECISION;
            amountOut -= feeAmount;
            P.accrueFeesToLPs(asset, lpState, feeAmount);
        }

        if (amountOut < minAmountOut) revert E.SlippageExceeded();
        if (amountOut > asset.reserves) revert E.InsufficientReserves();
        if (asset.reserves - amountOut < asset.minLiquidity && lpState.totalScaledSupply - scaledAmount > 0) {
            revert E.BelowMinimumLiquidity();
        }

        // Store old reserves and liabilities for delta calculation
        uint128 oldReserves = asset.reserves;
        uint128 oldLiabilities = asset.liabilities;

        unchecked {
            // SAFE: Both subtractions checked by toUint128(), underflow impossible due to prior checks
            lpState.totalScaledSupply = (lpState.totalScaledSupply - scaledAmount).toUint128();
            asset.reserves = (asset.reserves - amountOut).toUint128();
            // Reduce liabilities by LP's proportional share
            // This maintains accurate coverage ratio tracking: C = reserves / liabilities
            asset.liabilities = (asset.liabilities - liabilityShare).toUint128();
        }

        _burn(msg.sender, token.addressToTokenId(), lpTokens);

        // Update cached total value with delta (O(1) - no loop!)
        LibStorage.OracleEntry storage oracle = $.oracleEntries[asset.oracleId];
        uint256 totalValue = $.cachedTotalValue;
        if (totalValue == 0) {
            // Shouldn't happen but handle gracefully
            totalValue = P.calculateTotalValue($.registeredAssets, $.assets, $.oracleEntries);
        } else {
            int256 delta = int256(uint256(asset.reserves)) - int256(uint256(oldReserves));
            totalValue = P.updateTotalValueDelta(totalValue, asset, oracle, delta);
        }
        $.cachedTotalValue = totalValue;

        // Update cached liabilities with delta
        int256 liabilitiesDelta = int256(uint256(asset.liabilities)) - int256(uint256(oldLiabilities));
        $.cachedTotalLiabilities = P.updateTotalLiabilitiesDelta($.cachedTotalLiabilities, asset, oracle, liabilitiesDelta);

        // Fee-on-transfer protection: measure actual sent amount
        uint256 balanceBefore = msg.sender.balance;
        uint256 actualAmountOut;
        if (token == address(0)) {
            // ETH transfer
            balanceBefore = msg.sender.balance;
            token.safeTransfer(msg.sender, amountOut);
            actualAmountOut = msg.sender.balance - balanceBefore;

            // Adjust reserves if transfer tax was applied (shouldn't happen with ETH, but defensive)
            if (actualAmountOut != amountOut) {
                uint256 retained = amountOut - actualAmountOut;
                asset.reserves = uint128(uint256(asset.reserves) + retained);
                int256 retainedDelta = int256(retained);
                $.cachedTotalValue = P.updateTotalValueDelta($.cachedTotalValue, asset, oracle, retainedDelta);
                // Note: Liabilities don't change on fee-on-transfer in withdrawal (already reduced above)
            }
        } else {
            // ERC20 transfer
            balanceBefore = token.balanceOf(msg.sender);
            token.safeTransfer(msg.sender, amountOut);
            actualAmountOut = token.balanceOf(msg.sender) - balanceBefore;

            // Adjust reserves if transfer tax was applied
            if (actualAmountOut != amountOut) {
                uint256 retained = amountOut - actualAmountOut;
                asset.reserves = uint128(uint256(asset.reserves) + retained);
                int256 retainedDelta = int256(retained);
                $.cachedTotalValue = P.updateTotalValueDelta($.cachedTotalValue, asset, oracle, retainedDelta);
                // Note: Liabilities don't change on fee-on-transfer in withdrawal (already reduced above)
            }
        }

        // Post-withdraw hook (optional: no-op if hooks not configured)
        if (asset.hooks != address(0)) {
            IBAMMHooks(asset.hooks).postWithdraw(token, msg.sender, lpTokens, actualAmountOut, "");
        }

        emit Events.Withdraw(msg.sender, token, lpTokens, actualAmountOut, withdrawalFeeBps);
    }

    // ========== ASSET MANAGEMENT ==========


    // ========== VIEW FUNCTIONS ==========

    function baseToken() public view returns (address) { return _s().baseToken; }
    function isPoolPaused() public view returns (bool) { return _s().isPoolPaused; }
    function assets(address token) public view returns (Asset memory) { return _s().assets[token]; }
    function lpStates(address token) public view returns (LPState memory) { return _s().lpStates[token]; }
    function registeredAssets() public view returns (address[] memory) { return _s().registeredAssets; }
    function scaledBalances(address user, address token) public view returns (uint256) {
        return _s().scaledBalances[user][token];
    }

    function getSwapQuote(
        address tokenIn, address tokenOut, uint256 amountIn
    ) external view override returns (uint256 amountOut, uint256 feeBps) {
        LibStorage.BAMMStorage storage $ = _s();
        Asset storage assetIn = $.assets[tokenIn];
        Asset storage assetOut = $.assets[tokenOut];

        if (assetIn.reserves == 0 || assetOut.reserves == 0) return (0, 0);

        address base = $.baseToken;
        uint256 totalValue = P.calculateTotalValue($.registeredAssets, $.assets, $.oracleEntries);

        // Hub-and-spoke routing: if neither token is base, route through base
        if (tokenIn != base && tokenOut != base) {
            Asset storage assetBase = $.assets[base];
            if (assetBase.reserves == 0) return (0, 0);

            // Get oracle entries for all three assets
            LibStorage.OracleEntry storage oracleIn = $.oracleEntries[assetIn.oracleId];
            LibStorage.OracleEntry storage oracleBase = $.oracleEntries[assetBase.oracleId];
            LibStorage.OracleEntry storage oracleOut = $.oracleEntries[assetOut.oracleId];

            // Leg 1: tokenIn → base
            // Calculate fee components first to get fee (decode TWAPs inline)
            uint256 timeElapsedIn = block.timestamp - oracleIn.lastOracleUpdate;
            uint256 currentAccumIn = oracleIn.priceAccumulator + (uint256(oracleIn.currentPrice) * timeElapsedIn);
            uint256 timeDeltaIn = block.timestamp - oracleIn.fastSnapshotTime;
            uint64 fastTWAPIn = timeDeltaIn == 0 ? oracleIn.currentPrice : uint64((currentAccumIn - oracleIn.fastAccumSnapshot) / timeDeltaIn);
            uint256 inFast = M.b64ToPrice(fastTWAPIn);

            uint256 timeElapsedBase = block.timestamp - oracleBase.lastOracleUpdate;
            uint256 currentAccumBase = oracleBase.priceAccumulator + (uint256(oracleBase.currentPrice) * timeElapsedBase);
            uint256 timeDeltaBase = block.timestamp - oracleBase.fastSnapshotTime;
            uint64 fastTWAPBase = timeDeltaBase == 0 ? oracleBase.currentPrice : uint64((currentAccumBase - oracleBase.fastAccumSnapshot) / timeDeltaBase);
            uint256 baseFast = M.b64ToPrice(fastTWAPBase);

            uint256 timeElapsedOut = block.timestamp - oracleOut.lastOracleUpdate;
            uint256 currentAccumOut = oracleOut.priceAccumulator + (uint256(oracleOut.currentPrice) * timeElapsedOut);
            uint256 timeDeltaOut = block.timestamp - oracleOut.fastSnapshotTime;
            uint64 fastTWAPOut = timeDeltaOut == 0 ? oracleOut.currentPrice : uint64((currentAccumOut - oracleOut.fastAccumSnapshot) / timeDeltaOut);
            uint256 outFast = M.b64ToPrice(fastTWAPOut);

            uint256 leg1Notional = FixedPointMathLib.fullMulDiv(amountIn, inFast, M.PRICE_PRECISION);

            // Estimate leg2 notional (rough estimate for fee calculation)
            uint256 leg2Notional = FixedPointMathLib.fullMulDiv(leg1Notional, baseFast, outFast);

            // TWO-LEG HUB ROUTING: Calculate fees for each leg separately using tri-factor model

            // Leg 1: tokenIn → base (use cached liabilities)
            uint256 totalLiabilities = $.cachedTotalLiabilities;
            FeeComponents memory fees1 = P.calculateSwapFee(
                assetIn, assetBase,
                $.liquidityProfiles[tokenIn], $.liquidityProfiles[base],
                oracleIn, oracleBase,
                $.feeParams,
                amountIn,
                totalValue,
                totalLiabilities
            );

            // Leg 2: base → tokenOut (calculate notional after leg 1 fee)
            uint256 amountAfterFee1Temp = (amountIn * (M.BPS_PRECISION - fees1.totalFeeBps)) / M.BPS_PRECISION;
            uint256 priceInTemp = P.getSegmentPrice(assetIn, $.liquidityProfiles[tokenIn], $.feeParams, oracleIn, amountAfterFee1Temp);
            uint256 priceBaseTemp = P.getSegmentPrice(assetBase, $.liquidityProfiles[base], $.feeParams, oracleBase, 0);
            uint256 leg2InputNotional = priceBaseTemp > 0
                ? FixedPointMathLib.mulDiv(amountAfterFee1Temp, priceInTemp, priceBaseTemp)
                : 0;
            leg2InputNotional = M.adjustDecimals(leg2InputNotional, assetIn.decimals, assetBase.decimals);

            FeeComponents memory fees2 = P.calculateSwapFee(
                assetBase, assetOut,
                $.liquidityProfiles[base], $.liquidityProfiles[tokenOut],
                oracleBase, oracleOut,
                $.feeParams,
                leg2InputNotional,
                totalValue,
                totalLiabilities
            );

            // Aggregate fees (notional-weighted average approach)
            uint256 totalNotional = leg1Notional + leg2Notional;
            uint256 aggregatedFeeBps = totalNotional > 0
                ? (fees1.totalFeeBps * leg1Notional + fees2.totalFeeBps * leg2Notional) / totalNotional
                : (fees1.totalFeeBps + fees2.totalFeeBps) / 2;

            // Build aggregate fee components for return
            FeeComponents memory fees = FeeComponents({
                baseFee: (fees1.baseFee + fees2.baseFee) / 2,
                totalFeeBps: aggregatedFeeBps,
                volatilityMultiplier: (fees1.volatilityMultiplier + fees2.volatilityMultiplier) / 2,
                inventoryMultiplier: (fees1.inventoryMultiplier + fees2.inventoryMultiplier) / 2,
                divergenceMultiplier: (fees1.divergenceMultiplier + fees2.divergenceMultiplier) / 2,
                exitInventoryDivergence: 100,
                leg1FeeBps: fees1.totalFeeBps,
                leg2FeeBps: fees2.totalFeeBps,
                leg1Notional: leg1Notional,
                leg2Notional: leg2Notional
            });

            feeBps = fees.totalFeeBps;
            uint256 amountAfterFee1 = (amountIn * (M.BPS_PRECISION - fees.leg1FeeBps)) / M.BPS_PRECISION;

            // Get segment price with amount for leg 1 (input-side piecewise)
            uint256 priceIn = P.getSegmentPrice(assetIn, $.liquidityProfiles[tokenIn], $.feeParams, oracleIn, amountAfterFee1);
            uint256 priceBase = P.getSegmentPrice(assetBase, $.liquidityProfiles[base], $.feeParams, oracleBase, 0);

            if (priceBase == 0) return (0, feeBps);
            uint256 amountBase = FixedPointMathLib.mulDiv(amountAfterFee1, priceIn, priceBase);
            amountBase = M.adjustDecimals(amountBase, assetIn.decimals, assetBase.decimals);

            // Leg 2: base → tokenOut
            uint256 amountAfterFee2 = (amountBase * (M.BPS_PRECISION - fees.leg2FeeBps)) / M.BPS_PRECISION;

            // Get segment price with amount for leg 2 (output-side piecewise - marginal pricing)
            priceBase = P.getSegmentPrice(assetBase, $.liquidityProfiles[base], $.feeParams, oracleBase, amountAfterFee2);
            uint256 priceOut = P.getSegmentPrice(assetOut, $.liquidityProfiles[tokenOut], $.feeParams, oracleOut, amountAfterFee2);

            if (priceOut == 0) return (0, feeBps);
            amountOut = FixedPointMathLib.mulDiv(amountAfterFee2, priceBase, priceOut);
            amountOut = M.adjustDecimals(amountOut, assetBase.decimals, assetOut.decimals);

        } else {
            // Single-leg: direct pair (one is base)
            // Get oracle entries
            LibStorage.OracleEntry storage oracleIn = $.oracleEntries[assetIn.oracleId];
            LibStorage.OracleEntry storage oracleOut = $.oracleEntries[assetOut.oracleId];

            uint256 totalLiabilities = $.cachedTotalLiabilities;
            FeeComponents memory fees = P.calculateSwapFee(
                assetIn, assetOut, $.liquidityProfiles[tokenIn], $.liquidityProfiles[tokenOut],
                oracleIn, oracleOut, $.feeParams, amountIn, totalValue, totalLiabilities
            );
            feeBps = fees.totalFeeBps;

            uint256 amountAfterFee = (amountIn * (M.BPS_PRECISION - feeBps)) / M.BPS_PRECISION;
            uint256 priceIn = P.getSegmentPrice(assetIn, $.liquidityProfiles[tokenIn], $.feeParams, oracleIn, amountAfterFee);
            uint256 priceOut = P.getSegmentPrice(assetOut, $.liquidityProfiles[tokenOut], $.feeParams, oracleOut, 0);

            if (priceOut == 0) return (0, feeBps);
            amountOut = FixedPointMathLib.mulDiv(amountAfterFee, priceIn, priceOut);
            amountOut = M.adjustDecimals(amountOut, assetIn.decimals, assetOut.decimals);
        }
    }

    function getLPValue(address token, uint256 lpTokens) external view override returns (uint256 underlyingAmount) {
        LibStorage.BAMMStorage storage $ = _s();
        LPState storage lpState = $.lpStates[token];

        if (lpState.liquidityIndex == 0) return 0;

        uint256 scaledAmount = (lpTokens * M.PRECISION) / lpState.liquidityIndex;
        underlyingAmount = (scaledAmount * lpState.liquidityIndex * $.assets[token].reserves) /
                         (lpState.totalScaledSupply * M.PRECISION);
    }

    function getTotalValue() external view override returns (uint256) {
        LibStorage.BAMMStorage storage $ = _s();
        return P.calculateTotalValue($.registeredAssets, $.assets, $.oracleEntries);
    }

    function calculateSwapFee(
        address tokenIn, address tokenOut, uint256 amountIn
    ) external view override returns (FeeComponents memory) {
        LibStorage.BAMMStorage storage $ = _s();
        Asset storage assetIn = $.assets[tokenIn];
        Asset storage assetOut = $.assets[tokenOut];
        LibStorage.OracleEntry storage oracleIn = $.oracleEntries[assetIn.oracleId];
        LibStorage.OracleEntry storage oracleOut = $.oracleEntries[assetOut.oracleId];
        uint256 totalValue = P.calculateTotalValue($.registeredAssets, $.assets, $.oracleEntries);
        uint256 totalLiabilities = $.cachedTotalLiabilities;
        return P.calculateSwapFee(
            assetIn, assetOut,
            $.liquidityProfiles[tokenIn], $.liquidityProfiles[tokenOut],
            oracleIn, oracleOut, $.feeParams, amountIn, totalValue, totalLiabilities
        );
    }

    function getLiquidityProfile(address token) external view returns (
        uint8[16] memory weights, int8[17] memory offsets, uint64 minBreadth, uint64 maxBreadth
    ) {
        LiquidityProfile storage profile = _s().liquidityProfiles[token];
        return (profile.segmentWeights, profile.twapOffsets, profile.minBreadth, profile.maxBreadth);
    }

    // ========== ERC1155 OVERRIDES ==========

    function balanceOf(address owner, uint256 id) public view override returns (uint256) {
        LibStorage.BAMMStorage storage $ = _s();
        address token = address(uint160(id));
        LPState storage lpState = $.lpStates[token];
        uint128 index = lpState.liquidityIndex;
        if (index == 0) return 0;

        unchecked {
            // SAFE: Cannot overflow due to LP token supply limits
            return ($.scaledBalances[owner][token] * index) / M.PRECISION;
        }
    }

    function uri(uint256 id) public view override returns (string memory) {
        address token = address(uint160(id));
        return string(abi.encodePacked(
            "https://btr.supply/pool/",
            address(this).toHexString(),
            "/",
            token.toHexString()
        ));
    }

    function _afterTokenTransfer(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal override {
        LibStorage.BAMMStorage storage $ = _s();

        uint256 length = ids.length;
        unchecked {
            for (uint256 i; i < length; ++i) {
                address token = address(uint160(ids[i]));
                LPState storage lpState = $.lpStates[token];

                if (lpState.liquidityIndex == 0) {
                    if (amounts[i] > 0) revert E.NotInitialized();
                    continue;
                }

                uint256 scaledAmount = (amounts[i] * M.PRECISION) / lpState.liquidityIndex;

                if (from != address(0)) {
                    uint256 fromBalance = $.scaledBalances[from][token];
                    if (fromBalance < scaledAmount) revert E.InsufficientBalance();
                    $.scaledBalances[from][token] = fromBalance - scaledAmount;
                }

                if (to != address(0)) {
                    $.scaledBalances[to][token] += scaledAmount;
                }
            }
        }
    }
}
