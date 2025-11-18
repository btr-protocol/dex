// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IInternalOracle} from "../interfaces/IInternalOracle.sol";
import {LibStorage as S} from "../libraries/LibStorage.sol";
import {LibPricing as P} from "../libraries/LibPricing.sol";

/// @title BAMMPricing
/// @notice Pricing facet - delegates to LibPricing for actual logic
/// @dev Delegatecalled from BAMMCore
contract BAMMPricing {

    /// @notice Quote direct swap route (one or two legs with base)
    function quoteRouteDirect(
        address tokenIn,
        address tokenOut,
        address base,
        uint256 amountIn
    ) external view returns (P.RouteQuote memory rq) {
        IBAMM.BAMMStorage storage $ = S.bamm();

        // Fetch all required assets and configs
        IBAMM.Asset storage assetIn = $.assets[tokenIn];
        IBAMM.Asset storage assetOut = $.assets[tokenOut];
        IBAMM.Asset storage assetBase = $.assets[base];

        IInternalOracle.InternalFeedData storage oracleIn = $.internalFeeds[S.computeOracleId(tokenIn, base)];
        IInternalOracle.InternalFeedData storage oracleOut = $.internalFeeds[S.computeOracleId(tokenOut, base)];
        IInternalOracle.InternalFeedData storage oracleBase = $.internalFeeds[S.computeOracleId(base, base)];

        // Call LibPricing with all configs
        rq = P.quoteRoute(
            tokenIn, tokenOut, base, amountIn,
            assetIn, assetOut, assetBase,
            $.liquidityProfiles[tokenIn],
            $.liquidityProfiles[tokenOut],
            $.liquidityProfiles[base],
            oracleIn, oracleOut, oracleBase,
            $.dynamicFeeConfigs[tokenIn]
        );

        return rq;
    }

    /// @notice Quote triangulated swap route (A → base → B)
    function quoteRouteTriangulated(
        address tokenIn,
        address tokenOut,
        address base,
        uint256 amountIn
    ) external view returns (P.RouteQuote memory rq) {
        IBAMM.BAMMStorage storage $ = S.bamm();

        // Fetch all required assets and configs
        IBAMM.Asset storage assetIn = $.assets[tokenIn];
        IBAMM.Asset storage assetOut = $.assets[tokenOut];
        IBAMM.Asset storage assetBase = $.assets[base];

        IInternalOracle.InternalFeedData storage oracleIn = $.internalFeeds[S.computeOracleId(tokenIn, base)];
        IInternalOracle.InternalFeedData storage oracleOut = $.internalFeeds[S.computeOracleId(tokenOut, base)];
        IInternalOracle.InternalFeedData storage oracleBase = $.internalFeeds[S.computeOracleId(base, base)];

        // Call LibPricing
        rq = P.quoteRoute(
            tokenIn, tokenOut, base, amountIn,
            assetIn, assetOut, assetBase,
            $.liquidityProfiles[tokenIn],
            $.liquidityProfiles[tokenOut],
            $.liquidityProfiles[base],
            oracleIn, oracleOut, oracleBase,
            $.dynamicFeeConfigs[tokenIn]
        );

        return rq;
    }
}
