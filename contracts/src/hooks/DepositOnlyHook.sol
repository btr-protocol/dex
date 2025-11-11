// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseBAMMHook} from "./BaseBAMMHook.sol";

/// @title DepositOnlyHook
/// @notice Example hook that ONLY implements deposit hooks (demonstrates bitmap usage)
/// @dev Uses hookFlags() bitmap to indicate only deposit hooks are active (gas optimization)
contract DepositOnlyHook is BaseBAMMHook {
    address public owner;

    // Only deposit hooks are implemented
    uint8 private constant FLAGS = (1 << 0) | (1 << 1); // 0x03 = preDeposit + postDeposit

    mapping(address => uint256) public depositCount;

    error OnlyOwner();

    constructor(address _bamm, address _owner) BaseBAMMHook(_bamm) {
        owner = _owner;
    }

    /// @dev Returns bitmap with only deposit hooks enabled (bits 0 and 1) - gas optimization
    function hookFlags() external pure returns (uint8) {
        return FLAGS; // 0x03 = 00000011 (only preDeposit and postDeposit)
    }

    // ========== IMPLEMENTED HOOKS (DEPOSIT ONLY) ==========

    /// @dev Track deposit count
    function preDeposit(
        address,
        address depositor,
        uint256,
        bytes calldata
    ) public override onlyBAMM returns (bytes4) {
        depositCount[depositor]++;
        return this.HOOK_SUCCESS.selector;
    }

    /// @dev Example: Emit event, update metrics, etc.
    function postDeposit(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) public override onlyBAMM returns (bytes4) {
        return this.HOOK_SUCCESS.selector;
    }

    // All other hooks inherit no-op implementations from BaseBAMMHook
    // They will NEVER be called due to hookFlags() = 0x03 (gas optimization)
}
