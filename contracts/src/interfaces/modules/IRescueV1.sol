// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPoolV1} from "../IPoolV1.sol";

interface IRescueV1 {
    // ========== TYPES ==========

    enum TokenType { NATIVE, ERC20, ERC721, ERC1155 }

    struct RescueRequest {
        address token;
        uint256[] tokenIds;  // For NFTs
        uint256 amount;      // Snapshotted balance for ERC20/NATIVE
        address receiver;
    }

    // ========== REQUEST RESCUE ==========

    /// @notice Request any token rescue (unified)
    function requestRescue(
        TokenType tokenType,
        address token,
        uint256[] calldata tokenIds,
        address receiver
    ) external;

    // ========== EXECUTE RESCUE ==========

    /// @notice Execute rescue after timelock
    function executeRescue(address receiver, TokenType tokenType) external;

    // ========== EVENTS ==========

    event RescueRequested(address indexed receiver, TokenType indexed tokenType, address indexed token);
    event RescueExecuted(address indexed receiver, TokenType indexed tokenType, address indexed token, uint256 amount);
}
