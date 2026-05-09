// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC721} from "../interfaces/external/IERC721.sol";
import {IERC1155} from "../interfaces/external/IERC1155.sol";
import {Err} from "../Errors.sol";
import {LibConstants as C} from "./LibConstants.sol";

/// @title LibRescue
/// @notice Generic rescue logic for recovering stuck tokens (ERC20/721/1155/Native)
/// @dev Shared by Bridge.sol and Rescue.sol module
/// @dev ALWAYS uses C.NATIVE (0xEeee...EEeE) for native ETH, NEVER address(0)
library LibRescue {
    using SafeTransferLib for address;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════
    // ZeroValue() inherited from IErrors

    error InvalidToken();

    // ═══════════════════════════════════════════════════════════════════════════
    // ERC20 / NATIVE RESCUE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Rescue ERC20 tokens or native ETH
    /// @param token Token address (C.NATIVE for native ETH)
    /// @param to Recipient address
    /// @param amount Amount to rescue
    function rescueToken(address token, address to, uint256 amount) internal {
        if (to == address(0)) revert Err.ZeroValue();
        if (amount == 0) revert Err.ZeroValue();

        if (token == C.NATIVE) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            // Validate token address
            if (token == address(0)) revert InvalidToken();
            if (token.code.length == 0) revert InvalidToken();
            token.safeTransfer(to, amount);
        }
    }

    /// @notice Get balance of token or native ETH
    /// @param token Token address (C.NATIVE for native ETH)
    /// @return balance Current balance of this contract
    function getBalance(address token) internal view returns (uint256) {
        if (token == C.NATIVE) {
            return address(this).balance;
        }
        // Validate token address for ERC20
        if (token == address(0)) revert InvalidToken();
        if (token.code.length == 0) revert InvalidToken();
        return SafeTransferLib.balanceOf(token, address(this));
    }

    /// @notice Rescue entire balance of a token
    /// @param token Token address (C.NATIVE for native ETH)
    /// @param to Recipient address
    /// @return rescued Amount rescued
    function rescueAll(address token, address to) internal returns (uint256 rescued) {
        if (to == address(0)) revert Err.ZeroValue();

        rescued = getBalance(token);
        if (rescued == 0) revert Err.ZeroValue();

        if (token == C.NATIVE) {
            SafeTransferLib.safeTransferETH(to, rescued);
        } else {
            // Validate token address (already checked in getBalance, but explicit for clarity)
            if (token == address(0)) revert InvalidToken();
            if (token.code.length == 0) revert InvalidToken();
            token.safeTransfer(to, rescued);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERC721 RESCUE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Rescue ERC721 NFT
    /// @param token NFT contract address
    /// @param to Recipient address
    /// @param tokenId Token ID to rescue
    function rescueERC721(address token, address to, uint256 tokenId) internal {
        if (to == address(0)) revert Err.ZeroValue();
        if (token == address(0)) revert InvalidToken();
        if (token.code.length == 0) revert InvalidToken();
        IERC721(token).safeTransferFrom(address(this), to, tokenId);
    }

    /// @notice Rescue multiple ERC721 NFTs
    /// @param token NFT contract address
    /// @param to Recipient address
    /// @param tokenIds Array of token IDs to rescue
    function rescueERC721Batch(address token, address to, uint256[] memory tokenIds) internal {
        if (to == address(0)) revert Err.ZeroValue();
        if (tokenIds.length == 0) revert Err.ZeroValue();
        if (token == address(0)) revert InvalidToken();
        if (token.code.length == 0) revert InvalidToken();

        // Best-effort: skip tokens we don't own instead of reverting entire batch
        for (uint256 i = 0; i < tokenIds.length; i++) {
            try IERC721(token).ownerOf(tokenIds[i]) returns (address owner) {
                if (owner == address(this)) {
                    IERC721(token).safeTransferFrom(address(this), to, tokenIds[i]);
                }
            } catch {
                // Skip this token if ownerOf fails
                continue;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERC1155 RESCUE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Rescue ERC1155 tokens (single ID)
    /// @param token ERC1155 contract address
    /// @param to Recipient address
    /// @param tokenId Token ID to rescue
    /// @param amount Amount to rescue (0 = rescue all balance)
    function rescueERC1155(address token, address to, uint256 tokenId, uint256 amount) internal {
        if (to == address(0)) revert Err.ZeroValue();
        if (token == address(0)) revert InvalidToken();
        if (token.code.length == 0) revert InvalidToken();

        uint256 balance = IERC1155(token).balanceOf(address(this), tokenId);
        uint256 toRescue = (amount == 0 || amount > balance) ? balance : amount;

        if (toRescue == 0) revert Err.ZeroValue();

        IERC1155(token).safeTransferFrom(address(this), to, tokenId, toRescue, "");
    }

    /// @notice Rescue ERC1155 tokens (multiple IDs)
    /// @param token ERC1155 contract address
    /// @param to Recipient address
    /// @param tokenIds Array of token IDs to rescue
    function rescueERC1155Batch(address token, address to, uint256[] memory tokenIds) internal {
        if (to == address(0)) revert Err.ZeroValue();
        if (tokenIds.length == 0) revert Err.ZeroValue();
        if (token == address(0)) revert InvalidToken();
        if (token.code.length == 0) revert InvalidToken();

        // Best-effort: only rescue tokens with balance > 0
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 balance = IERC1155(token).balanceOf(address(this), tokenIds[i]);
            if (balance > 0) {
                IERC1155(token).safeTransferFrom(address(this), to, tokenIds[i], balance, "");
            }
        }
    }
}
