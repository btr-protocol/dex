// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC721} from "../interfaces/external/IERC721.sol";
import {IERC1155} from "../interfaces/external/IERC1155.sol";
import {Err} from "../Errors.sol";
import {LibConstants as C} from "./LibConstants.sol";

/// @title LibRescue — recover stuck ERC20/721/1155/Native tokens.
/// @dev Native uses C.NATIVE (0xEeee...EEeE), never address(0).
library LibRescue {
    using SafeTransferLib for address;

    error InvalidToken();

    function _validToken(address token) private view {
        if (token == address(0)) revert InvalidToken();
        if (token.code.length == 0) revert InvalidToken();
    }

    /// @notice Rescue ERC20 or native ETH (token == C.NATIVE).
    function rescueToken(address token, address to, uint256 amount) internal {
        if (to == address(0) || amount == 0) revert Err.ZeroValue();
        if (token == C.NATIVE) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            _validToken(token);
            token.safeTransfer(to, amount);
        }
    }

    /// @notice Get ERC20 / native balance held by this contract.
    function getBalance(address token) internal view returns (uint256) {
        if (token == C.NATIVE) return address(this).balance;
        _validToken(token);
        return SafeTransferLib.balanceOf(token, address(this));
    }

    /// @notice Best-effort batch ERC721 rescue. Skips ids not owned.
    function rescueERC721Batch(address token, address to, uint256[] memory tokenIds) internal {
        if (to == address(0) || tokenIds.length == 0) revert Err.ZeroValue();
        _validToken(token);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            try IERC721(token).ownerOf(tokenIds[i]) returns (address owner) {
                if (owner == address(this)) {
                    IERC721(token).safeTransferFrom(address(this), to, tokenIds[i]);
                }
            } catch { continue; }
        }
    }

    /// @notice Best-effort batch ERC1155 rescue. Sends entire balance per id.
    function rescueERC1155Batch(address token, address to, uint256[] memory tokenIds) internal {
        if (to == address(0) || tokenIds.length == 0) revert Err.ZeroValue();
        _validToken(token);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 bal = IERC1155(token).balanceOf(address(this), tokenIds[i]);
            if (bal > 0) IERC1155(token).safeTransferFrom(address(this), to, tokenIds[i], bal, "");
        }
    }
}
