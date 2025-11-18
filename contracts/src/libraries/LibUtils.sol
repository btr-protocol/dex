// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {BAMMErrors as E} from "../bamm/BAMMErrors.sol";
import {LibStorage as S} from "./LibStorage.sol";

/// @title LibUtils
/// @notice Utility library for validation helpers
/// @dev Casting functions removed - use solady's SafeCastLib instead
library LibUtils {

    /// @notice Convert address to token ID (for ERC1155)
    function addressToTokenId(address token) internal pure returns (uint256 id) {
        assembly { id := token }
    }

    /// @notice Convert address to hex string (without 0x prefix)
    function toHexString(address addr) internal pure returns (string memory) {
        bytes memory buffer = new bytes(40);
        unchecked {
            for (uint256 i; i < 20; ++i) {
                uint8 b = uint8(uint160(addr) >> (8 * (19 - i)));
                buffer[i * 2] = bytes1(b >> 4 < 10 ? b >> 4 + 0x30 : b >> 4 + 0x57);
                buffer[i * 2 + 1] = bytes1((b & 0x0f) < 10 ? (b & 0x0f) + 0x30 : (b & 0x0f) + 0x57);
            }
        }
        return string(buffer);
    }

    // ========== VALIDATION ==========

    /// @notice Require asset exists (reserves > 0)
    function requireExists(IBAMM.Asset storage asset) internal view {
        if (asset.reserves == 0) revert E.AssetNotFound();
    }

    /// @notice Require asset is registered (has segment configuration)
    function requireRegistered(IBAMM.Asset storage asset) internal view {
        if (asset.segmentCount == 0) revert E.AssetNotFound();
    }

    /// @notice Require asset is not frozen
    function requireNotFrozen(IBAMM.RiskConfig storage risk) internal view {
        if (S._isFrozen(risk)) revert E.AssetFrozen();
    }

    /// @notice Require asset exists and is not frozen
    function requireActive(IBAMM.Asset storage asset, IBAMM.RiskConfig storage risk) internal view {
        requireExists(asset);
        requireNotFrozen(risk);
    }

    /// @notice Require address is not zero
    function requireNonZero(address addr) internal pure {
        if (addr == address(0)) revert E.ZeroAddress();
    }

    /// @notice Require amount is not zero
    function requireNonZero(uint256 amount) internal pure {
        if (amount == 0) revert E.ZeroAmount();
    }

    /// @notice Require reserves meet minimum liquidity
    function requireMinLiquidity(IBAMM.Asset storage asset, IBAMM.RiskConfig storage risk) internal view {
        if (asset.reserves < risk.minLiquidity) revert E.BelowMinimumLiquidity();
    }
}
