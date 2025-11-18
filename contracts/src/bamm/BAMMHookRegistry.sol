// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IBAMMHooks} from "../interfaces/IBAMMHooks.sol";
import {IERC165} from "../interfaces/IERC165.sol";
import {BAMMErrors as E} from "./BAMMErrors.sol";
import {LibStorage} from "../libraries/LibStorage.sol";

/// @title BAMMHookRegistry
/// @notice Hook registry functions for BAMM
/// @dev Uses ERC-165 interface detection for reliable hook validation
///      Replaces unreliable staticcall probing with standard supportsInterface()
abstract contract BAMMHookRegistry {
    /// @notice Get asset storage for given token (must be implemented by child)
    function _getAsset(address token) internal view virtual returns (IBAMM.Asset storage);

    /// @notice Get storage (must be implemented by child)
    function _sh() internal pure virtual returns (IBAMM.BAMMStorage storage);

    /// @notice Modifier for owner-only functions (must be implemented by child)
    modifier onlyOwner() virtual;

    // ========== EVENTS ==========

    event HooksUpdated(address indexed token, address indexed hookAddress);

    // ========== HOOK REGISTRY ==========

    /// @notice Update hook contract for an asset
    /// @dev Uses ERC-165 supportsInterface for reliable interface detection
    ///      Works correctly with proxies and upgradeable contracts
    /// @param token Token address
    /// @param hookAddress New hook contract address (address(0) = disabled)
    function updateHooks(
        address token,
        address hookAddress
    ) external onlyOwner {
        IBAMM.BAMMStorage storage $ = _sh();
        IBAMM.Asset storage asset = _getAsset(token);
        if (asset.segmentCount == 0) revert E.AssetNotFound();

        // Early return if hook address unchanged (saves gas on no-op)
        if ($.hooks[token] == hookAddress) return;

        // If enabling hooks, validate using ERC-165
        if (hookAddress != address(0)) {
            _validateHookContract(hookAddress);
        }

        $.hooks[token] = hookAddress;

        emit HooksUpdated(token, hookAddress);
    }

    /// @notice Get hook contract for an asset
    /// @param token Token address
    /// @return hookAddress Current hook contract address
    function getHooks(address token) external view returns (address hookAddress) {
        IBAMM.Asset storage asset = _getAsset(token);
        if (asset.segmentCount == 0) revert E.AssetNotFound();

        IBAMM.BAMMStorage storage $ = _sh();
        return $.hooks[token];
    }

    /// @notice Validate hook contract at registration time (comprehensive check)
    /// @dev Validates ALL 10 hook functions return correct selectors
    ///      This eliminates need for runtime validation (huge gas savings)
    /// @param hookAddress Hook contract to validate
    function _validateHookContract(address hookAddress) private {
        // Basic sanity: ensure contract has code (reject EOAs)
        if (hookAddress.code.length == 0) {
            revert E.InvalidHookContract(hookAddress, "no code");
        }

        // ERC-165 interface detection: check if hook supports IBAMMHooks
        try IERC165(hookAddress).supportsInterface(type(IBAMMHooks).interfaceId) returns (bool supported) {
            if (!supported) {
                revert E.InvalidHookContract(hookAddress, "ERC165: IBAMMHooks not supported");
            }
        } catch {
            revert E.InvalidHookContract(hookAddress, "ERC165: supportsInterface failed");
        }

        // Validate ALL 10 hooks return correct selectors (zero-value dummy calls)
        // This ensures hooks are fully compliant before registration
        address dummyToken = address(1);
        address dummyUser = address(2);

        // Liquidity hooks (4)
        try IBAMMHooks(hookAddress).preDeposit(dummyToken, dummyUser, 0, "") returns (bytes4 selector) {
            if (selector != IBAMMHooks.preDeposit.selector) {
                revert E.InvalidHookContract(hookAddress, "preDeposit: invalid selector");
            }
        } catch {
            revert E.InvalidHookContract(hookAddress, "preDeposit: call failed");
        }

        try IBAMMHooks(hookAddress).postDeposit(dummyToken, dummyUser, 0, 0, "") returns (bytes4 selector) {
            if (selector != IBAMMHooks.postDeposit.selector) {
                revert E.InvalidHookContract(hookAddress, "postDeposit: invalid selector");
            }
        } catch {
            revert E.InvalidHookContract(hookAddress, "postDeposit: call failed");
        }

        try IBAMMHooks(hookAddress).preWithdraw(dummyToken, dummyUser, 0, "") returns (bytes4 selector) {
            if (selector != IBAMMHooks.preWithdraw.selector) {
                revert E.InvalidHookContract(hookAddress, "preWithdraw: invalid selector");
            }
        } catch {
            revert E.InvalidHookContract(hookAddress, "preWithdraw: call failed");
        }

        try IBAMMHooks(hookAddress).postWithdraw(dummyToken, dummyUser, 0, 0, "") returns (bytes4 selector) {
            if (selector != IBAMMHooks.postWithdraw.selector) {
                revert E.InvalidHookContract(hookAddress, "postWithdraw: invalid selector");
            }
        } catch {
            revert E.InvalidHookContract(hookAddress, "postWithdraw: call failed");
        }

        // Swap hooks (4)
        try IBAMMHooks(hookAddress).preBuy(dummyToken, dummyUser, 0, dummyToken, 0, "") returns (bytes4 selector) {
            if (selector != IBAMMHooks.preBuy.selector) {
                revert E.InvalidHookContract(hookAddress, "preBuy: invalid selector");
            }
        } catch {
            revert E.InvalidHookContract(hookAddress, "preBuy: call failed");
        }

        try IBAMMHooks(hookAddress).postBuy(dummyToken, dummyUser, 0, dummyToken, 0, "") returns (bytes4 selector) {
            if (selector != IBAMMHooks.postBuy.selector) {
                revert E.InvalidHookContract(hookAddress, "postBuy: invalid selector");
            }
        } catch {
            revert E.InvalidHookContract(hookAddress, "postBuy: call failed");
        }

        try IBAMMHooks(hookAddress).preSell(dummyToken, dummyUser, 0, dummyToken, 0, "") returns (bytes4 selector) {
            if (selector != IBAMMHooks.preSell.selector) {
                revert E.InvalidHookContract(hookAddress, "preSell: invalid selector");
            }
        } catch {
            revert E.InvalidHookContract(hookAddress, "preSell: call failed");
        }

        try IBAMMHooks(hookAddress).postSell(dummyToken, dummyUser, 0, dummyToken, 0, "") returns (bytes4 selector) {
            if (selector != IBAMMHooks.postSell.selector) {
                revert E.InvalidHookContract(hookAddress, "postSell: invalid selector");
            }
        } catch {
            revert E.InvalidHookContract(hookAddress, "postSell: call failed");
        }

        // Flash loan hooks (2)
        try IBAMMHooks(hookAddress).preFlashLoan(dummyToken, dummyUser, 0, 0, "") returns (bytes4 selector) {
            if (selector != IBAMMHooks.preFlashLoan.selector) {
                revert E.InvalidHookContract(hookAddress, "preFlashLoan: invalid selector");
            }
        } catch {
            revert E.InvalidHookContract(hookAddress, "preFlashLoan: call failed");
        }

        try IBAMMHooks(hookAddress).postFlashLoan(dummyToken, dummyUser, 0, 0, "") returns (bytes4 selector) {
            if (selector != IBAMMHooks.postFlashLoan.selector) {
                revert E.InvalidHookContract(hookAddress, "postFlashLoan: invalid selector");
            }
        } catch {
            revert E.InvalidHookContract(hookAddress, "postFlashLoan: call failed");
        }

        // All 10 hooks validated! Hook is fully compliant.
    }
}
