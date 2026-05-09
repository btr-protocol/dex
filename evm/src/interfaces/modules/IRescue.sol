// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface IRescue {
    enum TokenType { NATIVE, ERC20, ERC721, ERC1155 }

    struct RescueRequest {
        address token;
        uint256[] tokenIds;
        uint256 amount;
        address receiver;
    }

    function requestRescue(
        TokenType tokenType,
        address token,
        uint256[] calldata tokenIds,
        address receiver
    ) external;

    function executeRescue(address receiver, TokenType tokenType) external;

    event RescueRequested(address indexed receiver, TokenType indexed tokenType, address indexed token);
    event RescueExecuted(address indexed receiver, TokenType indexed tokenType, address indexed token, uint256 amount);
}
