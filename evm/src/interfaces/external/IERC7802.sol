// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IERC7802 -Crosschain Token Interface (mint/burn via authorized bridge)
interface IERC7802 {
    event CrosschainMint(address indexed to, uint256 amount, address indexed bridge);
    event CrosschainBurn(address indexed from, uint256 amount, address indexed bridge);

    /// @param _payload srcChain/dstChain/nonce/metadata context
    function crosschainMint(address _to, uint256 _amount, bytes calldata _payload) external;
    function crosschainBurn(address _from, uint256 _amount, bytes calldata _payload) external;
}
