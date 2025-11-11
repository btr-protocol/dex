// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMMHooks} from "../interfaces/IBAMMHooks.sol";
import {IERC165} from "../interfaces/IERC165.sol";
import {ERC165} from "../utils/ERC165.sol";

/// @title BaseBAMMHook
/// @notice Base contract for BAMM hooks with default no-op implementations
/// @dev Inherit from this and override only the hooks you need
///      Implements ERC-165 for proper interface detection
abstract contract BaseBAMMHook is IBAMMHooks, ERC165 {
    address public immutable bamm;

    error OnlyBAMM();

    modifier onlyBAMM() {
        if (msg.sender != bamm) revert OnlyBAMM();
        _;
    }

    constructor(address _bamm) {
        bamm = _bamm;
    }

    /// @notice ERC-165 interface detection
    /// @dev Returns true for IBAMMHooks and IERC165 interfaces
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IBAMMHooks).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @notice Returns the hook success selector constant
    function HOOK_SUCCESS() external pure returns (bytes4) {
        return this.HOOK_SUCCESS.selector;
    }

    // ========== DEFAULT NO-OP IMPLEMENTATIONS ==========
    // Override these in your derived contract as needed
    // Note: public (not external) so derived contracts can inherit interface compliance

    function preDeposit(
        address,
        address,
        uint256,
        bytes calldata
    ) public virtual onlyBAMM returns (bytes4) {
        return this.HOOK_SUCCESS.selector;
    }

    function postDeposit(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) public virtual onlyBAMM returns (bytes4) {
        return this.HOOK_SUCCESS.selector;
    }

    function preWithdraw(
        address,
        address,
        uint256,
        bytes calldata
    ) public virtual onlyBAMM returns (bytes4) {
        return this.HOOK_SUCCESS.selector;
    }

    function postWithdraw(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) public virtual onlyBAMM returns (bytes4) {
        return this.HOOK_SUCCESS.selector;
    }

    function preBuy(
        address,
        address,
        uint256,
        address,
        uint256,
        bytes calldata
    ) public virtual onlyBAMM returns (bytes4) {
        return this.HOOK_SUCCESS.selector;
    }

    function postBuy(
        address,
        address,
        uint256,
        address,
        uint256,
        bytes calldata
    ) public virtual onlyBAMM returns (bytes4) {
        return this.HOOK_SUCCESS.selector;
    }

    function preSell(
        address,
        address,
        uint256,
        address,
        uint256,
        bytes calldata
    ) public virtual onlyBAMM returns (bytes4) {
        return this.HOOK_SUCCESS.selector;
    }

    function postSell(
        address,
        address,
        uint256,
        address,
        uint256,
        bytes calldata
    ) public virtual onlyBAMM returns (bytes4) {
        return this.HOOK_SUCCESS.selector;
    }
}
