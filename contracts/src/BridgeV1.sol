// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC7802} from "./interfaces/external/IERC7802.sol";
import {LZEndpointV2} from "./interfaces/external/ILZEndpointV2.sol";
import {ILZOAppReceiver} from "./interfaces/external/ILZOAppReceiver.sol";
import {IBridgeV1} from "./interfaces/IBridgeV1.sol";
import {Err} from "./Errors.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {LibTimelock as TL} from "./libraries/LibTimelock.sol";
import {LibRescue} from "./libraries/LibRescue.sol";
import {LibMaths as M} from "./libraries/LibMaths.sol";
import {LibConstants as C} from "./libraries/LibConstants.sol";

/// @title BridgeV1
/// @notice Ultra-compact LayerZero bridge with timelocked upgrades
/// @dev UUPS upgradeable, unified pending ops, single-slot TokenConfig with B64 limits
contract BridgeV1 is Ownable, ReentrancyGuard, ILZOAppReceiver, UUPSUpgradeable, IBridgeV1 {

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    uint8 constant RATIO_DENOM = 100;
    // Timelock constants from LibConstants: C.BASE_TIMELOCK, C.GRACE_PERIOD, C.UPGRADE_TIMELOCK

    uint8 constant FLAG_SUPPORTED = 0x01;
    uint8 constant FLAG_PAUSED = 0x02;
    uint8 constant FLAG_UNLIMITED = 0x04;

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    address public immutable LZ_ENDPOINT;

    mapping(address => IBridgeV1.TokenConfig) public tokenConfigs;
    mapping(uint32 => bytes32) public peers;
    mapping(bytes32 => uint96) public pendingOps;      // Unified timelock ops
    mapping(bytes32 => bytes) public pendingData;      // Op data

    // Upgrade mechanism
    bytes32 public pendingUpgrade;
    address public pendingImplementation;

    // ═══════════════════════════════════════════════════════════════════════════
    // SECURITY FIX (CRITICAL-6): Failed Message Recovery Queue
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Stores failed bridge messages for later recovery
    struct FailedMessage {
        address recipient;      // Target recipient
        address token;          // Token to mint
        uint256 amount;         // Amount to mint
        uint32 srcEid;          // Source chain ID
        uint64 failureTime;     // When the failure occurred
        uint8 failureCode;      // 1=peer_removed, 2=token_paused, 3=rate_limit, 4=mint_failed
    }

    /// @dev Maps GUID => FailedMessage for recovery
    mapping(bytes32 guid => FailedMessage) public failedMessages;

    /// @dev Emitted when a bridge message fails and is queued for recovery
    event MessageFailed(bytes32 indexed guid, address recipient, address token, uint256 amount, uint8 failureCode);

    /// @dev Emitted when a failed message is recovered
    event MessageRecovered(bytes32 indexed guid, address recipient, address token, uint256 amount);

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address endpoint) {
        if (endpoint == address(0)) revert Err.ZeroValue();
        LZ_ENDPOINT = endpoint;
    }

    /// @notice Initialize bridge (one-time, called via proxy)
    function initialize(address newOwner) external {
        if (newOwner == address(0)) revert Err.ZeroValue();
        // Ensure initialize is only called once
        if (owner() != address(0)) revert Err.InvalidState();
        _initializeOwner(newOwner);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BRIDGE OPERATIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Bridge tokens via LayerZero
    function bridgeViaLayerZero(
        address token,
        uint32 dstEid,
        bytes32 receiver,
        uint256 amount,
        bytes calldata options
    ) external payable nonReentrant {
        if (receiver == bytes32(0)) revert Err.ZeroValue();
        if (amount == 0) revert Err.ZeroValue();

        bytes32 peer = peers[dstEid];
        if (peer == bytes32(0)) revert Err.NotConfigured(Err.Resource.BRIDGE_PEER, address(uint160(dstEid)));

        _checkAndUpdateLimit(token, amount, IBridgeV1.Direction.Outbound);

        // Burn tokens
        IERC7802(token).crosschainBurn(msg.sender, amount, abi.encode(dstEid, msg.sender, block.timestamp));

        // Send via LayerZero
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

    /// @notice LayerZero receive callback
    /// @dev SECURITY FIX (CRITICAL-6): Queues failed messages for recovery instead of reverting
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

        // SECURITY FIX (CRITICAL-6): Check peer - queue for recovery if failed
        bytes32 trustedPeer = peers[_origin.srcEid];
        if (trustedPeer == bytes32(0) || trustedPeer != _origin.sender) {
            _queueFailedMessage(_guid, to, token, amount, _origin.srcEid, 1); // 1 = peer_removed
            return;
        }

        // SECURITY FIX (CRITICAL-6): Check rate limit - queue for recovery if exceeded
        TokenConfig memory cfg = tokenConfigs[token];
        if ((cfg.flags & FLAG_SUPPORTED) == 0) {
            _queueFailedMessage(_guid, to, token, amount, _origin.srcEid, 2); // 2 = token_not_supported
            return;
        }
        if ((cfg.flags & FLAG_PAUSED) != 0) {
            _queueFailedMessage(_guid, to, token, amount, _origin.srcEid, 3); // 3 = token_paused
            return;
        }

        // Check rate limit (non-reverting version)
        if (!_tryCheckAndUpdateLimit(token, amount, cfg)) {
            _queueFailedMessage(_guid, to, token, amount, _origin.srcEid, 4); // 4 = rate_limit_exceeded
            return;
        }

        // SECURITY FIX (CRITICAL-6): Try mint - queue for recovery if fails
        try IERC7802(token).crosschainMint(to, amount, abi.encode(_origin.srcEid, _origin.nonce, _guid)) {
            emit Bridged(to, token, _origin.srcEid, receiver, amount, _origin.nonce, Direction.Inbound);
        } catch {
            _queueFailedMessage(_guid, to, token, amount, _origin.srcEid, 5); // 5 = mint_failed
        }
    }

    /// @dev Queue a failed message for later recovery
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

    /// @dev Non-reverting rate limit check
    function _tryCheckAndUpdateLimit(
        address token,
        uint256 amount,
        TokenConfig memory cfg
    ) internal returns (bool) {
        // Check if unlimited
        if ((cfg.flags & FLAG_UNLIMITED) != 0) return true;

        // Decode limits - inbound limit is outbound limit * inRatio / 100
        uint256 outLimit = M.decodeB64(cfg.limitOutB64, 18);
        uint256 inLimit = (outLimit * uint256(cfg.inRatio)) / RATIO_DENOM;
        uint256 currentIn = M.decodeB64(cfg.bridgedInB64, 18);

        // Check if limit would be exceeded
        if (currentIn + amount > inLimit) return false;

        // Update accumulator
        tokenConfigs[token].bridgedInB64 = M.encodeB64(currentIn + amount, 18);
        return true;
    }

    /// @notice Quote bridge fee
    function quoteLZBridge(
        address token,
        uint32 dstEid,
        uint256 amount,
        bytes calldata options
    ) external view returns (LZEndpointV2.MessagingFee memory) {
        if (amount == 0) revert Err.ZeroValue();

        TokenConfig memory cfg = tokenConfigs[token];
        if ((cfg.flags & FLAG_SUPPORTED) == 0 || (cfg.flags & FLAG_PAUSED) != 0) {
            revert Err.NotConfigured(Err.Resource.ASSET, token);
        }
        if (peers[dstEid] == bytes32(0)) revert Err.NotConfigured(Err.Resource.BRIDGE_PEER, address(uint160(dstEid)));

        return _quoteFee(LZEndpointV2.SendParam({
            dstEid: dstEid,
            to: peers[dstEid],
            message: abi.encode(bytes32(uint256(uint160(msg.sender))), token, amount),
            options: options,
            payInLzToken: false
        }));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECURITY FIX (CRITICAL-6): FAILED MESSAGE RECOVERY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Recover a failed bridge message
    /// @dev SECURITY FIX (CRITICAL-6): Allows owner to retry failed messages
    /// @param guid The LayerZero message GUID
    function recoverFailedMessage(bytes32 guid) external onlyOwner nonReentrant {
        FailedMessage memory failed = failedMessages[guid];
        if (failed.amount == 0) revert Err.InvalidState(); // No such failed message

        // Delete before external call (reentrancy protection)
        delete failedMessages[guid];

        // Attempt to mint
        IERC7802(failed.token).crosschainMint(
            failed.recipient,
            failed.amount,
            abi.encode(failed.srcEid, uint64(0), guid)
        );

        emit MessageRecovered(guid, failed.recipient, failed.token, failed.amount);
    }

    /// @notice Recover a failed message to a different recipient
    /// @dev For cases where original recipient address was wrong or compromised
    /// @param guid The LayerZero message GUID
    /// @param newRecipient New address to receive the tokens
    function recoverFailedMessageTo(bytes32 guid, address newRecipient) external onlyOwner nonReentrant {
        if (newRecipient == address(0)) revert Err.ZeroValue();

        FailedMessage memory failed = failedMessages[guid];
        if (failed.amount == 0) revert Err.InvalidState();

        delete failedMessages[guid];

        IERC7802(failed.token).crosschainMint(
            newRecipient,
            failed.amount,
            abi.encode(failed.srcEid, uint64(0), guid)
        );

        emit MessageRecovered(guid, newRecipient, failed.token, failed.amount);
    }

    /// @notice Refund a failed message back to the source chain
    /// @dev For cases where recovery on this chain isn't possible
    /// @param guid The LayerZero message GUID
    /// @param options LayerZero options for the refund message
    function refundFailedMessage(bytes32 guid, bytes calldata options) external payable onlyOwner nonReentrant {
        FailedMessage memory failed = failedMessages[guid];
        if (failed.amount == 0) revert Err.InvalidState();

        bytes32 peer = peers[failed.srcEid];
        if (peer == bytes32(0)) revert Err.NotConfigured(Err.Resource.BRIDGE_PEER, address(uint160(failed.srcEid)));

        delete failedMessages[guid];

        // Send refund message to source chain
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

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN - TOKEN CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Configure token (initial setup)
    function setTokenConfig(
        address token,
        uint256 limitRaw,
        uint8 decimals,
        uint8 inRatio,
        bool unlimited
    ) external onlyOwner {
        if (token == address(0)) revert Err.ZeroValue();

        IBridgeV1.TokenConfig memory cfg = tokenConfigs[token];
        if ((cfg.flags & FLAG_SUPPORTED) != 0) revert Err.AlreadyConfigured(Err.Resource.ASSET, token);

        tokenConfigs[token] = IBridgeV1.TokenConfig({
            limitOutB64: unlimited ? 0 : M.encodeB64(limitRaw, decimals),
            bridgedOutB64: 0,
            bridgedInB64: 0,
            day: uint16(block.timestamp / 1 days),
            inRatio: inRatio,
            flags: FLAG_SUPPORTED | (unlimited ? FLAG_UNLIMITED : 0)
        });

        emit TokenConfigured(token, tokenConfigs[token].limitOutB64, inRatio, tokenConfigs[token].flags);
    }

    /// @notice Request config change (timelocked)
    function requestConfigChange(
        address token,
        uint256 newLimitRaw,
        uint8 decimals,
        uint8 newRatio,
        bool updateLimit,
        bool updateRatio
    ) external onlyOwner {
        bytes32 id = keccak256(abi.encode(IBridgeV1.OpType.ConfigUpdate, token));
        if (pendingOps[id] != 0) revert Err.PendingTimelock(uint48(block.timestamp));

        pendingOps[id] = TL.pack(C.BASE_TIMELOCK, C.GRACE_PERIOD);
        pendingData[id] = abi.encode(
            updateLimit ? M.encodeB64(newLimitRaw, decimals) : uint64(0),
            newRatio,
            (updateLimit ? 0x01 : 0) | (updateRatio ? 0x02 : 0)
        );
    }

    /// @notice Execute config change
    function executeConfigChange(address token) external onlyOwner {
        bytes32 id = keccak256(abi.encode(IBridgeV1.OpType.ConfigUpdate, token));
        TL.validate(pendingOps[id]);

        (uint64 newLimit, uint8 newRatio, uint8 updateFlags) = abi.decode(pendingData[id], (uint64, uint8, uint8));

        IBridgeV1.TokenConfig storage cfg = tokenConfigs[token];
        if ((updateFlags & 0x01) != 0) cfg.limitOutB64 = newLimit;
        if ((updateFlags & 0x02) != 0) cfg.inRatio = newRatio;

        delete pendingOps[id];
        delete pendingData[id];
        emit TokenConfigured(token, cfg.limitOutB64, cfg.inRatio, cfg.flags);
    }

    /// @notice Emergency pause (instant)
    function pauseToken(address token, bool paused) external onlyOwner {
        TokenConfig storage cfg = tokenConfigs[token];
        if (paused) cfg.flags |= FLAG_PAUSED;
        else cfg.flags &= ~FLAG_PAUSED;
        emit TokenPaused(token, paused);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN - PEER CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Request peer set (timelocked)
    function requestSetPeer(uint32 eid, bytes32 peer) external onlyOwner {
        bytes32 id = keccak256(abi.encode(IBridgeV1.OpType.PeerUpdate, eid));
        if (pendingOps[id] != 0) revert Err.PendingTimelock(uint48(block.timestamp));

        pendingOps[id] = TL.pack(C.BASE_TIMELOCK, C.GRACE_PERIOD);
        pendingData[id] = abi.encodePacked(peer);
    }

    /// @notice Execute peer set
    function executeSetPeer(uint32 eid) external onlyOwner {
        bytes32 id = keccak256(abi.encode(IBridgeV1.OpType.PeerUpdate, eid));
        TL.validate(pendingOps[id]);

        bytes32 peer = abi.decode(pendingData[id], (bytes32));
        peers[eid] = peer;

        delete pendingOps[id];
        delete pendingData[id];
        emit PeerSet(eid, peer);
    }

    /// @notice Cancel pending operation
    function cancelOperation(bytes32 id) external onlyOwner {
        if (pendingOps[id] == 0) revert Err.InvalidState();
        delete pendingOps[id];
        delete pendingData[id];
    }

    /// @notice Emergency rescue tokens
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        LibRescue.rescueToken(token, to, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UPGRADES (UUPS with timelock)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Request contract upgrade (timelocked)
    function requestUpgrade(address newImplementation) external onlyOwner {
        if (newImplementation == address(0)) revert Err.ZeroValue();
        if (pendingUpgrade != bytes32(0)) revert Err.PendingTimelock(uint48(block.timestamp));

        pendingUpgrade = keccak256(abi.encode(newImplementation, block.timestamp));
        pendingImplementation = newImplementation;

        uint96 timelock = TL.pack(C.UPGRADE_TIMELOCK, C.GRACE_PERIOD);
        pendingOps[pendingUpgrade] = timelock;

        emit UpgradeAuthorized(pendingUpgrade, newImplementation, uint48(timelock >> 48));
    }

    /// @notice Execute contract upgrade after timelock
    function executeUpgrade() external onlyOwner {
        if (pendingUpgrade == bytes32(0)) revert Err.InvalidState();
        TL.validate(pendingOps[pendingUpgrade]);

        address newImpl = pendingImplementation;
        bytes32 upgradeId = pendingUpgrade;

        delete pendingUpgrade;
        delete pendingImplementation;
        delete pendingOps[upgradeId];

        this.upgradeToAndCall(newImpl, "");
    }

    /// @notice Cancel pending upgrade request
    function cancelUpgrade() external onlyOwner {
        if (pendingUpgrade == bytes32(0)) revert Err.InvalidState();

        bytes32 upgradeId = pendingUpgrade;
        delete pendingUpgrade;
        delete pendingImplementation;
        delete pendingOps[upgradeId];

        emit UpgradeCancelled(upgradeId);
    }

    /// @notice UUPS upgrade authorization (required by UUPSUpgradeable)
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEWS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Check if token is bridgeable
    function isBridgeable(address token) external view returns (bool) {
        uint8 flags = tokenConfigs[token].flags;
        return (flags & FLAG_SUPPORTED) != 0 && (flags & FLAG_PAUSED) == 0;
    }

    /// @notice Get remaining capacity
    function getRemainingLimits(address token) external view returns (uint256 outbound, uint256 inbound) {
        IBridgeV1.TokenConfig memory cfg = tokenConfigs[token];

        if ((cfg.flags & FLAG_UNLIMITED) != 0) {
            return (type(uint256).max, type(uint256).max);
        }

        uint16 today = uint16(block.timestamp / 1 days);
        uint8 decimals = M.b64Decimals(cfg.limitOutB64);

        // Use B64 for volume tracking (reset to 0 if different day)
        uint64 outUsedB64 = (cfg.day == today) ? cfg.bridgedOutB64 : 0;
        uint64 inUsedB64 = (cfg.day == today) ? cfg.bridgedInB64 : 0;

        // Decode for return values
        uint256 limitDecoded = M.decodeB64(cfg.limitOutB64, decimals);
        uint256 outUsed = outUsedB64 == 0 ? 0 : M.decodeB64(outUsedB64, decimals);
        uint256 inUsed = inUsedB64 == 0 ? 0 : M.decodeB64(inUsedB64, decimals);

        outbound = limitDecoded > outUsed ? limitDecoded - outUsed : 0;

        uint256 inLimit = (limitDecoded * cfg.inRatio) / RATIO_DENOM;
        inbound = inLimit > inUsed ? inLimit - inUsed : 0;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Unified limit check and update (optimized with B64 arithmetic)
    function _checkAndUpdateLimit(address token, uint256 amount, Direction dir) internal {
        IBridgeV1.TokenConfig storage cfg = tokenConfigs[token];

        if ((cfg.flags & FLAG_SUPPORTED) == 0) revert Err.NotConfigured(Err.Resource.ASSET, token);
        if ((cfg.flags & FLAG_PAUSED) != 0) revert Err.FeatureDisabled(Err.Resource.BRIDGE);
        if ((cfg.flags & FLAG_UNLIMITED) != 0) return;

        // Reset if new day
        uint16 today = uint16(block.timestamp / 1 days);
        if (cfg.day != today) {
            cfg.day = today;
            cfg.bridgedOutB64 = 0;
            cfg.bridgedInB64 = 0;
        }

        // Encode amount to B64 for direct comparison and arithmetic
        uint8 decimals = M.b64Decimals(cfg.limitOutB64);
        uint64 amountB64 = M.encodeB64(amount, decimals);

        if (dir == IBridgeV1.Direction.Outbound) {
            // Use B64 addition and comparison
            uint64 newTotal = M.add64(cfg.bridgedOutB64, amountB64);

            // Check if exceeded limit using B64 comparison
            if (M.gt64(newTotal, cfg.limitOutB64)) {
                // Decode for error message only
                uint256 limitDec = M.decodeB64(cfg.limitOutB64, decimals);
                uint256 usedDec = M.decodeB64(cfg.bridgedOutB64, decimals);
                revert Err.ExcessiveAmount(amount, limitDec - usedDec);
            }

            cfg.bridgedOutB64 = newTotal;
        } else {
            // Inbound: need to decode limit for ratio calculation
            uint256 limitDecoded = M.decodeB64(cfg.limitOutB64, decimals);
            uint256 inboundLimit = (limitDecoded * cfg.inRatio) / RATIO_DENOM;
            uint64 inboundLimitB64 = M.encodeB64(inboundLimit, decimals);

            // Use B64 addition and comparison
            uint64 newTotal = M.add64(cfg.bridgedInB64, amountB64);

            if (M.gt64(newTotal, inboundLimitB64)) {
                uint256 usedDec = M.decodeB64(cfg.bridgedInB64, decimals);
                revert Err.ExcessiveAmount(amount, inboundLimit - usedDec);
            }

            cfg.bridgedInB64 = newTotal;
        }
    }

    /// @notice Quote LayerZero fee
    function _quoteFee(LZEndpointV2.SendParam memory sendParam)
        internal view returns (LZEndpointV2.MessagingFee memory)
    {
        try LZEndpointV2(LZ_ENDPOINT).quote(sendParam, false) returns (
            LZEndpointV2.MessagingFee memory fee
        ) {
            if (fee.nativeFee == 0 && fee.lzTokenFee == 0) revert Err.OperationFailed();
            return fee;
        } catch {
            revert Err.OperationFailed();
        }
    }

    receive() external payable {}
}