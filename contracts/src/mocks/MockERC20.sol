// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ERC20} from "solady/tokens/ERC20.sol";

/**
 * @title MockERC20
 * @notice Mintable ERC20 for testing - only faucet can mint
 */
contract MockERC20 is ERC20 {
    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;
    address immutable public faucet;

    error Unauthorized();

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address faucet_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
        faucet = faucet_;
    }

    function name() public view override returns (string memory) { return _name; }
    function symbol() public view override returns (string memory) { return _symbol; }
    function decimals() public view override returns (uint8) { return _decimals; }

    function mint(address to, uint256 amount) external {
        if (msg.sender != faucet) revert Unauthorized();
        _mint(to, amount);
    }
}
