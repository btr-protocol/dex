// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ERC20} from "solady/tokens/ERC20.sol";

/**
 * @title MockERC20
 * @notice Simple mintable ERC20 for testing
 * @dev Prefixed with "Mock" to distinguish from real tokens in explorers
 */
contract MockERC20 is ERC20 {
    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() public view virtual override returns (string memory) {
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Mint tokens to any address (faucet-style)
     * @dev Public function - anyone can mint (perfect for testing)
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Convenience function to mint to msg.sender
     */
    function faucet(uint256 amount) external {
        _mint(msg.sender, amount);
    }
}
