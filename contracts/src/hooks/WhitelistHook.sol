// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseBAMMHook} from "./BaseBAMMHook.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title WhitelistHook
/// @notice Example hook that enforces whitelist access control on deposits
/// @dev Simple whitelist implementation - can be extended with role-based access
contract WhitelistHook is BaseBAMMHook, Ownable {
    mapping(address => bool) public whitelist;

    event AddressWhitelisted(address indexed account);
    event AddressRemovedFromWhitelist(address indexed account);

    error NotWhitelisted(address account);
    error ZeroAddress();

    constructor(address _bamm, address _owner) BaseBAMMHook(_bamm) {
        if (_owner == address(0)) revert ZeroAddress();
        _initializeOwner(_owner);
    }

    // ========== OWNER FUNCTIONS ==========

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
    function batchAddToWhitelist(address[] calldata accounts) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == address(0)) revert ZeroAddress();
            whitelist[accounts[i]] = true;
            emit AddressWhitelisted(accounts[i]);
        }
    }

    // Ownership transfer uses Solady's Ownable two-step mechanism
    // See: https://github.com/Vectorized/solady/blob/main/src/auth/Ownable.sol

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
        return this.preDeposit.selector;
    }

    // All other hooks inherit no-op implementations from BaseBAMMHook
}
