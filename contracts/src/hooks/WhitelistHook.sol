// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseBAMMHook} from "./BaseBAMMHook.sol";

/// @title WhitelistHook
/// @notice Example hook that enforces whitelist access control on deposits
/// @dev Simple whitelist implementation - can be extended with role-based access
contract WhitelistHook is BaseBAMMHook {
    address public owner;
    mapping(address => bool) public whitelist;

    event AddressWhitelisted(address indexed account);
    event AddressRemovedFromWhitelist(address indexed account);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error OnlyOwner();
    error NotWhitelisted(address account);
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor(address _bamm, address _owner) BaseBAMMHook(_bamm) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
    }

    // ========== ADMIN FUNCTIONS ==========

    /// @notice Add address to whitelist
    function addToWhitelist(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        whitelist[account] = true;
        emit AddressWhitelisted(account);
    }

    /// @notice Remove address from whitelist
    function removeFromWhitelist(address account) external onlyOwner {
        whitelist[account] = false;
        emit AddressRemovedFromWhitelist(account);
    }

    /// @notice Batch add addresses to whitelist
    function addBatchToWhitelist(address[] calldata accounts) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == address(0)) revert ZeroAddress();
            whitelist[accounts[i]] = true;
            emit AddressWhitelisted(accounts[i]);
        }
    }

    /// @notice Transfer ownership
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    // ========== LIQUIDITY HOOKS ==========

    /// @dev Override to enforce whitelist on deposits
    function preDeposit(
        address,
        address depositor,
        uint256,
        bytes calldata
    ) public view override onlyBAMM returns (bytes4) {
        if (!whitelist[depositor]) {
            revert NotWhitelisted(depositor);
        }
        return this.HOOK_SUCCESS.selector;
    }

    // All other hooks inherit no-op implementations from BaseBAMMHook
}
