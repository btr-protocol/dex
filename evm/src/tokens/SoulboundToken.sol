// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title SoulboundToken
/// @notice Non-transferable ERC20-like for points campaigns; only minter can mint/burn
contract SoulboundToken is ERC20 {
    error NonTransferable();

    string private _name;
    string private _symbol;
    address public immutable minter;

    constructor(string memory name_, string memory symbol_, address minter_) {
        _name = name_;
        _symbol = symbol_;
        minter = minter_;
    }

    function name() public view override returns (string memory) { return _name; }
    function symbol() public view override returns (string memory) { return _symbol; }

    function _disabled() internal pure { revert NonTransferable(); }
    function transfer(address, uint256) public pure override returns (bool) { _disabled(); return false; }
    function transferFrom(address, address, uint256) public pure override returns (bool) { _disabled(); return false; }
    function approve(address, uint256) public pure override returns (bool) { _disabled(); return false; }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert Ownable.Unauthorized();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != minter) revert Ownable.Unauthorized();
        _burn(from, amount);
    }
}
