// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ERC20} from "solady/tokens/ERC20.sol";
import {IERC7802} from "../interfaces/external/IERC7802.sol";

/// @title BridgeableERC20
/// @notice Ultra-compact ERC20 + ERC7802 for crosschain mint/burn
abstract contract BridgeableERC20 is ERC20, IERC7802 {
    error UnauthorizedBridge();

    /// @dev Get authorized bridge (must be implemented by derived contract)
    function _getBridge() internal view virtual returns (address);

    modifier onlyBridge() {
        if (msg.sender != _getBridge()) revert UnauthorizedBridge();
        _;
    }

    /// @inheritdoc IERC7802
    function crosschainMint(address to, uint256 amount, bytes calldata) external onlyBridge {
        _mint(to, amount);
        emit CrosschainMint(to, amount, msg.sender);
    }

    /// @inheritdoc IERC7802
    function crosschainBurn(address from, uint256 amount, bytes calldata) external onlyBridge {
        _burn(from, amount);
        emit CrosschainBurn(from, amount, msg.sender);
    }

    /// @notice ERC165 interface detection
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0x33331994; // ERC165 | ERC7802
    }
}