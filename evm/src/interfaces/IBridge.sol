// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {LZEndpointV2} from "./external/ILZEndpointV2.sol";

/// @title IBridge -LayerZero bridge w/ ERC7802 + timelocked config
interface IBridge {
    /// @dev Single-slot 224 bits
    struct TokenConfig {
        uint64 limitOutB64;
        uint64 bridgedOutB64;
        uint64 bridgedInB64;
        uint16 day;
        uint8  inRatio;
        uint8  flags;
    }

    enum Direction { Outbound, Inbound }
    enum OpType { ConfigUpdate, PeerUpdate }

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
    event Salvaged(address indexed token, address indexed to, uint256 amount);

    function bridgeViaLayerZero(
        address token,
        uint32 dstEid,
        bytes32 receiver,
        uint256 amount,
        bytes calldata options
    ) external payable;

    function quoteLZBridge(address token, uint32 dstEid, uint256 amount, bytes calldata options)
        external view returns (LZEndpointV2.MessagingFee memory);

    function setTokenConfig(address token, uint256 limitRaw, uint8 decimals, uint8 inRatio, bool unlimited) external;

    function requestConfigChange(
        address token,
        uint256 newLimitRaw,
        uint8 decimals,
        uint8 newRatio,
        bool updateLimit,
        bool updateRatio
    ) external;
    function executeConfigChange(address token) external;
    function pauseToken(address token, bool paused) external;

    function requestSetPeer(uint32 eid, bytes32 peer) external;
    function executeSetPeer(uint32 eid) external;
    function cancelConfigChange(address token) external;
    function cancelSetPeer(uint32 eid) external;

    function requestUpgrade(address newImplementation) external;
    function executeUpgrade() external;
    function cancelUpgrade() external;

    function isBridgeable(address token) external view returns (bool);
    function getRemainingLimits(address token) external view returns (uint256 outbound, uint256 inbound);
}
