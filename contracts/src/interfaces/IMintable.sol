// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IMintable
/// @notice Interface for tokens with mint and burn capabilities
interface IMintable {
    /// @notice Mint tokens to an address
    /// @param to Recipient address
    /// @param amount Amount to mint
    function mint(address to, uint256 amount) external;

    /// @notice Burn tokens from an address
    /// @param from Source address
    /// @param amount Amount to burn
    function burn(address from, uint256 amount) external;

    /// @notice Get total supply
    /// @return Total supply of token
    function totalSupply() external view returns (uint256);

    /// @notice Get maximum supply cap
    /// @return Maximum supply of token
    function maxSupply() external view returns (uint256);
}
