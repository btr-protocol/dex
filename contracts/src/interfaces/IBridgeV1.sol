// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IErrors} from "./IErrors.sol";
import {LZEndpointV2} from "./external/ILZEndpointV2.sol";

/// @title IBridgeV1
/// @notice LayerZero bridge with ERC7802 support and timelocked configuration
interface IBridgeV1 is IErrors {
    // ═══════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Single-slot token config (224 bits)
    struct TokenConfig {
        uint64 limitOutB64;     // B64-encoded daily outbound limit
        uint64 bridgedOutB64;   // B64-encoded outbound volume today
        uint64 bridgedInB64;    // B64-encoded inbound volume today
        uint16 day;             // Day index
        uint8  inRatio;         // Inbound ratio (% of outbound)
        uint8  flags;           // Flags
    }

    enum Direction { Outbound, Inbound }
    enum OpType { ConfigUpdate, PeerUpdate }

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event Bridged(
        address indexed user,
        address indexed token,
        uint32 indexed dstEid,
        bytes32 receiver,
        uint256 amount,
        uint64 nonce,
        Direction dir
    );
    event TokenConfigured(address indexed token, uint64 limit, uint8 inRatio, uint8 flags);
    event PeerSet(uint32 indexed eid, bytes32 peer);
    event TokenPaused(address indexed token, bool paused);
    event UpgradeAuthorized(bytes32 indexed upgradeId, address newImplementation, uint48 executableAt);
    event UpgradeCancelled(bytes32 indexed upgradeId);

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════
    // All errors inherited from IErrors - see IErrors.sol for details

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
    ) external payable;

    /// @notice Quote bridge fee
    function quoteLZBridge(
        address token,
        uint32 dstEid,
        uint256 amount,
        bytes calldata options
    ) external view returns (LZEndpointV2.MessagingFee memory);

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
    ) external;

    /// @notice Request config change (timelocked)
    function requestConfigChange(
        address token,
        uint256 newLimitRaw,
        uint8 decimals,
        uint8 newRatio,
        bool updateLimit,
        bool updateRatio
    ) external;

    /// @notice Execute config change
    function executeConfigChange(address token) external;

    /// @notice Emergency pause (instant)
    function pauseToken(address token, bool paused) external;

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN - PEER CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Request peer set (timelocked)
    function requestSetPeer(uint32 eid, bytes32 peer) external;

    /// @notice Execute peer set
    function executeSetPeer(uint32 eid) external;

    /// @notice Cancel pending operation
    function cancelOperation(bytes32 id) external;

    // ═══════════════════════════════════════════════════════════════════════════
    // UPGRADES (UUPS with timelock)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Request contract upgrade (timelocked)
    function requestUpgrade(address newImplementation) external;

    /// @notice Execute contract upgrade after timelock
    function executeUpgrade() external;

    /// @notice Cancel pending upgrade request
    function cancelUpgrade() external;

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEWS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Check if token is bridgeable
    function isBridgeable(address token) external view returns (bool);

    /// @notice Get remaining capacity
    function getRemainingLimits(address token) external view returns (uint256 outbound, uint256 inbound);
}
