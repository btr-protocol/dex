// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice Mintable BEP20 for chapel mock assets (symbols mirror mainnet pegs).
/// @dev Only `minter` (deployer) can mint — open mint would bypass the faucet caps.
contract TestnetERC20 is ERC20 {
    string private _name;
    string private _symbol;
    uint8 private _decimals;
    address public minter;

    error NotMinter();

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
        minter = msg.sender;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        _mint(to, amount);
    }
}
