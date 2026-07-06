// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IAdmin} from "./interfaces/IAdmin.sol";
import {IPool} from "./interfaces/IPool.sol";
import {IHasTreasury} from "./interfaces/IHasTreasury.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Timelock as TL} from "@btr-shared/Timelock.sol";
import {AdminTimelock as ATL} from "./libraries/AdminTimelock.sol";

/// @title Admin
/// @notice Standalone singleton governance contract. Replaces the former Admin Diamond module.
/// @dev Phase 42H.B.3a -Admin no longer delegatecalls into Pool. It calls Pool's restricted
///      setters via standard external calls. Each public function takes `address pool` as the
///      first arg. Pending timelock ops are stored locally (per-pool keyed) instead of in
///      PoolStorage. Owner check goes through the shared singleton AccessControl.
contract Admin is IAdmin {
    /// @notice Shared singleton AccessControl -single source of truth for owner.
    address public immutable AC;

    /// @dev pendingOps[keccak256(pool, opId)] => packed Timelock value.
    ///      Wave-1: demoted public→internal (indexer reads via events; no on-chain consumer).
    mapping(bytes32 => uint96) internal pendingOps;
    /// @dev pendingData[keccak256(pool, opId)] => abi-encoded payload.
    ///      Wave-1: demoted public→internal (consumed only by `_consume`/`_cancel`).
    mapping(bytes32 => bytes) internal pendingData;

    // ── op-id namespaces (per-pool) ──
    bytes32 private constant OP_ADD_ASSET            = keccak256("ADD_ASSET");
    bytes32 private constant OP_UPDATE_RISK          = keccak256("UPDATE_RISK");
    bytes32 private constant OP_UPDATE_FEES          = keccak256("UPDATE_FEES");
    bytes32 private constant OP_UPDATE_BRIDGE        = keccak256("UPDATE_BRIDGE");
    bytes32 private constant OP_UPDATE_TREASURY      = keccak256("UPDATE_TREASURY");
    bytes32 private constant OP_BASE_MIGRATION       = keccak256("BASE_MIGRATION");
    bytes32 private constant OP_UPDATE_ORACLE        = keccak256("UPDATE_ORACLE");

    constructor(address ac_) {
        if (ac_ == address(0)) revert Err.ZeroAddr();
        AC = ac_;
    }

    modifier onlyAdmin() {
        if (msg.sender != AccessControl(AC).owner()) revert Ownable.Unauthorized();
        _;
    }

    function _key(address pool, bytes32 opId) internal pure returns (bytes32) {
        return keccak256(abi.encode(pool, opId));
    }

    function _keyToken(address pool, bytes32 opId, address token) internal pure returns (bytes32) {
        return keccak256(abi.encode(pool, opId, token));
    }

    function _emitQueued(bytes32 key, uint48 delay, bytes memory data, address pool, uint8 opType) internal {
        pendingOps[key] = TL.pack(delay, SC.GRACE_PERIOD);
        pendingData[key] = data;
        uint48 eta;
        unchecked { eta = uint48(block.timestamp) + delay; }
        emit TimelockRequested(pool, key, opType, eta);
    }

    function _consume(bytes32 key) internal returns (bytes memory data) {
        TL.validate(pendingOps[key]);
        data = pendingData[key];
        delete pendingOps[key];
        delete pendingData[key];
    }

    function _cancel(address pool, bytes32 key, uint8 opType) internal {
        if (pendingOps[key] == 0) revert Err.InvalidState();
        delete pendingOps[key];
        delete pendingData[key];
        emit TimelockCancelled(pool, key, opType);
    }

    // ─── one-shot setters ───

    function freezeAsset(address pool, address token) external onlyAdmin {
        IPool(pool).adminFreezeAsset(token);
        emit EmergencyFreeze(pool, token);
    }

    function unfreezeAsset(address pool, address token) external onlyAdmin {
        IPool(pool).adminUnfreezeAsset(token);
        emit EmergencyUnfreeze(pool, token);
    }

    /// @notice Guardian emergency halt for one asset on one pool (bit6, separate from FROZEN so
    ///         unpausing never clobbers an independent risk freeze). Protocol-wide = loop these over
    ///         PoolFactory.getPoolsForToken / getPoolTokens off-chain via Safe MultiSend (Multicall3
    ///         fails onlyAdmin — msg.sender must be the AC owner). // ponytail: onlyAdmin today; a
    ///         dedicated fast onlyPauser guardian (never the keeper key) is the next-layer upgrade.
    function pauseAsset(address pool, address token) external onlyAdmin {
        IPool(pool).adminPauseAsset(token);
        emit ProtocolPause(pool, token);
    }

    function unpauseAsset(address pool, address token) external onlyAdmin {
        IPool(pool).adminUnpauseAsset(token);
        emit ProtocolUnpause(pool, token);
    }

    /// @notice Batch a freeze/unfreeze/pause/unpause across (pool,token) pairs in ONE owner tx — works
    ///         from an EOA OR a multisig (no Safe MultiSend / Multicall3 needed; the loop runs inside
    ///         `Admin`, so `msg.sender` stays the AC owner throughout). The UI/operator enumerates pools
    ///         off-chain (`PoolFactory.officialPools` / `getPoolsForToken` / `getPoolTokens`) and passes
    ///         the arrays. Per-leg try/catch: a bad leg (uninit pool / unlisted asset) is SKIPPED +
    ///         logged (`BatchLegSkipped`), so one failure never bricks an emergency sweep — reconcile
    ///         from the events. // ponytail: onlyAdmin today; a dedicated fast onlyPauser guardian
    ///         (never the keeper key) is the next-layer upgrade.
    function batchRiskOp(address[] calldata pools, address[] calldata tokens, BatchOp op) external onlyAdmin {
        uint256 n = pools.length;
        if (n != tokens.length) revert Err.InvalidInput();
        for (uint256 i; i < n; ++i) {
            address p = pools[i];
            address t = tokens[i];
            bool ok;
            if (op == BatchOp.Pause) {
                try IPool(p).adminPauseAsset(t) { ok = true; } catch {}
            } else if (op == BatchOp.Unpause) {
                try IPool(p).adminUnpauseAsset(t) { ok = true; } catch {}
            } else if (op == BatchOp.Freeze) {
                try IPool(p).adminFreezeAsset(t) { ok = true; } catch {}
            } else {
                try IPool(p).adminUnfreezeAsset(t) { ok = true; } catch {}
            }
            if (ok) emit BatchRiskOp(p, t, uint8(op));
            else emit BatchLegSkipped(p, t);
        }
    }

    function addAsset(
        address pool,
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
    ) external onlyAdmin {
        IPool(pool).adminInitAsset(
            token, oracleCfg, riskCfg, profile, minFeeBps, decimals,
            minDispersion, maxDispersion, gamma, vega
        );
        emit AssetAdded(pool, token, decimals, 0);
    }

    function collectProtocolFees(address pool, address token, address recipient) external {
        // Gate: caller must be the pool's treasury (preserves prior semantics from
        // the former Admin module which checked `msg.sender == $.treasury`).
        if (msg.sender != IHasTreasury(pool).treasury()) revert Ownable.Unauthorized();
        uint256 amount = IPool(pool).adminCollectProtocolFees(token, recipient);
        emit ProtocolFeesCollected(pool, token, recipient, amount);
    }

    function setFlowCooldown(address pool, uint16 cooldownSeconds) external onlyAdmin {
        IPool(pool).adminSetFlowCooldown(cooldownSeconds);
        emit FlowCooldownUpdated(pool, 0, cooldownSeconds);
    }

    function setAnchor(address pool, address token, address anchor) external onlyAdmin {
        IPool(pool).adminSetAnchor(token, anchor);
        emit AnchorUpdated(pool, token, anchor, 0);
    }

    /// @notice R44-2 (T3-HIGH2): owner-only base-token oracle configuration. Untimelocked because
    ///         this is a SAFETY config (enables depeg halt). Operators MAY need to (re)pin under
    ///         duress; the only effect on the bad-actor axis is making swaps *stricter*
    ///         (revert-on-depeg), not looser. Pass `oracle = address(0)` to revert to the
    ///         legacy stable-base 1e18-hardcoded path.
    function setBaseTokenOracle(address pool, address oracle, bytes32 feedId) external onlyAdmin {
        IPool(pool).adminSetBaseTokenOracle(oracle, feedId);
    }

    function setAssetParams(
        address pool,
        address token,
        uint128 minLiquidity,
        uint16 minFeeBps,
        uint16 maxFeeBps,
        uint16 gamma,
        uint16 vega,
        uint16 haircutSuppressor,
        uint64 reservationPrice,
        uint64 reservationPriceMax
    ) external onlyAdmin {
        IPool(pool).adminSetAssetParams(
            token, minLiquidity, minFeeBps, maxFeeBps,
            gamma, vega, haircutSuppressor, reservationPrice, reservationPriceMax
        );
        emit AssetParamsUpdated(pool, token, minLiquidity, reservationPrice);
    }

    // ─── timelocked governance ───

    function requestAddAsset(
        address pool,
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
    ) external onlyAdmin {
        bytes32 key = _keyToken(pool, OP_ADD_ASSET, token);
        ATL.AddAssetPayload memory p = ATL.AddAssetPayload({
            token: token,
            oracleCfg: oracleCfg,
            riskCfg: riskCfg,
            profile: profile,
            minFeeBps: minFeeBps,
            decimals: decimals,
            minDispersion: minDispersion,
            maxDispersion: maxDispersion,
            gamma: gamma,
            vega: vega
        });
        _emitQueued(key, SC.LOW_TIMELOCK, ATL.encodeAddAsset(p), pool, uint8(IPool.OpType.ADD_ASSET));
    }

    function executeAddAsset(address pool, address token) external onlyAdmin {
        bytes32 key = _keyToken(pool, OP_ADD_ASSET, token);
        uint8 decimals = ATL.applyAddAsset(pool, token, _consume(key));
        emit AssetAdded(pool, token, decimals, 0);
    }

    function requestUpdateRiskConfig(address pool, address token, IPool.RiskConfig calldata cfg) external onlyAdmin {
        bytes32 key = _keyToken(pool, OP_UPDATE_RISK, token);
        _emitQueued(key, SC.LOW_TIMELOCK, abi.encode(token, cfg), pool, uint8(IPool.OpType.UPDATE_RISK));
    }

    function executeUpdateRiskConfig(address pool, address token) external onlyAdmin {
        bytes32 key = _keyToken(pool, OP_UPDATE_RISK, token);
        (address storedToken, IPool.RiskConfig memory cfg) = abi.decode(_consume(key), (address, IPool.RiskConfig));
        if (storedToken != token) revert Err.InvalidInput();
        IPool(pool).adminSetRiskConfig(token, cfg);
        emit RiskConfigUpdated(pool, token, cfg.flags, 0);
    }

    function requestUpdateFeeParams(address pool, IPool.FeeParams calldata params) external onlyAdmin {
        bytes32 key = _key(pool, OP_UPDATE_FEES);
        _emitQueued(key, SC.LOW_TIMELOCK, abi.encode(params), pool, uint8(IPool.OpType.UPDATE_FEES));
    }

    function executeUpdateFeeParams(address pool) external onlyAdmin {
        bytes32 key = _key(pool, OP_UPDATE_FEES);
        IPool.FeeParams memory params = abi.decode(_consume(key), (IPool.FeeParams));
        if (params.protoShare > 100) revert Err.InvalidInput();
        IPool(pool).adminSetFeeParams(params);
        emit FeeParamsUpdated(pool, params.protoShare, params.flashFeeBps);
    }

    function requestBridgeUpdate(address pool, address newBridge) external onlyAdmin {
        _emitQueued(_key(pool, OP_UPDATE_BRIDGE), SC.HIGH_TIMELOCK, abi.encode(newBridge), pool, uint8(IPool.OpType.UPDATE_BRIDGE));
    }

    function executeBridgeUpdate(address pool) external onlyAdmin {
        address newBridge = abi.decode(_consume(_key(pool, OP_UPDATE_BRIDGE)), (address));
        IPool(pool).adminSetBridge(newBridge);
        emit BridgeUpdated(pool, address(0), newBridge);
    }

    function requestTreasuryUpdate(address pool, address newTreasury) external onlyAdmin {
        if (newTreasury == address(0)) revert Err.ZeroValue();
        _emitQueued(_key(pool, OP_UPDATE_TREASURY), SC.HIGH_TIMELOCK, abi.encode(newTreasury), pool, uint8(IPool.OpType.UPDATE_TREASURY));
    }

    function executeTreasuryUpdate(address pool) external onlyAdmin {
        address newTreasury = abi.decode(_consume(_key(pool, OP_UPDATE_TREASURY)), (address));
        IPool(pool).adminSetTreasury(newTreasury);
        emit TreasuryUpdated(pool, address(0), newTreasury);
    }

    function requestBaseMigration(address pool, address newBase) external onlyAdmin {
        _emitQueued(_key(pool, OP_BASE_MIGRATION), SC.CRITICAL_TIMELOCK, abi.encode(newBase), pool, uint8(IPool.OpType.MIGRATE_BASE_TOKEN));
    }

    function executeBaseMigration(address pool) external onlyAdmin {
        address newBase = abi.decode(_consume(_key(pool, OP_BASE_MIGRATION)), (address));
        IPool(pool).adminSetBaseToken(newBase);
        emit BaseTokenMigrated(pool, address(0), newBase);
    }

    function requestOracleUpdate(address pool, address token, IPool.OracleConfig calldata cfg) external onlyAdmin {
        bytes32 key = _keyToken(pool, OP_UPDATE_ORACLE, token);
        _emitQueued(key, SC.BASE_TIMELOCK, abi.encode(token, cfg), pool, uint8(IPool.OpType.UPDATE_ORACLE));
    }

    function executeOracleUpdate(address pool, address token) external onlyAdmin {
        bytes32 key = _keyToken(pool, OP_UPDATE_ORACLE, token);
        (address storedToken, IPool.OracleConfig memory cfg) = abi.decode(_consume(key), (address, IPool.OracleConfig));
        if (storedToken != token) revert Err.InvalidInput();
        IPool(pool).adminSetOracleConfig(token, cfg);
        emit OracleUpdated(pool, token);
    }

    function cancelOracleUpdate(address pool, address token) external onlyAdmin {
        _cancel(pool, _keyToken(pool, OP_UPDATE_ORACLE, token), uint8(IPool.OpType.UPDATE_ORACLE));
    }

    function cancelAddAsset(address pool, address token) external onlyAdmin {
        _cancel(pool, _keyToken(pool, OP_ADD_ASSET, token), uint8(IPool.OpType.ADD_ASSET));
    }

    function cancelUpdateRiskConfig(address pool, address token) external onlyAdmin {
        _cancel(pool, _keyToken(pool, OP_UPDATE_RISK, token), uint8(IPool.OpType.UPDATE_RISK));
    }

    function cancelTimelock(address pool, uint8 opType) external onlyAdmin {
        bytes32 key;
        if (opType == uint8(IPool.OpType.MIGRATE_BASE_TOKEN)) key = _key(pool, OP_BASE_MIGRATION);
        else if (opType == uint8(IPool.OpType.UPDATE_BRIDGE)) key = _key(pool, OP_UPDATE_BRIDGE);
        else if (opType == uint8(IPool.OpType.UPDATE_TREASURY)) key = _key(pool, OP_UPDATE_TREASURY);
        else if (opType == uint8(IPool.OpType.UPDATE_FEES)) key = _key(pool, OP_UPDATE_FEES);
        else revert Err.InvalidInput();
        _cancel(pool, key, opType);
    }
}
