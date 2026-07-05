// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as C} from "./Constants.sol";
import {AnchorTree} from "./AnchorTree.sol";
import {PoolAdmin} from "./PoolAdmin.sol";
import {PoolIO} from "./PoolIO.sol";

/// @title PoolAdminWrite -admin-side state setters extracted from Pool.sol
/// @notice Wave-2 bytecode reduction. Pure refactor; behavior preserved.
///         All fns are `external` → DELEGATECALL'd from Pool's onlyAdmin
///         trampolines. ~700 gas/call extra but admin paths are cold so
///         the trade-off is favorable for ~250 bytes/fn bytecode savings.
library PoolAdminWrite {
    function _requireAsset(IPool.PoolStorage storage $, address t) private view {
        if ($.assets[t].decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
    }

    function freezeAsset(IPool.PoolStorage storage $, address token) external {
        address t = PoolIO.wrap($, token);
        _requireAsset($, t);
        $.riskConfigs[t].flags |= C.FROZEN_BIT;
    }

    function unfreezeAsset(IPool.PoolStorage storage $, address token) external {
        address t = PoolIO.wrap($, token);
        _requireAsset($, t);
        $.riskConfigs[t].flags &= ~C.FROZEN_BIT;
    }

    function pauseAsset(IPool.PoolStorage storage $, address token) external {
        address t = PoolIO.wrap($, token);
        _requireAsset($, t);
        $.riskConfigs[t].flags |= C.PROTOCOL_PAUSED_BIT;
    }

    function unpauseAsset(IPool.PoolStorage storage $, address token) external {
        address t = PoolIO.wrap($, token);
        _requireAsset($, t);
        $.riskConfigs[t].flags &= ~C.PROTOCOL_PAUSED_BIT; // clears ONLY bit6 — an independent FROZEN survives
    }

    function initAsset(
        IPool.PoolStorage storage $,
        address self,
        address token,
        IPool.OracleConfig calldata oracleCfg,
        IPool.RiskConfig calldata riskCfg,
        IPool.LiquidityProfile calldata profile,
        uint16 minFeeBps,
        uint8 decimals,
        uint32 minDispersion,
        uint32 maxDispersion,
        uint16 gamma,
        uint16 vega
    ) external {
        address t = PoolIO.wrap($, token);
        if ($.assets[t].decimals != 0) revert Err.AlreadyConfigured(Err.Resource.ASSET, t);

        PoolAdmin.validateProfileMemory(profile);
        PoolAdmin.validateOracleConfig(oracleCfg, self);
        PoolAdmin.initAsset($, t, decimals, minFeeBps, minDispersion, maxDispersion, gamma, vega);
        PoolAdmin.setupOracleAndConfig($, t, oracleCfg, riskCfg, profile);
    }

    function setFlowCooldown(IPool.PoolStorage storage $, uint16 cooldownSeconds) external {
        $.flowCooldownSeconds = cooldownSeconds;
    }

    function setAnchor(IPool.PoolStorage storage $, address token, address anchor) external {
        address t = PoolIO.wrap($, token);
        IPool.Asset storage asset = $.assets[t];
        if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
        uint8 depth = AnchorTree.validateAnchor($, t, anchor);
        asset.anchor = anchor;
        asset.anchorDepth = depth;
    }

    function setAssetParams(
        IPool.PoolStorage storage $,
        address token,
        uint128 minLiquidity,
        uint16 minFeeBps,
        uint16 maxFeeBps,
        uint16 gamma,
        uint16 vega,
        uint16 haircutSuppressor,
        uint64 reservationPrice,
        uint64 reservationPriceMax
    ) external {
        address t = PoolIO.wrap($, token);
        IPool.Asset storage asset = $.assets[t];
        if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
        if (minFeeBps > maxFeeBps) revert Err.InvalidInput();
        if (reservationPriceMax != 0 && reservationPriceMax < reservationPrice) revert Err.InvalidInput();

        asset.minLiquidity = minLiquidity;
        asset.minFeeBps = minFeeBps;
        asset.maxFeeBps = maxFeeBps;
        asset.gamma = gamma;
        asset.vega = vega;
        asset.haircutSuppressor = haircutSuppressor;
        asset.reservationPrice = reservationPrice;
        asset.reservationPriceMax = reservationPriceMax;
    }

    function setRiskConfig(IPool.PoolStorage storage $, address token, IPool.RiskConfig calldata cfg) external {
        address t = PoolIO.wrap($, token);
        _requireAsset($, t);
        // Halt bits survive config writes: a freeze/pause raised during the timelock window must not
        // be cleared (nor sneaked in) by executing a queued RiskConfig — only the explicit
        // unfreeze/unpause ops touch HALT_MASK.
        uint16 halt = $.riskConfigs[t].flags & C.HALT_MASK;
        $.riskConfigs[t] = cfg;
        $.riskConfigs[t].flags = (cfg.flags & ~C.HALT_MASK) | halt;
    }

    function setOracleConfig(IPool.PoolStorage storage $, address self, address token, IPool.OracleConfig calldata cfg) external {
        PoolAdmin.validateOracleConfig(cfg, self);
        $.oracleConfigs[token] = cfg;
    }

    function setFeeParams(IPool.PoolStorage storage $, IPool.FeeParams calldata params) external {
        if (params.protoShare > 100) revert Err.InvalidInput();
        $.feeParams = params;
    }

    function setBridge(IPool.PoolStorage storage $, address newBridge) external {
        $.bridge = newBridge;
    }

    function setTreasury(IPool.PoolStorage storage $, address newTreasury) external {
        if (newTreasury == address(0)) revert Err.ZeroValue();
        $.treasury = newTreasury;
    }

    function setBaseToken(IPool.PoolStorage storage $, address newBase) external {
        $.baseToken = newBase;
    }

    /// @notice R44-2 (T3-HIGH2): set base-token oracle for depeg detection. `oracle == address(0)`
    ///         clears the configuration → fallback to pre-Pass-44A 1e18-hardcoded stable-base path
    ///         (no halt). When set, Pricing reads base price and reverts swaps if deviation from
    ///         1e18 exceeds `Constants.BASE_DEPEG_HALT_BPS`.
    function setBaseTokenOracle(IPool.PoolStorage storage $, address oracle, bytes32 feedId) external {
        $.baseTokenOracle = oracle;
        $.baseTokenFeedId = feedId;
    }
}
