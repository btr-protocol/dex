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

    // ========== DEFAULT NO-OP IMPLEMENTATIONS ==========
    // Override these in your derived contract as needed
    // Note: public (not external) so derived contracts can inherit interface compliance
    // Each hook MUST return its own function selector for validation

    function preDeposit(
        address,
        address,
        uint256,
        bytes calldata
    ) public virtual onlyBAMM returns (bytes4) {
        return this.preDeposit.selector;
    }

    function postDeposit(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) public virtual onlyBAMM returns (bytes4) {
        return this.postDeposit.selector;
    }

    function preWithdraw(
        address,
        address,
        uint256,
        bytes calldata
    ) public virtual onlyBAMM returns (bytes4) {
        return this.preWithdraw.selector;
    }

    function postWithdraw(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) public virtual onlyBAMM returns (bytes4) {
        return this.postWithdraw.selector;
    }

    function preBuy(
        address,
        address,
        uint256,
        address,
        uint256,
        bytes calldata
    ) public virtual onlyBAMM returns (bytes4) {
        return this.preBuy.selector;
    }

    function postBuy(
        address,
        address,
        uint256,
        address,
        uint256,
        bytes calldata
    ) public virtual onlyBAMM returns (bytes4) {
        return this.postBuy.selector;
    }

    function preSell(
        address,
        address,
        uint256,
        address,
        uint256,
        bytes calldata
    ) public virtual onlyBAMM returns (bytes4) {
        return this.preSell.selector;
    }

    function postSell(
        address,
        address,
        uint256,
        address,
        uint256,
        bytes calldata
    ) public virtual onlyBAMM returns (bytes4) {
        return this.postSell.selector;
    }

    function preFlashLoan(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) public virtual onlyBAMM returns (bytes4) {
        return this.preFlashLoan.selector;
    }

    function postFlashLoan(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) public virtual onlyBAMM returns (bytes4) {
        return this.postFlashLoan.selector;
    }
}
