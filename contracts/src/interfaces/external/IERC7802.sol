// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title IERC7802
/// @notice Crosschain Token Interface
/// @dev Standard interface for tokens with crosschain mint/burn capabilities
/// @dev See https://eips.ethereum.org/EIPS/eip-7802
interface IERC7802 {
    /// @notice Emitted when tokens are minted for crosschain transfer
    /// @param to Address receiving the minted tokens
    /// @param amount Amount of tokens minted
    /// @param bridge Bridge contract that initiated the mint
    event CrosschainMint(address indexed to, uint256 amount, address indexed bridge);

    /// @notice Emitted when tokens are burned for crosschain transfer
    /// @param from Address whose tokens are burned
    /// @param amount Amount of tokens burned
    /// @param bridge Bridge contract that initiated the burn
    event CrosschainBurn(address indexed from, uint256 amount, address indexed bridge);

    /// @notice Mint tokens to an address via authorized bridge
    /// @dev Must emit Transfer(address(0), _to, _amount) for ERC-20 compliance
    /// @dev Must emit CrosschainMint(_to, _amount, msg.sender)
    /// @param _to Address to mint tokens to
    /// @param _amount Amount of tokens to mint
    /// @param _payload Additional context (srcChain, dstChain, nonce, metadata)
    function crosschainMint(address _to, uint256 _amount, bytes calldata _payload) external;

    /// @notice Burn tokens from an address via authorized bridge
    /// @dev Should emit Transfer(_from, address(0), _amount) per ERC-5679
    /// @dev Must emit CrosschainBurn(_from, _amount, msg.sender)
    /// @param _from Address to burn tokens from
    /// @param _amount Amount of tokens to burn
    /// @param _payload Additional context (srcChain, dstChain, nonce, metadata)
    function crosschainBurn(address _from, uint256 _amount, bytes calldata _payload) external;
}
