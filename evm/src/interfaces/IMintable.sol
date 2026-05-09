// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IMintable
/// @notice Mintable + burnable token surface
interface IMintable {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function totalSupply() external view returns (uint256);
    function maxSupply() external view returns (uint256);
}
