// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseV1} from "./BaseV1.sol";
import {IErrors} from "../interfaces/IErrors.sol";
import {IAdminV1} from "../interfaces/modules/IAdminV1.sol";
import {IPoolV1} from "../interfaces/IPoolV1.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";
import {IOracleV1} from "../interfaces/IOracleV1.sol";
import {InternalOracleV1} from "./InternalOracleV1.sol";
import {LibTimelock as TL} from "../libraries/LibTimelock.sol";
import {LibAnchorTree} from "../libraries/LibAnchorTree.sol";
import {LibTransientCache as TCache} from "../libraries/LibTransientCache.sol";

/// @title Admin
/// @notice Administrative functions with ultra-compact timelock governance
contract AdminV1 is BaseV1, IAdminV1 {
    modifier onlyOwner() override {
        IPoolV1.PoolStorage storage $ = _s();
        if (msg.sender != $.owner) revert Unauthorized();
        _;
    }

    // ========== EMERGENCY FUNCTIONS (NO TIMELOCK) ==========

    /// @notice Emergency freeze of an asset - only immediate admin function
    function freezeAsset(address token) external override onlyOwner {
        IPoolV1.PoolStorage storage $ = _s();
        address tokenNorm = _wrap($, token);
        _asset($, tokenNorm);
        $.riskConfigs[tokenNorm].flags |= C.FROZEN_BIT;
        emit IAdminV1.EmergencyFreeze(tokenNorm);
    }

    /// @notice Unfreeze an asset
    function unfreezeAsset(address token) external override onlyOwner {
        IPoolV1.PoolStorage storage $ = _s();
        address tokenNorm = _wrap($, token);
        _asset($, tokenNorm);
        $.riskConfigs[tokenNorm].flags &= ~C.FROZEN_BIT;
        emit IAdminV1.EmergencyUnfreeze(tokenNorm);
    }

    // ========== TIMELOCKED ADMIN FUNCTIONS ==========

    function requestAddAsset(
        address token,
        IPoolV1.OracleConfig calldata oracleCfg,
        IPoolV1.RiskConfig calldata riskCfg,
        IPoolV1.LiquidityProfile calldata profile,
        uint16 minFeeBps,
        uint8 decimals,
        uint64 initialPrice,
        uint32 initialFastVolEMA,
        uint32 initialSlowVolEMA
    ) external override onlyOwner {
        bytes32 id = keccak256(abi.encodePacked("ADD_ASSET", token));
        IPoolV1.PoolStorage storage $ = _s();

        if (initialPrice == 0) revert IErrors.ZeroValue();
        if (initialFastVolEMA == 0) revert IErrors.InvalidInput();
        if (initialSlowVolEMA == 0) revert IErrors.InvalidInput();

        $.pendingOps[id] = TL.pack(C.LOW_TIMELOCK, C.GRACE_PERIOD);
        $.pendingData[id] = abi.encode(token, oracleCfg, riskCfg, profile, minFeeBps, decimals, initialPrice, initialFastVolEMA, initialSlowVolEMA);
        emit IAdminV1.TimelockRequested(id, uint8(IPoolV1.OpType.ADD_ASSET), uint48(block.timestamp) + C.LOW_TIMELOCK);
    }

    function executeAddAsset(address token) external override onlyOwner {
        bytes32 id = keccak256(abi.encodePacked("ADD_ASSET", token));
        IPoolV1.PoolStorage storage $ = _s();

        TL.validate($.pendingOps[id]);

        (
            address storedToken,
            IPoolV1.OracleConfig memory oracleCfg,
            IPoolV1.RiskConfig memory riskCfg,
            IPoolV1.LiquidityProfile memory profileMem,
            uint16 minFeeBps,
            uint8 decimals,
            uint64 initialPrice,
            uint32 initialFastVolEMA,
            uint32 initialSlowVolEMA
        ) = abi.decode($.pendingData[id], (address, IPoolV1.OracleConfig, IPoolV1.RiskConfig, IPoolV1.LiquidityProfile, uint16, uint8, uint64, uint32, uint32));

        if (storedToken != token) revert IErrors.InvalidInput();

        address tokenNorm = _wrap($, token);
        IPoolV1.Asset storage asset = $.assets[tokenNorm];
        if (asset.decimals != 0) revert IErrors.AlreadyConfigured(IErrors.Resource.ASSET, tokenNorm);

        _validateProfileMemory(profileMem);
        _validateOracleConfig(oracleCfg);

        asset.decimals = decimals;
        asset.minFeeBps = minFeeBps;
        asset.maxFeeBps = 10000;          // Default 1% max fee
        asset.minLiquidity = 0;
        asset.minDispersion = 1000;        // Default 0.1% min dispersion
        asset.maxDispersion = 100000;      // Default 10% max dispersion
        asset.gamma = 10000;               // Default 1.0x inventory sensitivity
        asset.vega = 10000;                // Default 1.0x volatility sensitivity
        asset.lambda = 10000;              // Default 1.0x deviation sensitivity
        asset.haircutSuppressor = 10000;   // Default 1.0x haircut

        // Initialize anchor tree relationship
        // By default, new assets anchor to base token (hub-and-spoke)
        // Can be changed later via setAnchor()
        if (tokenNorm == $.baseToken) {
            asset.anchor = address(0); // Base token is root
            asset.anchorDepth = 0;
        } else {
            asset.anchor = $.baseToken; // Default to base token as anchor
            asset.anchorDepth = 1;
        }

        $.oracleConfigs[tokenNorm] = oracleCfg;
        $.riskConfigs[tokenNorm] = riskCfg;
        $.profiles[tokenNorm] = profileMem;

        // Initialize internal oracle with base price and volatility
        // Only initialize if using internal oracle (primary = address(this))
        if (oracleCfg.primary == address(this)) {
            // Use accDecimals from oracle config (0 defaults to 6 for stablecoin-friendly range)
            uint8 accDec = oracleCfg.accDecimals == 0 ? 6 : oracleCfg.accDecimals;
            try InternalOracleV1(address(this)).updateFeed(
                tokenNorm,
                initialPrice,
                accDec,
                initialFastVolEMA,
                initialSlowVolEMA
            ) {} catch {
                revert IErrors.OperationFailed();
            }
        }

        delete $.pendingOps[id];
        delete $.pendingData[id];
        emit IAdminV1.AssetAdded(tokenNorm, decimals, 0);
    }

    function requestUpdateRiskConfig(address token, IPoolV1.RiskConfig calldata cfg) external override onlyOwner {
        bytes32 id = keccak256(abi.encodePacked("UPDATE_RISK", token));
        IPoolV1.PoolStorage storage $ = _s();

        $.pendingOps[id] = TL.pack(C.LOW_TIMELOCK, C.GRACE_PERIOD);
        $.pendingData[id] = abi.encode(token, cfg);
        emit IAdminV1.TimelockRequested(id, uint8(IPoolV1.OpType.UPDATE_RISK), uint48(block.timestamp) + C.LOW_TIMELOCK);
    }

    function executeUpdateRiskConfig(address token) external override onlyOwner {
        bytes32 id = keccak256(abi.encodePacked("UPDATE_RISK", token));
        IPoolV1.PoolStorage storage $ = _s();

        TL.validate($.pendingOps[id]);

        (address storedToken, IPoolV1.RiskConfig memory cfg) = abi.decode($.pendingData[id], (address, IPoolV1.RiskConfig));
        if (storedToken != token) revert IErrors.InvalidInput();

        address tokenNorm = _wrap($, token);
        _asset($, tokenNorm);
        $.riskConfigs[tokenNorm] = cfg;

        delete $.pendingOps[id];
        delete $.pendingData[id];
        emit IAdminV1.RiskConfigUpdated(tokenNorm, cfg.flags, 0);
    }

    function requestUpdateFeeParams(IPoolV1.FeeParams calldata params) external override onlyOwner {
        IPoolV1.PoolStorage storage $ = _s();

        $.pendingOps[C.TIMELOCK_ID_FEE_PARAMS] = TL.pack(C.LOW_TIMELOCK, C.GRACE_PERIOD);
        $.pendingData[C.TIMELOCK_ID_FEE_PARAMS] = abi.encode(params);
        emit IAdminV1.TimelockRequested(C.TIMELOCK_ID_FEE_PARAMS, uint8(IPoolV1.OpType.UPDATE_FEES), uint48(block.timestamp) + C.LOW_TIMELOCK);
    }

    function executeUpdateFeeParams() external override onlyOwner {
        IPoolV1.PoolStorage storage $ = _s();

        TL.validate($.pendingOps[C.TIMELOCK_ID_FEE_PARAMS]);

        IPoolV1.FeeParams memory params = abi.decode($.pendingData[C.TIMELOCK_ID_FEE_PARAMS], (IPoolV1.FeeParams));
        $.feeParams = params;

        delete $.pendingOps[C.TIMELOCK_ID_FEE_PARAMS];
        delete $.pendingData[C.TIMELOCK_ID_FEE_PARAMS];
        emit IAdminV1.FeeParamsUpdated(params.protoShare, params.flashFeeBps);
    }

    function collectProtocolFees(address token, address recipient) external override nonReentrant {
        IPoolV1.PoolStorage storage $ = _s();

        // Only treasury can collect protocol fees
        if (msg.sender != $.treasury) revert Unauthorized();

        address tokenNorm = _wrap($, token);
        uint256 fees = $.protocolFees[tokenNorm];
        if (fees > 0) {
            $.protocolFees[tokenNorm] = 0;
            _push(token, recipient, fees);
            emit IAdminV1.ProtocolFeesCollected(tokenNorm, recipient, fees);
        }
    }

    // ========== TIMELOCK GOVERNANCE ==========

    function requestOwnershipTransfer(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert IErrors.ZeroValue();
        IPoolV1.PoolStorage storage $ = _s();

        $.pendingOps[C.TIMELOCK_ID_OWNERSHIP] = TL.pack(C.HIGH_TIMELOCK, C.GRACE_PERIOD);
        $.pendingData[C.TIMELOCK_ID_OWNERSHIP] = abi.encode(newOwner);
        emit IAdminV1.TimelockRequested(C.TIMELOCK_ID_OWNERSHIP, uint8(IPoolV1.OpType.TRANSFER_OWNERSHIP), uint48(block.timestamp) + C.HIGH_TIMELOCK);
    }

    function executeOwnershipTransfer() external override {
        IPoolV1.PoolStorage storage $ = _s();

        TL.validate($.pendingOps[C.TIMELOCK_ID_OWNERSHIP]);

        address newOwner = abi.decode($.pendingData[C.TIMELOCK_ID_OWNERSHIP], (address));
        address oldOwner = $.owner;
        $.owner = newOwner;

        delete $.pendingOps[C.TIMELOCK_ID_OWNERSHIP];
        delete $.pendingData[C.TIMELOCK_ID_OWNERSHIP];
        emit IAdminV1.OwnershipTransferred(oldOwner, newOwner);
    }

    function requestBridgeUpdate(address newBridge) external override onlyOwner {
        IPoolV1.PoolStorage storage $ = _s();

        $.pendingOps[C.TIMELOCK_ID_BRIDGE] = TL.pack(C.HIGH_TIMELOCK, C.GRACE_PERIOD);
        $.pendingData[C.TIMELOCK_ID_BRIDGE] = abi.encode(newBridge);
        emit IAdminV1.TimelockRequested(C.TIMELOCK_ID_BRIDGE, uint8(IPoolV1.OpType.UPDATE_BRIDGE), uint48(block.timestamp) + C.HIGH_TIMELOCK);
    }

    function executeBridgeUpdate() external override onlyOwner {
        IPoolV1.PoolStorage storage $ = _s();

        TL.validate($.pendingOps[C.TIMELOCK_ID_BRIDGE]);

        address newBridge = abi.decode($.pendingData[C.TIMELOCK_ID_BRIDGE], (address));
        address oldBridge = $.bridge;
        $.bridge = newBridge;

        delete $.pendingOps[C.TIMELOCK_ID_BRIDGE];
        delete $.pendingData[C.TIMELOCK_ID_BRIDGE];
        emit IAdminV1.BridgeUpdated(oldBridge, newBridge);
    }

    function requestTreasuryUpdate(address newTreasury) external override onlyOwner {
        if (newTreasury == address(0)) revert IErrors.ZeroValue();
        IPoolV1.PoolStorage storage $ = _s();

        $.pendingOps[C.TIMELOCK_ID_TREASURY] = TL.pack(C.HIGH_TIMELOCK, C.GRACE_PERIOD);
        $.pendingData[C.TIMELOCK_ID_TREASURY] = abi.encode(newTreasury);
        emit IAdminV1.TimelockRequested(C.TIMELOCK_ID_TREASURY, uint8(IPoolV1.OpType.UPDATE_TREASURY), uint48(block.timestamp) + C.HIGH_TIMELOCK);
    }

    function executeTreasuryUpdate() external override onlyOwner {
        IPoolV1.PoolStorage storage $ = _s();

        TL.validate($.pendingOps[C.TIMELOCK_ID_TREASURY]);

        address newTreasury = abi.decode($.pendingData[C.TIMELOCK_ID_TREASURY], (address));
        address oldTreasury = $.treasury;
        $.treasury = newTreasury;

        delete $.pendingOps[C.TIMELOCK_ID_TREASURY];
        delete $.pendingData[C.TIMELOCK_ID_TREASURY];
        emit IAdminV1.TreasuryUpdated(oldTreasury, newTreasury);
    }

    function requestModuleUpdate(address impl, bytes4[] calldata selectors, bytes calldata initData) external override onlyOwner {
        IPoolV1.PoolStorage storage $ = _s();

        $.pendingOps[C.TIMELOCK_ID_MODULE] = TL.pack(C.HIGH_TIMELOCK, C.GRACE_PERIOD);
        $.pendingData[C.TIMELOCK_ID_MODULE] = abi.encode(impl, selectors, initData);
        emit IAdminV1.TimelockRequested(C.TIMELOCK_ID_MODULE, uint8(IPoolV1.OpType.UPDATE_MODULE), uint48(block.timestamp) + C.HIGH_TIMELOCK);
    }

    function executeModuleUpdate() external override onlyOwner nonReentrant {
        IPoolV1.PoolStorage storage $ = _s();

        TL.validate($.pendingOps[C.TIMELOCK_ID_MODULE]);

        (address impl, bytes4[] memory selectors, bytes memory initData) = abi.decode($.pendingData[C.TIMELOCK_ID_MODULE], (address, bytes4[], bytes));

        _updateModule($, impl, selectors, initData);

        delete $.pendingOps[C.TIMELOCK_ID_MODULE];
        delete $.pendingData[C.TIMELOCK_ID_MODULE];
    }

    function requestBaseMigration(address newBase) external override onlyOwner {
        IPoolV1.PoolStorage storage $ = _s();

        $.pendingOps[C.TIMELOCK_ID_BASE_MIGRATION] = TL.pack(C.CRITICAL_TIMELOCK, C.GRACE_PERIOD);
        $.pendingData[C.TIMELOCK_ID_BASE_MIGRATION] = abi.encode(newBase);
        emit IAdminV1.TimelockRequested(C.TIMELOCK_ID_BASE_MIGRATION, uint8(IPoolV1.OpType.MIGRATE_BASE_TOKEN), uint48(block.timestamp) + C.CRITICAL_TIMELOCK);
    }

    function executeBaseMigration() external override onlyOwner {
        IPoolV1.PoolStorage storage $ = _s();

        TL.validate($.pendingOps[C.TIMELOCK_ID_BASE_MIGRATION]);

        address newBase = abi.decode($.pendingData[C.TIMELOCK_ID_BASE_MIGRATION], (address));
        address oldBase = $.baseToken;
        $.baseToken = newBase;

        delete $.pendingOps[C.TIMELOCK_ID_BASE_MIGRATION];
        delete $.pendingData[C.TIMELOCK_ID_BASE_MIGRATION];
        emit IAdminV1.BaseTokenMigrated(oldBase, newBase);
    }

    function requestOracleUpdate(address token, IPoolV1.OracleConfig calldata cfg) external override onlyOwner {
        bytes32 id = keccak256(abi.encodePacked("ORACLE_UPDATE", token));
        IPoolV1.PoolStorage storage $ = _s();

        $.pendingOps[id] = TL.pack(C.BASE_TIMELOCK, C.GRACE_PERIOD);
        $.pendingData[id] = abi.encode(token, cfg);
        emit IAdminV1.TimelockRequested(id, uint8(IPoolV1.OpType.UPDATE_ORACLE), uint48(block.timestamp) + C.BASE_TIMELOCK);
    }

    function executeOracleUpdate(address token) external onlyOwner {
        bytes32 id = keccak256(abi.encodePacked("ORACLE_UPDATE", token));
        IPoolV1.PoolStorage storage $ = _s();

        TL.validate($.pendingOps[id]);

        (address storedToken, IPoolV1.OracleConfig memory cfg) = abi.decode($.pendingData[id], (address, IPoolV1.OracleConfig));
        if (storedToken != token) revert IErrors.InvalidInput();

        _validateOracleConfig(cfg);

        $.oracleConfigs[token] = cfg;

        delete $.pendingOps[id];
        delete $.pendingData[id];
        emit IAdminV1.OracleUpdated(token);
    }

    function cancelTimelock(uint8 opType) external override onlyOwner {
        IPoolV1.PoolStorage storage $ = _s();
        bytes32 id;

        if (opType == uint8(IPoolV1.OpType.TRANSFER_OWNERSHIP)) {
            id = C.TIMELOCK_ID_OWNERSHIP;
        } else if (opType == uint8(IPoolV1.OpType.UPDATE_MODULE)) {
            id = C.TIMELOCK_ID_MODULE;
        } else if (opType == uint8(IPoolV1.OpType.MIGRATE_BASE_TOKEN)) {
            id = C.TIMELOCK_ID_BASE_MIGRATION;
        } else if (opType == uint8(IPoolV1.OpType.UPDATE_ORACLE)) {
            revert IErrors.InvalidInput(); // Use cancelOracleUpdate instead
        } else if (opType == uint8(IPoolV1.OpType.UPDATE_STAKING)) {
            id = C.TIMELOCK_ID_STAKING;
        } else if (opType == uint8(IPoolV1.OpType.UPDATE_DISTRIBUTION)) {
            id = C.TIMELOCK_ID_DISTRIBUTION;
        } else if (opType == uint8(IPoolV1.OpType.UPDATE_BRIDGE)) {
            id = C.TIMELOCK_ID_BRIDGE;
        } else if (opType == uint8(IPoolV1.OpType.UPDATE_TREASURY)) {
            id = C.TIMELOCK_ID_TREASURY;
        } else {
            revert IErrors.InvalidInput();
        }

        if ($.pendingOps[id] == 0) {
            revert IErrors.InvalidState();
        }

        delete $.pendingOps[id];
        delete $.pendingData[id];
        emit IAdminV1.TimelockCancelled(id, opType);
    }

    function cancelOracleUpdate(address token) external onlyOwner {
        bytes32 id = keccak256(abi.encodePacked("ORACLE_UPDATE", token));
        IPoolV1.PoolStorage storage $ = _s();

        if ($.pendingOps[id] == 0) {
            revert IErrors.InvalidState();
        }

        delete $.pendingOps[id];
        delete $.pendingData[id];
        emit IAdminV1.TimelockCancelled(id, uint8(IPoolV1.OpType.UPDATE_ORACLE));
    }

    // ========== MODULE MANAGEMENT ==========

    function _updateModule(
        IPoolV1.PoolStorage storage $,
        address impl,
        bytes4[] memory sels,
        bytes memory initData
    ) internal {
        if (sels.length == 0) revert IErrors.InvalidInput();

        for (uint256 i = 0; i < sels.length; i++) {
            $.modules[sels[i]] = impl;
        }

        if (impl != address(0) && initData.length > 0) {
            (bool ok, bytes memory err) = impl.delegatecall(initData);
            if (!ok) {
                assembly { revert(add(err, 32), mload(err)) }
            }
        }

        emit IAdminV1.ModulesUpdated(impl, sels);
    }

    function getModule(bytes4 sel) external view override returns (address) {
        return _s().modules[sel];
    }

    // ========== INTERNAL HELPERS ==========

    function _validateProfileMemory(IPoolV1.LiquidityProfile memory profile) internal pure {
        if (profile.weights[0] == 0) revert IErrors.InvalidInput();

        uint256 sum = 0;
        uint256 segmentCount = 0;
        unchecked {
            for (uint256 i = 0; i < 16; ++i) {
                if (profile.weights[i] == 0) {
                    segmentCount = i;
                    break;
                }
                sum += profile.weights[i];
                if (i == 15) segmentCount = 16;
            }
        }

        if (segmentCount == 0) revert IErrors.InvalidInput();
        if (sum != 200) revert IErrors.InvalidInput();

        // Validate knots are monotonically increasing (for N segments, we have N+1 knots)
        uint256 knotCount = segmentCount + 1;
        unchecked {
            for (uint256 i = 1; i < knotCount; ++i) {
                if (profile.knots[i] < profile.knots[i - 1]) {
                    revert IErrors.InvalidInput();
                }
            }
        }

        // Validate dispersion constraint: max(knots) - min(knots) == 100
        // Since knots are monotonically increasing: min = knots[0], max = knots[knotCount-1]
        if (int16(profile.knots[knotCount - 1]) - int16(profile.knots[0]) != 100) {
            revert IErrors.InvalidInput();
        }
    }

    function _validateOracleConfig(IPoolV1.OracleConfig memory cfg) internal view {
        if (cfg.primary == address(0)) revert IErrors.InvalidInput();

        // Validate primary oracle exists and is callable
        if (cfg.primary != address(this)) {
            try IOracleV1(cfg.primary).getFeed(cfg.feedId) returns (IOracleV1.FeedData memory feed) {
                // Success - could cache this feed data for immediate use after validation
                // But since this is admin function (rare), caching benefit is minimal
            } catch {
                revert IErrors.InvalidInput();
            }
        }

        // Validate secondary oracle if configured
        if (cfg.secondary != address(0) && cfg.secondary != address(this)) {
            try IOracleV1(cfg.secondary).getFeed(cfg.feedId) returns (IOracleV1.FeedData memory) {
                // Success
            } catch {
                revert IErrors.InvalidInput();
            }
        }
    }

    // ========== FLOW GUARD (JIT PROTECTION) ==========

    /// @notice Set flow cooldown for deposit→withdraw and stake→unstake protection
    /// @dev No timelock needed - this is a protective parameter, not a risk-increasing one
    /// @param cooldownSeconds Cooldown duration in seconds (0 to disable)
    function setFlowCooldown(uint16 cooldownSeconds) external override onlyOwner {
        IPoolV1.PoolStorage storage $ = _s();
        uint16 oldCooldown = $.flowCooldownSeconds;
        $.flowCooldownSeconds = cooldownSeconds;
        emit IAdminV1.FlowCooldownUpdated(oldCooldown, cooldownSeconds);
    }

    // ========== ANCHOR TREE MANAGEMENT ==========

    /// @notice Set or update anchor for an asset
    /// @dev No timelock needed as this is a configuration change, not a risk change
    /// @param token The asset to configure
    /// @param anchor The parent asset in the tree (address(0) for root)
    function setAnchor(address token, address anchor) external onlyOwner {
        IPoolV1.PoolStorage storage $ = _s();
        address tokenNorm = _wrap($, token);

        // Validate asset exists
        IPoolV1.Asset storage asset = $.assets[tokenNorm];
        if (asset.decimals == 0) revert IErrors.NotFound(IErrors.Resource.ASSET, tokenNorm);

        // Import LibAnchorTree for validation
        uint8 depth = LibAnchorTree.validateAnchor($, tokenNorm, anchor);

        // Update anchor relationship
        asset.anchor = anchor;
        asset.anchorDepth = depth;

        // Note: Route caching removed - paths are recomputed on demand

        emit AnchorUpdated(tokenNorm, anchor, depth);
    }

    /// @notice Update asset pricing and risk parameters
    /// @dev No timelock as these are configuration changes (not irreversible)
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
        IPoolV1.PoolStorage storage $ = _s();
        address tokenNorm = _wrap($, token);

        IPoolV1.Asset storage asset = $.assets[tokenNorm];
        if (asset.decimals == 0) revert IErrors.NotFound(IErrors.Resource.ASSET, tokenNorm);

        // Validate fee bounds
        if (minFeeBps > maxFeeBps) revert IErrors.InvalidInput();

        asset.minLiquidity = minLiquidity;
        asset.minFeeBps = minFeeBps;
        asset.maxFeeBps = maxFeeBps;
        asset.gamma = gamma;
        asset.vega = vega;
        asset.lambda = lambda;
        asset.haircutSuppressor = haircutSuppressor;
        asset.reservationPrice = reservationPrice;

        emit AssetParamsUpdated(tokenNorm, minLiquidity, reservationPrice);
    }

    // Note: clearRouteCache removed - no caching needed

}