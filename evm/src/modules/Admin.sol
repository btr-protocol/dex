// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Base} from "./Base.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Err} from "@btr-peripheral/Errors.sol";
import {IAdmin, IAdminConfig, IAdminTimelock} from "../interfaces/modules/IAdmin.sol";
import {IPool} from "../interfaces/IPool.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {InternalOracle} from "./InternalOracle.sol";
import {LibAnchorTree} from "../libraries/LibAnchorTree.sol";
import {LibTimelock as TL} from "../libraries/LibTimelock.sol";

/// @title Admin
/// @notice Unified admin module: emergency/setters/getters + timelocked governance ops.
/// @dev Replaces former AdminConfig + AdminTimelock split. Inlines LibUpgradeQueue calls;
///      single copy of asset-init helpers.
contract Admin is Base, IAdmin {
    modifier onlyOwner() override {
        if (msg.sender != _s().owner) revert Ownable.Unauthorized();
        _;
    }

    // ─── Non-timelocked: emergency / setters / getters ───

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

    // ─── Timelocked governance ───

    function requestAddAsset(
        address token,
        IPool.OracleConfig calldata oracleCfg,
        IPool.RiskConfig calldata riskCfg,
        IPool.LiquidityProfile calldata profile,
        uint16 minFeeBps,
        uint8 decimals,
        uint64 initialPrice,
        uint32 initialFastVolEMA,
        uint32 initialSlowVolEMA
    ) external override onlyOwner {
        if (initialPrice == 0) revert Err.ZeroValue();
        if (initialFastVolEMA == 0 || initialSlowVolEMA == 0) revert Err.InvalidInput();
        bytes32 id = keccak256(abi.encodePacked("ADD_ASSET", token));
        bytes memory data = abi.encode(token, oracleCfg, riskCfg, profile, minFeeBps, decimals, initialPrice, initialFastVolEMA, initialSlowVolEMA);
        _emitQueued(id, C.LOW_TIMELOCK, data, uint8(IPool.OpType.ADD_ASSET));
    }

    function executeAddAsset(address token) external override nonReentrant onlyOwner {
        bytes32 id = keccak256(abi.encodePacked("ADD_ASSET", token));
        bytes memory raw = _consumeRaw(id);
        (
            address storedToken,
            IPool.OracleConfig memory oracleCfg,
            IPool.RiskConfig memory riskCfg,
            IPool.LiquidityProfile memory profile,
            uint16 minFeeBps,
            uint8 decimals,
            uint64 initialPrice,
            uint32 initialFastVolEMA,
            uint32 initialSlowVolEMA
        ) = abi.decode(raw, (address, IPool.OracleConfig, IPool.RiskConfig, IPool.LiquidityProfile, uint16, uint8, uint64, uint32, uint32));
        if (storedToken != token) revert Err.InvalidInput();

        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        if ($.assets[t].decimals != 0) revert Err.AlreadyConfigured(Err.Resource.ASSET, t);

        _validateProfileMemory(profile);
        _validateOracleConfig(oracleCfg);
        _initAsset($, t, decimals, minFeeBps, 0, 0, 0, 0, 0);
        _setupOracleAndConfig($, t, oracleCfg, riskCfg, profile, initialPrice, initialFastVolEMA, initialSlowVolEMA);
        emit IAdminConfig.AssetAdded(t, decimals, 0);
    }

    function requestUpdateRiskConfig(address token, IPool.RiskConfig calldata cfg) external override onlyOwner {
        bytes32 id = keccak256(abi.encodePacked("UPDATE_RISK", token));
        _emitQueued(id, C.LOW_TIMELOCK, abi.encode(token, cfg), uint8(IPool.OpType.UPDATE_RISK));
    }

    function executeUpdateRiskConfig(address token) external override nonReentrant onlyOwner {
        bytes32 id = keccak256(abi.encodePacked("UPDATE_RISK", token));
        (address storedToken, IPool.RiskConfig memory cfg) = abi.decode(_consumeRaw(id), (address, IPool.RiskConfig));
        if (storedToken != token) revert Err.InvalidInput();

        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        _asset($, t);
        $.riskConfigs[t] = cfg;
        emit IAdminTimelock.RiskConfigUpdated(t, cfg.flags, 0);
    }

    function requestUpdateFeeParams(IPool.FeeParams calldata params) external override onlyOwner {
        _emitQueued(C.TIMELOCK_ID_FEE_PARAMS, C.LOW_TIMELOCK, abi.encode(params), uint8(IPool.OpType.UPDATE_FEES));
    }

    function executeUpdateFeeParams() external override nonReentrant onlyOwner {
        IPool.FeeParams memory params = abi.decode(_consumeRaw(C.TIMELOCK_ID_FEE_PARAMS), (IPool.FeeParams));
        _s().feeParams = params;
        emit IAdminTimelock.FeeParamsUpdated(params.protoShare, params.flashFeeBps);
    }

    function requestOwnershipTransfer(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert Err.ZeroValue();
        _emitQueued(C.TIMELOCK_ID_OWNERSHIP, C.HIGH_TIMELOCK, abi.encode(newOwner), uint8(IPool.OpType.TRANSFER_OWNERSHIP));
    }

    function executeOwnershipTransfer() external override nonReentrant {
        address newOwner = abi.decode(_consumeRaw(C.TIMELOCK_ID_OWNERSHIP), (address));
        IPool.PoolStorage storage $ = _s();
        address oldOwner = $.owner;
        $.owner = newOwner;
        emit IAdminTimelock.OwnershipTransferred(oldOwner, newOwner);
    }

    function requestBridgeUpdate(address newBridge) external override onlyOwner {
        _emitQueued(C.TIMELOCK_ID_BRIDGE, C.HIGH_TIMELOCK, abi.encode(newBridge), uint8(IPool.OpType.UPDATE_BRIDGE));
    }

    function executeBridgeUpdate() external override nonReentrant onlyOwner {
        address newBridge = abi.decode(_consumeRaw(C.TIMELOCK_ID_BRIDGE), (address));
        IPool.PoolStorage storage $ = _s();
        address oldBridge = $.bridge;
        $.bridge = newBridge;
        emit IAdminTimelock.BridgeUpdated(oldBridge, newBridge);
    }

    function requestTreasuryUpdate(address newTreasury) external override onlyOwner {
        if (newTreasury == address(0)) revert Err.ZeroValue();
        _emitQueued(C.TIMELOCK_ID_TREASURY, C.HIGH_TIMELOCK, abi.encode(newTreasury), uint8(IPool.OpType.UPDATE_TREASURY));
    }

    function executeTreasuryUpdate() external override nonReentrant onlyOwner {
        address newTreasury = abi.decode(_consumeRaw(C.TIMELOCK_ID_TREASURY), (address));
        IPool.PoolStorage storage $ = _s();
        address oldTreasury = $.treasury;
        $.treasury = newTreasury;
        emit IAdminTimelock.TreasuryUpdated(oldTreasury, newTreasury);
    }

    function requestModuleUpdate(address impl, bytes4[] calldata selectors, bytes calldata initData) external override onlyOwner {
        _emitQueued(C.TIMELOCK_ID_MODULE, C.HIGH_TIMELOCK, abi.encode(impl, selectors, initData), uint8(IPool.OpType.UPDATE_MODULE));
    }

    function executeModuleUpdate() external override onlyOwner nonReentrant {
        (address impl, bytes4[] memory selectors, bytes memory initData) = abi.decode(_consumeRaw(C.TIMELOCK_ID_MODULE), (address, bytes4[], bytes));
        IPool.PoolStorage storage $ = _s();
        if (selectors.length == 0) revert Err.InvalidInput();
        for (uint256 i = 0; i < selectors.length; i++) $.modules[selectors[i]] = impl;
        if (impl != address(0) && initData.length > 0) {
            (bool ok, bytes memory err) = impl.delegatecall(initData);
            if (!ok) { assembly { revert(add(err, 32), mload(err)) } }
        }
        emit IAdminTimelock.ModulesUpdated(impl, selectors);
    }

    function requestBaseMigration(address newBase) external override onlyOwner {
        _emitQueued(C.TIMELOCK_ID_BASE_MIGRATION, C.CRITICAL_TIMELOCK, abi.encode(newBase), uint8(IPool.OpType.MIGRATE_BASE_TOKEN));
    }

    function executeBaseMigration() external override nonReentrant onlyOwner {
        address newBase = abi.decode(_consumeRaw(C.TIMELOCK_ID_BASE_MIGRATION), (address));
        IPool.PoolStorage storage $ = _s();
        address oldBase = $.baseToken;
        $.baseToken = newBase;
        emit IAdminTimelock.BaseTokenMigrated(oldBase, newBase);
    }

    function requestOracleUpdate(address token, IPool.OracleConfig calldata cfg) external override onlyOwner {
        bytes32 id = keccak256(abi.encodePacked("ORACLE_UPDATE", token));
        _emitQueued(id, C.BASE_TIMELOCK, abi.encode(token, cfg), uint8(IPool.OpType.UPDATE_ORACLE));
    }

    function executeOracleUpdate(address token) external nonReentrant onlyOwner {
        bytes32 id = keccak256(abi.encodePacked("ORACLE_UPDATE", token));
        (address storedToken, IPool.OracleConfig memory cfg) = abi.decode(_consumeRaw(id), (address, IPool.OracleConfig));
        if (storedToken != token) revert Err.InvalidInput();
        _validateOracleConfig(cfg);
        _s().oracleConfigs[token] = cfg;
        emit IAdminTimelock.OracleUpdated(token);
    }

    function cancelOracleUpdate(address token) external onlyOwner {
        bytes32 id = keccak256(abi.encodePacked("ORACLE_UPDATE", token));
        _cancelInline(id, uint8(IPool.OpType.UPDATE_ORACLE));
    }

    function cancelTimelock(uint8 opType) external override onlyOwner {
        bytes32 id;
        if (opType == uint8(IPool.OpType.TRANSFER_OWNERSHIP)) id = C.TIMELOCK_ID_OWNERSHIP;
        else if (opType == uint8(IPool.OpType.UPDATE_MODULE)) id = C.TIMELOCK_ID_MODULE;
        else if (opType == uint8(IPool.OpType.MIGRATE_BASE_TOKEN)) id = C.TIMELOCK_ID_BASE_MIGRATION;
        else if (opType == uint8(IPool.OpType.UPDATE_STAKING)) id = C.TIMELOCK_ID_STAKING;
        else if (opType == uint8(IPool.OpType.UPDATE_DISTRIBUTION)) id = C.TIMELOCK_ID_DISTRIBUTION;
        else if (opType == uint8(IPool.OpType.UPDATE_BRIDGE)) id = C.TIMELOCK_ID_BRIDGE;
        else if (opType == uint8(IPool.OpType.UPDATE_TREASURY)) id = C.TIMELOCK_ID_TREASURY;
        else revert Err.InvalidInput(); // includes UPDATE_ORACLE → use cancelOracleUpdate
        _cancelInline(id, opType);
    }

    // ─── Internal helpers (single copy) ───

    function _emitQueued(bytes32 id, uint48 delay, bytes memory data, uint8 opType) internal {
        IPool.PoolStorage storage $ = _s();
        $.pendingOps[id] = TL.pack(delay, C.GRACE_PERIOD);
        $.pendingData[id] = data;
        uint48 eta;
        unchecked { eta = uint48(block.timestamp) + delay; }
        emit IAdminTimelock.TimelockRequested(id, opType, eta);
    }

    function _consumeRaw(bytes32 id) internal returns (bytes memory data) {
        IPool.PoolStorage storage $ = _s();
        TL.validate($.pendingOps[id]);
        data = $.pendingData[id];
        delete $.pendingOps[id];
        delete $.pendingData[id];
    }

    function _cancelInline(bytes32 id, uint8 opType) internal {
        IPool.PoolStorage storage $ = _s();
        if ($.pendingOps[id] == 0) revert Err.InvalidState();
        delete $.pendingOps[id];
        delete $.pendingData[id];
        emit IAdminTimelock.TimelockCancelled(id, opType);
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
