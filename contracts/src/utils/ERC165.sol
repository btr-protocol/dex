// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC165} from "../interfaces/IERC165.sol";

/// @title ERC165
/// @notice Implementation of ERC-165 Standard Interface Detection
/// @dev Contracts should inherit from this and override supportsInterface to check for additional interfaces
abstract contract ERC165 is IERC165 {
    /// @notice Query if a contract implements an interface
    /// @dev Interface identification is specified in ERC-165
    /// @param interfaceId The interface identifier
    /// @return bool True if the contract implements `interfaceId` and it's not 0xffffffff
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}
