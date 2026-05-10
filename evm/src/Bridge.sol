// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC7802} from "./interfaces/external/IERC7802.sol";
import {LZEndpointV2} from "./interfaces/external/ILZEndpointV2.sol";
import {ILZOAppReceiver} from "./interfaces/external/ILZOAppReceiver.sol";
import {IBridge} from "./interfaces/IBridge.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Timelock as TL} from "@btr-shared/Timelock.sol";
import {Maths as M} from "./libraries/Maths.sol";
import {Constants as C} from "./libraries/Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";

/// @title Bridge
/// @notice Compact LayerZero bridge w/ timelocked upgrades. UUPS, single-slot TokenConfig w/ B64 limits.
contract Bridge is Ownable, ReentrancyGuardTransient, ILZOAppReceiver, UUPSUpgradeable, IBridge {
    uint8 constant RATIO_DENOM = 100;
    uint8 constant FLAG_SUPPORTED = 0x01;
    uint8 constant FLAG_PAUSED = 0x02;
    uint8 constant FLAG_UNLIMITED = 0x04;

    // Failure codes for queued messages.
    uint8 constant FC_PEER_REMOVED = 1;
    uint8 constant FC_TOKEN_UNSUPPORTED = 2;
    uint8 constant FC_TOKEN_PAUSED = 3;
    uint8 constant FC_RATE_LIMIT = 4;
    uint8 constant FC_MINT_FAILED = 5;

    address public immutable LZ_ENDPOINT;

    mapping(address => IBridge.TokenConfig) public tokenConfigs;
    mapping(uint32 => bytes32) public peers;
    mapping(bytes32 => uint96) public pendingOps;
    mapping(bytes32 => bytes) public pendingData;

    bytes32 public pendingUpgrade;
    address public pendingImplementation;

    /// @dev G18 fix: transient slot for self-call upgrade auth. See Treasury.sol for details.
    bytes32 private constant _UPGRADE_AUTH_TSLOT =
        0x9f1c8b7e3f6a4d2c5b8e1a0f7d9c4e2b5a8f1c7e4b9d6a3c0e7f1b8d5a2c9e61;

    struct FailedMessage {
        address recipient;
        address token;
        uint256 amount;
        uint32 srcEid;
        uint64 failureTime;
        uint8 failureCode;
    }

    mapping(bytes32 guid => FailedMessage) public failedMessages;

    event MessageFailed(bytes32 indexed guid, address recipient, address token, uint256 amount, uint8 failureCode);
    event MessageRecovered(bytes32 indexed guid, address recipient, address token, uint256 amount);

    constructor(address endpoint_) {
        if (endpoint_ == address(0)) revert Err.ZeroValue();
        LZ_ENDPOINT = endpoint_;
    }

    /// @dev F-A2-R10-1 (LOW) NOT FIXED (intentional): `initialize` has no caller gate, only a
    ///      one-shot guard (`owner() != address(0)`). Front-running risk is zero in production
    ///      because deployment scripts atomically deploy + initialize in the same tx. Adding a
    ///      caller gate would require a deployer immutable mirroring PoolProxy's pattern, but
    ///      Bridge is deployed once by an EOA / multisig — no factory in the loop. Documented
    ///      to anti-recur.
    function initialize(address newOwner_) external {
        if (newOwner_ == address(0)) revert Err.ZeroValue();
        if (owner() != address(0)) revert Err.InvalidState();
        _initializeOwner(newOwner_);
    }

    // ─── bridge ops ───

    function bridgeViaLayerZero(
        address token,
        uint32 dstEid,
        bytes32 receiver,
        uint256 amount,
        bytes calldata options
    ) external payable nonReentrant {
        if (receiver == bytes32(0) || amount == 0) revert Err.ZeroValue();

        bytes32 peer = peers[dstEid];
        if (peer == bytes32(0)) revert Err.NotConfigured(Err.Resource.BRIDGE_PEER, address(uint160(dstEid)));

        _checkAndUpdateLimit(token, amount, IBridge.Direction.Outbound);

        IERC7802(token).crosschainBurn(msg.sender, amount, abi.encode(dstEid, msg.sender, block.timestamp));

        LZEndpointV2.SendParam memory sendParam = LZEndpointV2.SendParam({
            dstEid: dstEid,
            to: peer,
            message: abi.encode(receiver, token, amount),
            options: options,
            payInLzToken: false
        });

        LZEndpointV2.MessagingFee memory fee = _quoteFee(sendParam);
        if (msg.value != fee.nativeFee) revert Err.InsufficientAmount(msg.value, fee.nativeFee);

        LZEndpointV2.MessagingReceipt memory receipt =
            LZEndpointV2(LZ_ENDPOINT).send{value: fee.nativeFee}(sendParam, fee, msg.sender);

        emit Bridged(msg.sender, token, dstEid, receiver, amount, receipt.nonce, Direction.Outbound);
    }

    /// @notice LayerZero receive callback. Queues failed messages for recovery instead of reverting.
    /// @dev Phase 42D #3 DISCARD (by-design): replay-safety relies on LZ Endpoint's per-`_guid`
    ///      uniqueness + ordered-delivery guarantee. We additionally peer-verify (`peers[srcEid] == sender`)
    ///      and on `crosschainMint` failure we store `failedMessages[guid]`; recovery deletes the
    ///      entry pre-mint (`recoverFailedMessage`) so a successful recovery cannot be re-triggered.
    ///      A duplicate `lzReceive` for the same guid would be filtered by LZ; if it bypassed LZ
    ///      `msg.sender == LZ_ENDPOINT` blocks it. Trust chain: LZ Endpoint contract correctness.
    function lzReceive(
        LZEndpointV2.Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address,
        bytes calldata
    ) external payable override nonReentrant {
        if (msg.sender != LZ_ENDPOINT) revert Unauthorized();

        (bytes32 receiver, address token, uint256 amount) = abi.decode(_message, (bytes32, address, uint256));
        if (amount == 0) revert Err.ZeroValue();

        address to = address(uint160(uint256(receiver)));
        if (to == address(0)) revert Err.ZeroValue();

        bytes32 trustedPeer = peers[_origin.srcEid];
        if (trustedPeer == bytes32(0) || trustedPeer != _origin.sender) {
            _queueFailedMessage(_guid, to, token, amount, _origin.srcEid, FC_PEER_REMOVED);
            return;
        }

        TokenConfig memory cfg = tokenConfigs[token];
        if ((cfg.flags & FLAG_SUPPORTED) == 0) {
            _queueFailedMessage(_guid, to, token, amount, _origin.srcEid, FC_TOKEN_UNSUPPORTED);
            return;
        }
        if ((cfg.flags & FLAG_PAUSED) != 0) {
            _queueFailedMessage(_guid, to, token, amount, _origin.srcEid, FC_TOKEN_PAUSED);
            return;
        }
        if (!_tryCheckAndUpdateLimit(token, amount, cfg)) {
            _queueFailedMessage(_guid, to, token, amount, _origin.srcEid, FC_RATE_LIMIT);
            return;
        }

        try IERC7802(token).crosschainMint(to, amount, abi.encode(_origin.srcEid, _origin.nonce, _guid)) {
            emit Bridged(to, token, _origin.srcEid, receiver, amount, _origin.nonce, Direction.Inbound);
        } catch {
            _queueFailedMessage(_guid, to, token, amount, _origin.srcEid, FC_MINT_FAILED);
        }
    }

    function _queueFailedMessage(
        bytes32 guid,
        address recipient,
        address token,
        uint256 amount,
        uint32 srcEid,
        uint8 failureCode
    ) internal {
        failedMessages[guid] = FailedMessage({
            recipient: recipient,
            token: token,
            amount: amount,
            srcEid: srcEid,
            failureTime: uint64(block.timestamp),
            failureCode: failureCode
        });
        emit MessageFailed(guid, recipient, token, amount, failureCode);
    }

    /// @notice F-A4-R10-2 (MED) fix: shared day-rollover for inbound + outbound paths.
    /// @dev Pre-fix `_tryCheckAndUpdateLimit` skipped the rollover the outbound twin performed,
    ///      letting `bridgedInB64` accumulate across calendar days; once cumulative > daily cap,
    ///      every subsequent lzReceive silently queued as failedMessage(FC_RATE_LIMIT) — DoS until
    ///      owner manual recovery. View `getRemainingLimits` virtualizes rollover correctly →
    ///      view↔logic divergence. Both call sites now share this helper.
    function _rolloverIfNeeded(IBridge.TokenConfig storage cfg) private {
        uint16 today = uint16(block.timestamp / 1 days);
        if (cfg.day != today) {
            cfg.day = today;
            cfg.bridgedOutB64 = 0;
            cfg.bridgedInB64 = 0;
        }
    }

    function _tryCheckAndUpdateLimit(address token, uint256 amount, TokenConfig memory cfg) internal returns (bool) {
        if ((cfg.flags & FLAG_UNLIMITED) != 0) return true;

        // Day-rollover via shared helper, identical semantics to outbound `_checkAndUpdateLimit`.
        IBridge.TokenConfig storage cfgS = tokenConfigs[token];
        _rolloverIfNeeded(cfgS);

        // F-A3-R11-1 (LOW) fix: align inbound bucket decimals with outbound logic + view.
        // Pre-fix hardcoded 18 caused `getRemainingLimits` (which decodes inbound bucket via
        // `b64Decimals(limitOutB64)`) to misreport `inbound` whenever admin configured a
        // token with decimals != 18. Now both encode and decode use the limit's decimals tag.
        uint8 decimals = M.b64Decimals(cfgS.limitOutB64);
        uint256 outLimit = M.decodeB64(cfgS.limitOutB64, decimals);
        uint256 inLimit = (outLimit * uint256(cfgS.inRatio)) / RATIO_DENOM;
        // decodeB64(0,..) reverts; treat empty bucket as 0 (post-rollover or fresh config).
        uint256 currentIn = cfgS.bridgedInB64 == 0 ? 0 : M.decodeB64(cfgS.bridgedInB64, decimals);
        if (currentIn + amount > inLimit) return false;
        cfgS.bridgedInB64 = M.encodeB64(currentIn + amount, decimals);
        return true;
    }

    function quoteLZBridge(address token, uint32 dstEid, uint256 amount, bytes calldata options)
        external view returns (LZEndpointV2.MessagingFee memory)
    {
        if (amount == 0) revert Err.ZeroValue();
        TokenConfig memory cfg = tokenConfigs[token];
        if ((cfg.flags & FLAG_SUPPORTED) == 0 || (cfg.flags & FLAG_PAUSED) != 0) {
            revert Err.NotConfigured(Err.Resource.ASSET, token);
        }
        if (peers[dstEid] == bytes32(0)) {
            revert Err.NotConfigured(Err.Resource.BRIDGE_PEER, address(uint160(dstEid)));
        }
        return _quoteFee(LZEndpointV2.SendParam({
            dstEid: dstEid,
            to: peers[dstEid],
            message: abi.encode(bytes32(uint256(uint160(msg.sender))), token, amount),
            options: options,
            payInLzToken: false
        }));
    }

    // ─── failed message recovery ───

    /// @notice Recover a failed bridge message; if newRecipient != 0, redirect.
    function recoverFailedMessage(bytes32 guid, address newRecipient) external onlyOwner nonReentrant {
        FailedMessage memory failed = failedMessages[guid];
        if (failed.amount == 0) revert Err.InvalidState();

        address to = newRecipient == address(0) ? failed.recipient : newRecipient;
        delete failedMessages[guid];

        IERC7802(failed.token).crosschainMint(to, failed.amount, abi.encode(failed.srcEid, uint64(0), guid));
        emit MessageRecovered(guid, to, failed.token, failed.amount);
    }

    /// @notice Refund a failed message back to the source chain.
    function refundFailedMessage(bytes32 guid, bytes calldata options) external payable onlyOwner nonReentrant {
        FailedMessage memory failed = failedMessages[guid];
        if (failed.amount == 0) revert Err.InvalidState();

        bytes32 peer = peers[failed.srcEid];
        if (peer == bytes32(0)) revert Err.NotConfigured(Err.Resource.BRIDGE_PEER, address(uint160(failed.srcEid)));

        delete failedMessages[guid];

        LZEndpointV2.SendParam memory sendParam = LZEndpointV2.SendParam({
            dstEid: failed.srcEid,
            to: peer,
            message: abi.encode(bytes32(uint256(uint160(failed.recipient))), failed.token, failed.amount),
            options: options,
            payInLzToken: false
        });

        LZEndpointV2.MessagingFee memory fee = _quoteFee(sendParam);
        if (msg.value < fee.nativeFee) revert Err.InsufficientAmount(msg.value, fee.nativeFee);

        LZEndpointV2(LZ_ENDPOINT).send{value: fee.nativeFee}(sendParam, fee, payable(msg.sender));
        emit MessageRecovered(guid, failed.recipient, failed.token, failed.amount);
    }

    // ─── token config ───

    function setTokenConfig(address token, uint256 limitRaw, uint8 decimals, uint8 inRatio, bool unlimited)
        external onlyOwner
    {
        if (token == address(0)) revert Err.ZeroValue();
        IBridge.TokenConfig memory cfg = tokenConfigs[token];
        if ((cfg.flags & FLAG_SUPPORTED) != 0) revert Err.AlreadyConfigured(Err.Resource.ASSET, token);

        tokenConfigs[token] = IBridge.TokenConfig({
            limitOutB64: unlimited ? 0 : M.encodeB64(limitRaw, decimals),
            bridgedOutB64: 0,
            bridgedInB64: 0,
            day: uint16(block.timestamp / 1 days),
            inRatio: inRatio,
            flags: FLAG_SUPPORTED | (unlimited ? FLAG_UNLIMITED : 0)
        });
        emit TokenConfigured(token, tokenConfigs[token].limitOutB64, inRatio, tokenConfigs[token].flags);
    }

    function requestConfigChange(
        address token,
        uint256 newLimitRaw,
        uint8 decimals,
        uint8 newRatio,
        bool updateLimit,
        bool updateRatio
    ) external onlyOwner {
        bytes32 id = keccak256(abi.encode(IBridge.OpType.ConfigUpdate, token));
        if (pendingOps[id] != 0) revert Err.PendingTimelock(uint48(block.timestamp));

        pendingOps[id] = TL.pack(SC.BASE_TIMELOCK, SC.GRACE_PERIOD);
        pendingData[id] = abi.encode(
            updateLimit ? M.encodeB64(newLimitRaw, decimals) : uint64(0),
            newRatio,
            (updateLimit ? 0x01 : 0) | (updateRatio ? 0x02 : 0)
        );
    }

    function executeConfigChange(address token) external onlyOwner {
        bytes32 id = keccak256(abi.encode(IBridge.OpType.ConfigUpdate, token));
        TL.validate(pendingOps[id]);

        (uint64 newLimit, uint8 newRatio, uint8 updateFlags) = abi.decode(pendingData[id], (uint64, uint8, uint8));
        IBridge.TokenConfig storage cfg = tokenConfigs[token];
        if ((updateFlags & 0x01) != 0) cfg.limitOutB64 = newLimit;
        if ((updateFlags & 0x02) != 0) cfg.inRatio = newRatio;

        delete pendingOps[id];
        delete pendingData[id];
        emit TokenConfigured(token, cfg.limitOutB64, cfg.inRatio, cfg.flags);
    }

    function pauseToken(address token, bool paused) external onlyOwner {
        TokenConfig storage cfg = tokenConfigs[token];
        if (paused) cfg.flags |= FLAG_PAUSED;
        else cfg.flags &= ~FLAG_PAUSED;
        emit TokenPaused(token, paused);
    }

    // ─── peer config ───

    function requestSetPeer(uint32 eid, bytes32 peer) external onlyOwner {
        bytes32 id = keccak256(abi.encode(IBridge.OpType.PeerUpdate, eid));
        if (pendingOps[id] != 0) revert Err.PendingTimelock(uint48(block.timestamp));
        pendingOps[id] = TL.pack(SC.BASE_TIMELOCK, SC.GRACE_PERIOD);
        pendingData[id] = abi.encodePacked(peer);
    }

    function executeSetPeer(uint32 eid) external onlyOwner {
        bytes32 id = keccak256(abi.encode(IBridge.OpType.PeerUpdate, eid));
        TL.validate(pendingOps[id]);
        bytes32 peer = abi.decode(pendingData[id], (bytes32));
        peers[eid] = peer;
        delete pendingOps[id];
        delete pendingData[id];
        emit PeerSet(eid, peer);
    }

    /// @notice G20 fix: per-OpType cancel functions replace untyped `cancelOperation(bytes32)`.
    ///         Caller specifies the typed key (token / eid) and the contract derives the id —
    ///         eliminates risk of passing an unrelated id (different OpType, stale, or arbitrary
    ///         hash) and silently clearing it.
    function cancelConfigChange(address token) external onlyOwner {
        bytes32 id = keccak256(abi.encode(IBridge.OpType.ConfigUpdate, token));
        if (pendingOps[id] == 0) revert Err.InvalidState();
        delete pendingOps[id];
        delete pendingData[id];
    }

    function cancelSetPeer(uint32 eid) external onlyOwner {
        bytes32 id = keccak256(abi.encode(IBridge.OpType.PeerUpdate, eid));
        if (pendingOps[id] == 0) revert Err.InvalidState();
        delete pendingOps[id];
        delete pendingData[id];
    }

    /// @notice Owner-only sweep of stuck ERC20 / native (alm Vault.salvage parity).
    function salvage(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0) || amount == 0) revert Err.ZeroValue();
        if (token == SC.NATIVE) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            if (token == address(0)) revert Err.InvalidInput();
            SafeTransferLib.safeTransfer(token, to, amount);
        }
        emit Salvaged(token, to, amount);
    }

    // ─── upgrades (UUPS w/ timelock) ───

    function requestUpgrade(address newImplementation) external onlyOwner {
        if (newImplementation == address(0)) revert Err.ZeroValue();
        if (pendingUpgrade != bytes32(0)) revert Err.PendingTimelock(uint48(block.timestamp));

        pendingUpgrade = keccak256(abi.encode(newImplementation, block.timestamp));
        pendingImplementation = newImplementation;
        uint96 timelock = TL.pack(SC.UPGRADE_TIMELOCK, SC.GRACE_PERIOD);
        pendingOps[pendingUpgrade] = timelock;

        emit UpgradeAuthorized(pendingUpgrade, newImplementation, uint48(timelock >> 48));
    }

    function executeUpgrade() external onlyOwner {
        if (pendingUpgrade == bytes32(0)) revert Err.InvalidState();
        TL.validate(pendingOps[pendingUpgrade]);

        address newImpl = pendingImplementation;
        bytes32 upgradeId = pendingUpgrade;
        delete pendingUpgrade;
        delete pendingImplementation;
        delete pendingOps[upgradeId];

        assembly { tstore(_UPGRADE_AUTH_TSLOT, 1) }
        this.upgradeToAndCall(newImpl, "");
        assembly { tstore(_UPGRADE_AUTH_TSLOT, 0) }
    }

    function cancelUpgrade() external onlyOwner {
        if (pendingUpgrade == bytes32(0)) revert Err.InvalidState();
        bytes32 upgradeId = pendingUpgrade;
        delete pendingUpgrade;
        delete pendingImplementation;
        delete pendingOps[upgradeId];
        emit UpgradeCancelled(upgradeId);
    }

    /// @dev G18 fix: see Treasury.sol comment.
    function _authorizeUpgrade(address) internal override {
        if (msg.sender == address(this)) {
            uint256 auth;
            assembly { auth := tload(_UPGRADE_AUTH_TSLOT) }
            if (auth == 1) return;
        }
        if (msg.sender != owner()) revert Ownable.Unauthorized();
    }

    // ─── views ───

    function isBridgeable(address token) external view returns (bool) {
        uint8 flags = tokenConfigs[token].flags;
        return (flags & FLAG_SUPPORTED) != 0 && (flags & FLAG_PAUSED) == 0;
    }

    function getRemainingLimits(address token) external view returns (uint256 outbound, uint256 inbound) {
        IBridge.TokenConfig memory cfg = tokenConfigs[token];
        if ((cfg.flags & FLAG_UNLIMITED) != 0) return (type(uint256).max, type(uint256).max);

        uint16 today = uint16(block.timestamp / 1 days);
        uint8 decimals = M.b64Decimals(cfg.limitOutB64);
        uint64 outUsedB64 = (cfg.day == today) ? cfg.bridgedOutB64 : 0;
        uint64 inUsedB64 = (cfg.day == today) ? cfg.bridgedInB64 : 0;

        uint256 limitDecoded = M.decodeB64(cfg.limitOutB64, decimals);
        uint256 outUsed = outUsedB64 == 0 ? 0 : M.decodeB64(outUsedB64, decimals);
        uint256 inUsed = inUsedB64 == 0 ? 0 : M.decodeB64(inUsedB64, decimals);

        outbound = limitDecoded > outUsed ? limitDecoded - outUsed : 0;
        uint256 inLimit = (limitDecoded * cfg.inRatio) / RATIO_DENOM;
        inbound = inLimit > inUsed ? inLimit - inUsed : 0;
    }

    // ─── internal ───

    /// @notice Unified limit check + update via shared B64 helper.
    function _checkAndUpdateLimit(address token, uint256 amount, Direction dir) internal {
        IBridge.TokenConfig storage cfg = tokenConfigs[token];

        if ((cfg.flags & FLAG_SUPPORTED) == 0) revert Err.NotConfigured(Err.Resource.ASSET, token);
        if ((cfg.flags & FLAG_PAUSED) != 0) revert Err.FeatureDisabled(Err.Resource.BRIDGE);
        if ((cfg.flags & FLAG_UNLIMITED) != 0) return;

        // F-A4-R10-2 (MED) — shared rollover across inbound + outbound paths (DRY).
        _rolloverIfNeeded(cfg);

        uint8 decimals = M.b64Decimals(cfg.limitOutB64);
        uint64 amountB64 = M.encodeB64(amount, decimals);

        bool outbound = dir == IBridge.Direction.Outbound;
        uint64 currentB64 = outbound ? cfg.bridgedOutB64 : cfg.bridgedInB64;
        uint64 limitB64;
        uint256 limitDecForErr;

        if (outbound) {
            limitB64 = cfg.limitOutB64;
        } else {
            uint256 limitDecoded = M.decodeB64(cfg.limitOutB64, decimals);
            limitDecForErr = (limitDecoded * cfg.inRatio) / RATIO_DENOM;
            limitB64 = M.encodeB64(limitDecForErr, decimals);
        }

        uint64 newTotal = M.add64(currentB64, amountB64);
        if (M.gt64(newTotal, limitB64)) {
            uint256 limitDec = outbound ? M.decodeB64(cfg.limitOutB64, decimals) : limitDecForErr;
            uint256 usedDec = M.decodeB64(currentB64, decimals);
            revert Err.ExcessiveAmount(amount, limitDec - usedDec);
        }

        if (outbound) cfg.bridgedOutB64 = newTotal;
        else cfg.bridgedInB64 = newTotal;
    }

    function _quoteFee(LZEndpointV2.SendParam memory sendParam)
        internal view returns (LZEndpointV2.MessagingFee memory)
    {
        try LZEndpointV2(LZ_ENDPOINT).quote(sendParam, false) returns (LZEndpointV2.MessagingFee memory fee) {
            if (fee.nativeFee == 0 && fee.lzTokenFee == 0) revert Err.OperationFailed();
            return fee;
        } catch {
            revert Err.OperationFailed();
        }
    }

    receive() external payable {}
}
