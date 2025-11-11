// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IBAMMHooks} from "../interfaces/IBAMMHooks.sol";
import {IERC165} from "../interfaces/IERC165.sol";
import {BAMMErrors as E} from "./BAMMEvents.sol";
import {BAMMEvents as Events} from "./BAMMEvents.sol";

/// @title BAMMHookRegistry
/// @notice Hook registry functions for BAMM
/// @dev Uses ERC-165 interface detection for reliable hook validation
///      Replaces unreliable staticcall probing with standard supportsInterface()
abstract contract BAMMHookRegistry {
    /// @notice Get asset storage for given token (must be implemented by child)
    function _getAsset(address token) internal view virtual returns (IBAMM.Asset storage);

    /// @notice Modifier for admin-only functions (must be implemented by child)
    modifier onlyAdmin() virtual;

    // ========== HOOK REGISTRY ==========

    /// @notice Update hook contract for an asset
    /// @dev Uses ERC-165 supportsInterface for reliable interface detection
    ///      Works correctly with proxies and upgradeable contracts
    /// @param token Token address
    /// @param hookAddress New hook contract address (address(0) = disabled)
    function updateHooks(
        address token,
        address hookAddress
    ) external onlyAdmin {
        IBAMM.Asset storage asset = _getAsset(token);
        if (asset.segmentCount == 0) revert E.AssetNotFound();

        // Early return if hook address unchanged (saves gas on no-op)
        if (asset.hooks == hookAddress) return;

        // If enabling hooks, validate using ERC-165
        if (hookAddress != address(0)) {
            _validateHookContract(hookAddress);
        }

        asset.hooks = hookAddress;

        emit Events.HooksUpdated(token, hookAddress);
    }

    /// @notice Get hook contract for an asset
    /// @param token Token address
    /// @return hookAddress Current hook contract address
    function getHooks(address token) external view returns (address hookAddress) {
        IBAMM.Asset storage asset = _getAsset(token);
        if (asset.segmentCount == 0) revert E.AssetNotFound();

        return asset.hooks;
    }

    /// @notice Validate hook contract using ERC-165 interface detection
    /// @dev Replaces unreliable staticcall probing with standard supportsInterface()
    ///      - Works correctly with proxies and upgradeable contracts
    ///      - Avoids false negatives from non-view hooks or argument validation
    ///      - Single call instead of 8 separate staticcalls
    /// @param hookAddress Hook contract to validate
    function _validateHookContract(address hookAddress) private view {
        // Basic sanity: ensure contract has code (reject EOAs)
        // Note: This check is imperfect during construction but catches most errors
        if (hookAddress.code.length == 0) {
            revert E.InvalidHookContract(hookAddress, "no code");
        }

        // ERC-165 interface detection: check if hook supports IBAMMHooks
        // This is the standard, reliable way to detect interface implementation
        try IERC165(hookAddress).supportsInterface(type(IBAMMHooks).interfaceId) returns (bool supported) {
            if (!supported) {
                revert E.InvalidHookContract(hookAddress, "ERC165: IBAMMHooks not supported");
            }
        } catch {
            // Hook doesn't implement ERC-165 or reverted
            revert E.InvalidHookContract(hookAddress, "ERC165: supportsInterface failed");
        }
    }
}
