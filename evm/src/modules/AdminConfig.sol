// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Base} from "./Base.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Err} from "@btr-peripheral/Errors.sol";
import {IAdminConfig} from "../interfaces/modules/IAdminConfig.sol";
import {IPool} from "../interfaces/IPool.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {InternalOracle} from "./InternalOracle.sol";
import {LibAnchorTree} from "../libraries/LibAnchorTree.sol";

/// @title AdminConfig
/// @notice Non-timelocked admin: emergency freeze, direct addAsset, setters, getters.
contract AdminConfig is Base, IAdminConfig {
    modifier onlyOwner() override {
        if (msg.sender != _s().owner) revert Ownable.Unauthorized();
        _;
    }

    function freezeAsset(address token) external override onlyOwner {
        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        _asset($, t);
        $.riskConfigs[t].flags |= C.FROZEN_BIT;
        emit IAdminConfig.EmergencyFreeze(t);
    }

    function unfreezeAsset(address token) external override onlyOwner {
        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        _asset($, t);
        $.riskConfigs[t].flags &= ~C.FROZEN_BIT;
        emit IAdminConfig.EmergencyUnfreeze(t);
    }

    function addAsset(
        address token,
        IPool.OracleConfig calldata oracleCfg,
        IPool.RiskConfig calldata riskCfg,
        IPool.LiquidityProfile calldata profile,
        uint16 minFeeBps,
        uint8 decimals,
        uint64 initialPrice,
        uint32 initialFastVolEMA,
        uint32 initialSlowVolEMA,
        uint32 minDispersion,
        uint32 maxDispersion,
        uint16 gamma,
        uint16 vega,
        uint16 lambda
    ) external onlyOwner {
        if (initialPrice == 0) revert Err.ZeroValue();
        if (initialFastVolEMA == 0 || initialSlowVolEMA == 0) revert Err.InvalidInput();

        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        if ($.assets[t].decimals != 0) revert Err.AlreadyConfigured(Err.Resource.ASSET, t);

        _validateProfileMemory(profile);
        _validateOracleConfig(oracleCfg);
        _initAsset($, t, decimals, minFeeBps, minDispersion, maxDispersion, gamma, vega, lambda);
        _setupOracleAndConfig($, t, oracleCfg, riskCfg, profile, initialPrice, initialFastVolEMA, initialSlowVolEMA);

        emit IAdminConfig.AssetAdded(t, decimals, 0);
    }

    function collectProtocolFees(address token, address recipient) external override nonReentrant {
        IPool.PoolStorage storage $ = _s();
        if (msg.sender != $.treasury) revert Ownable.Unauthorized();

        address t = _wrap($, token);
        uint256 fees = $.protocolFees[t];
        if (fees > 0) {
            $.protocolFees[t] = 0;
            _push(token, recipient, fees);
            emit IAdminConfig.ProtocolFeesCollected(t, recipient, fees);
        }
    }

    function setFlowCooldown(uint16 cooldownSeconds) external override onlyOwner {
        IPool.PoolStorage storage $ = _s();
        uint16 old = $.flowCooldownSeconds;
        $.flowCooldownSeconds = cooldownSeconds;
        emit IAdminConfig.FlowCooldownUpdated(old, cooldownSeconds);
    }

    function setAnchor(address token, address anchor) external onlyOwner {
        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        IPool.Asset storage asset = $.assets[t];
        if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);

        uint8 depth = LibAnchorTree.validateAnchor($, t, anchor);
        asset.anchor = anchor;
        asset.anchorDepth = depth;
        emit AnchorUpdated(t, anchor, depth);
    }

    function setAssetParams(
        address token,
        uint128 minLiquidity,
        uint16 minFeeBps,
        uint16 maxFeeBps,
        uint16 gamma,
        uint16 vega,
        uint16 lambda,
        uint16 haircutSuppressor,
        uint64 reservationPrice
    ) external onlyOwner {
        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        IPool.Asset storage asset = $.assets[t];
        if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
        if (minFeeBps > maxFeeBps) revert Err.InvalidInput();

        asset.minLiquidity = minLiquidity;
        asset.minFeeBps = minFeeBps;
        asset.maxFeeBps = maxFeeBps;
        asset.gamma = gamma;
        asset.vega = vega;
        asset.lambda = lambda;
        asset.haircutSuppressor = haircutSuppressor;
        asset.reservationPrice = reservationPrice;
        emit AssetParamsUpdated(t, minLiquidity, reservationPrice);
    }

    function getModule(bytes4 sel) external view override returns (address) {
        return _s().modules[sel];
    }

    function _validateProfileMemory(IPool.LiquidityProfile memory profile) internal pure {
        if (profile.weights[0] == 0) revert Err.InvalidInput();

        uint256 sum = 0;
        uint256 segmentCount = 0;
        unchecked {
            for (uint256 i = 0; i < 16; ++i) {
                if (profile.weights[i] == 0) { segmentCount = i; break; }
                sum += profile.weights[i];
                if (i == 15) segmentCount = 16;
            }
        }
        if (segmentCount == 0 || sum != 200) revert Err.InvalidInput();

        uint256 knotCount = segmentCount + 1;
        unchecked {
            for (uint256 i = 1; i < knotCount; ++i) {
                if (profile.knots[i] < profile.knots[i - 1]) revert Err.InvalidInput();
            }
        }
        if (int16(profile.knots[knotCount - 1]) - int16(profile.knots[0]) != 100) revert Err.InvalidInput();
    }

    function _validateOracleConfig(IPool.OracleConfig memory cfg) internal view {
        if (cfg.primary == address(0)) revert Err.InvalidInput();
        if (cfg.primary != address(this)) {
            try IOracle(cfg.primary).getFeed(cfg.feedId) returns (IOracle.FeedData memory) {} catch {
                revert Err.InvalidInput();
            }
        }
        if (cfg.secondary != address(0) && cfg.secondary != address(this)) {
            try IOracle(cfg.secondary).getFeed(cfg.feedId) returns (IOracle.FeedData memory) {} catch {
                revert Err.InvalidInput();
            }
        }
    }

    function _initAsset(
        IPool.PoolStorage storage $,
        address t,
        uint8 decimals,
        uint16 minFeeBps,
        uint32 minDispersion,
        uint32 maxDispersion,
        uint16 gamma,
        uint16 vega,
        uint16 lambda
    ) internal {
        IPool.Asset storage asset = $.assets[t];
        asset.decimals = decimals;
        asset.minFeeBps = minFeeBps;
        asset.maxFeeBps = 10000;
        asset.minLiquidity = 0;
        asset.minDispersion = minDispersion == 0 ? 1000 : minDispersion;
        asset.maxDispersion = maxDispersion == 0 ? 100000 : maxDispersion;
        asset.gamma = gamma == 0 ? 10000 : gamma;
        asset.vega = vega == 0 ? 10000 : vega;
        asset.lambda = lambda == 0 ? 10000 : lambda;
        asset.haircutSuppressor = 10000;

        if (t == $.baseToken) {
            asset.anchor = address(0);
            asset.anchorDepth = 0;
        } else {
            asset.anchor = $.baseToken;
            asset.anchorDepth = 1;
        }
    }

    function _setupOracleAndConfig(
        IPool.PoolStorage storage $,
        address t,
        IPool.OracleConfig memory oracleCfg,
        IPool.RiskConfig memory riskCfg,
        IPool.LiquidityProfile memory profile,
        uint64 initialPrice,
        uint32 initialFastVolEMA,
        uint32 initialSlowVolEMA
    ) internal {
        $.oracleConfigs[t] = oracleCfg;
        $.riskConfigs[t] = riskCfg;
        $.profiles[t] = profile;

        if (oracleCfg.primary == address(this)) {
            uint8 accDec = oracleCfg.accDecimals == 0 ? 6 : oracleCfg.accDecimals;
            try InternalOracle(address(this)).updateFeed(t, initialPrice, accDec, initialFastVolEMA, initialSlowVolEMA) {} catch {
                revert Err.OperationFailed();
            }
        }
    }
}
