// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IInternalOracle} from "../interfaces/IInternalOracle.sol";
import {LibStorage as S} from "../libraries/LibStorage.sol";

/// @title BAMMStorage
/// @notice Base contract providing consolidated storage accessors for BAMM contracts
/// @dev Eliminates redundant virtual/override patterns across inheritance tree
abstract contract BAMMStorage {
    // ========== STORAGE ACCESSORS ==========

    /// @notice Get full BAMM storage struct
    function _sb() internal pure returns (IBAMM.BAMMStorage storage) {
        return S.bamm();
    }

    /// @notice Get asset storage for given token
    function _getAsset(address token) internal view returns (IBAMM.Asset storage) {
        return _sb().assets[token];
    }

    /// @notice Get internal oracle feed data for given feed ID
    function _getOracleEntry(bytes32 feedId) internal view returns (IInternalOracle.InternalFeedData storage) {
        return _sb().internalFeeds[feedId];
    }

    /// @notice Get registered asset by index
    function _getRegisteredAsset(uint256 index) internal view returns (address) {
        return _sb().registeredAssets[index];
    }
}
