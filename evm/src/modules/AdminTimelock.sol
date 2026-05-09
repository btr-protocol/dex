// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Base} from "./Base.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Err} from "../Errors.sol";
import {IAdminTimelock} from "../interfaces/modules/IAdminTimelock.sol";
import {IAdminConfig} from "../interfaces/modules/IAdminConfig.sol";
import {IPool} from "../interfaces/IPool.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {InternalOracle} from "./InternalOracle.sol";
import {LibUpgradeQueue as UQ} from "../libraries/LibUpgradeQueue.sol";

/// @title AdminTimelock
/// @notice Timelocked governance: 9 request/execute triplets + module updates + cancel.
contract AdminTimelock is Base, IAdminTimelock {
    modifier onlyOwner() override {
        if (msg.sender != _s().owner) revert Ownable.Unauthorized();
        _;
    }

    function _queue(bytes32 id, uint48 delay, bytes memory data, uint8 opType) internal {
        IPool.PoolStorage storage $ = _s();
        uint48 eta = UQ.queue($.pendingOps, $.pendingData, id, delay, C.GRACE_PERIOD, data);
        emit IAdminTimelock.TimelockRequested(id, opType, eta);
    }

    function _consume(bytes32 id) internal returns (bytes memory data) {
        IPool.PoolStorage storage $ = _s();
        data = UQ.consume($.pendingOps, $.pendingData, id);
    }

    function _cancel(bytes32 id, uint8 opType) internal {
        IPool.PoolStorage storage $ = _s();
        UQ.cancel($.pendingOps, $.pendingData, id);
        emit IAdminTimelock.TimelockCancelled(id, opType);
    }


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
        _queue(id, C.LOW_TIMELOCK, abi.encode(token, oracleCfg, riskCfg, profile, minFeeBps, decimals, initialPrice, initialFastVolEMA, initialSlowVolEMA), uint8(IPool.OpType.ADD_ASSET));
    }

    function executeAddAsset(address token) external override nonReentrant onlyOwner {
        bytes32 id = keccak256(abi.encodePacked("ADD_ASSET", token));
        bytes memory raw = _consume(id);
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
        _queue(id, C.LOW_TIMELOCK, abi.encode(token, cfg), uint8(IPool.OpType.UPDATE_RISK));
    }

    function executeUpdateRiskConfig(address token) external override nonReentrant onlyOwner {
        bytes32 id = keccak256(abi.encodePacked("UPDATE_RISK", token));
        bytes memory raw = _consume(id);
        (address storedToken, IPool.RiskConfig memory cfg) = abi.decode(raw, (address, IPool.RiskConfig));
        if (storedToken != token) revert Err.InvalidInput();

        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        _asset($, t);
        $.riskConfigs[t] = cfg;
        emit IAdminTimelock.RiskConfigUpdated(t, cfg.flags, 0);
    }


    function requestUpdateFeeParams(IPool.FeeParams calldata params) external override onlyOwner {
        _queue(C.TIMELOCK_ID_FEE_PARAMS, C.LOW_TIMELOCK, abi.encode(params), uint8(IPool.OpType.UPDATE_FEES));
    }

    function executeUpdateFeeParams() external override nonReentrant onlyOwner {
        IPool.FeeParams memory params = abi.decode(_consume(C.TIMELOCK_ID_FEE_PARAMS), (IPool.FeeParams));
        _s().feeParams = params;
        emit IAdminTimelock.FeeParamsUpdated(params.protoShare, params.flashFeeBps);
    }


    function requestOwnershipTransfer(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert Err.ZeroValue();
        _queue(C.TIMELOCK_ID_OWNERSHIP, C.HIGH_TIMELOCK, abi.encode(newOwner), uint8(IPool.OpType.TRANSFER_OWNERSHIP));
    }

    function executeOwnershipTransfer() external override nonReentrant {
        address newOwner = abi.decode(_consume(C.TIMELOCK_ID_OWNERSHIP), (address));
        IPool.PoolStorage storage $ = _s();
        address oldOwner = $.owner;
        $.owner = newOwner;
        emit IAdminTimelock.OwnershipTransferred(oldOwner, newOwner);
    }


    function requestBridgeUpdate(address newBridge) external override onlyOwner {
        _queue(C.TIMELOCK_ID_BRIDGE, C.HIGH_TIMELOCK, abi.encode(newBridge), uint8(IPool.OpType.UPDATE_BRIDGE));
    }

    function executeBridgeUpdate() external override nonReentrant onlyOwner {
        address newBridge = abi.decode(_consume(C.TIMELOCK_ID_BRIDGE), (address));
        IPool.PoolStorage storage $ = _s();
        address oldBridge = $.bridge;
        $.bridge = newBridge;
        emit IAdminTimelock.BridgeUpdated(oldBridge, newBridge);
    }


    function requestTreasuryUpdate(address newTreasury) external override onlyOwner {
        if (newTreasury == address(0)) revert Err.ZeroValue();
        _queue(C.TIMELOCK_ID_TREASURY, C.HIGH_TIMELOCK, abi.encode(newTreasury), uint8(IPool.OpType.UPDATE_TREASURY));
    }

    function executeTreasuryUpdate() external override nonReentrant onlyOwner {
        address newTreasury = abi.decode(_consume(C.TIMELOCK_ID_TREASURY), (address));
        IPool.PoolStorage storage $ = _s();
        address oldTreasury = $.treasury;
        $.treasury = newTreasury;
        emit IAdminTimelock.TreasuryUpdated(oldTreasury, newTreasury);
    }


    function requestModuleUpdate(address impl, bytes4[] calldata selectors, bytes calldata initData) external override onlyOwner {
        _queue(C.TIMELOCK_ID_MODULE, C.HIGH_TIMELOCK, abi.encode(impl, selectors, initData), uint8(IPool.OpType.UPDATE_MODULE));
    }

    function executeModuleUpdate() external override onlyOwner nonReentrant {
        (address impl, bytes4[] memory selectors, bytes memory initData) = abi.decode(_consume(C.TIMELOCK_ID_MODULE), (address, bytes4[], bytes));
        _updateModule(_s(), impl, selectors, initData);
    }


    function requestBaseMigration(address newBase) external override onlyOwner {
        _queue(C.TIMELOCK_ID_BASE_MIGRATION, C.CRITICAL_TIMELOCK, abi.encode(newBase), uint8(IPool.OpType.MIGRATE_BASE_TOKEN));
    }

    function executeBaseMigration() external override nonReentrant onlyOwner {
        address newBase = abi.decode(_consume(C.TIMELOCK_ID_BASE_MIGRATION), (address));
        IPool.PoolStorage storage $ = _s();
        address oldBase = $.baseToken;
        $.baseToken = newBase;
        emit IAdminTimelock.BaseTokenMigrated(oldBase, newBase);
    }


    function requestOracleUpdate(address token, IPool.OracleConfig calldata cfg) external override onlyOwner {
        bytes32 id = keccak256(abi.encodePacked("ORACLE_UPDATE", token));
        _queue(id, C.BASE_TIMELOCK, abi.encode(token, cfg), uint8(IPool.OpType.UPDATE_ORACLE));
    }

    function executeOracleUpdate(address token) external nonReentrant onlyOwner {
        bytes32 id = keccak256(abi.encodePacked("ORACLE_UPDATE", token));
        (address storedToken, IPool.OracleConfig memory cfg) = abi.decode(_consume(id), (address, IPool.OracleConfig));
        if (storedToken != token) revert Err.InvalidInput();
        _validateOracleConfig(cfg);
        _s().oracleConfigs[token] = cfg;
        emit IAdminTimelock.OracleUpdated(token);
    }

    function cancelOracleUpdate(address token) external onlyOwner {
        bytes32 id = keccak256(abi.encodePacked("ORACLE_UPDATE", token));
        _cancel(id, uint8(IPool.OpType.UPDATE_ORACLE));
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
        _cancel(id, opType);
    }


    function _updateModule(
        IPool.PoolStorage storage $,
        address impl,
        bytes4[] memory sels,
        bytes memory initData
    ) internal {
        if (sels.length == 0) revert Err.InvalidInput();
        for (uint256 i = 0; i < sels.length; i++) $.modules[sels[i]] = impl;
        if (impl != address(0) && initData.length > 0) {
            (bool ok, bytes memory err) = impl.delegatecall(initData);
            if (!ok) { assembly { revert(add(err, 32), mload(err)) } }
        }
        emit IAdminTimelock.ModulesUpdated(impl, sels);
    }


    // ─── Local helpers (executeAddAsset path) ───
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
