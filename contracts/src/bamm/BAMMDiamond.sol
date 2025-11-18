// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibDiamondStorage} from "../libraries/LibDiamondStorage.sol";

/// @title BAMMDiamond
/// @notice Minimal diamond proxy router base contract
/// @dev Provides facet routing and diamondCut functionality
/// @dev No events or advanced features - just lean routing
abstract contract BAMMDiamond {
    using LibDiamondStorage for LibDiamondStorage.DiamondStorage;

    // ========== DIAMOND OPERATIONS ==========

    /// @notice Action type for diamondCut
    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }

    /// @notice Facet cut instruction
    struct FacetCut {
        address facet;          // Facet implementation address
        FacetCutAction action;  // Action: Add, Replace, Remove
        bytes4[] selectors;     // Function selectors to add/replace/remove
    }

    // ========== FALLBACK ROUTING ==========

    /// @notice Route unknown selectors to registered facets
    /// @dev Uses delegatecall to execute facet code in this contract's context
    fallback() external payable {
        LibDiamondStorage.DiamondStorage storage d = LibDiamondStorage.ds();
        address facet = d.facets[msg.sig].facet;

        if (facet == address(0)) {
            revert FacetNotFound(msg.sig);
        }

        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    /// @notice Accept ETH if received
    receive() external payable {}

    // ========== INTERNAL DIAMOND CUT ==========

    /// @notice Execute a diamond cut (add/replace/remove facets)
    /// @dev Internal function - called by core during initialization or updates
    /// @param cuts Array of facet cut instructions
    function _diamondCut(FacetCut[] memory cuts) internal {
        LibDiamondStorage.DiamondStorage storage d = LibDiamondStorage.ds();

        for (uint256 i = 0; i < cuts.length; ++i) {
            FacetCut memory cut = cuts[i];

            if (cut.action == FacetCutAction.Add || cut.action == FacetCutAction.Replace) {
                // Add or replace selectors
                for (uint256 j = 0; j < cut.selectors.length; ++j) {
                    bytes4 selector = cut.selectors[j];

                    LibDiamondStorage.FacetInfo storage info = d.facets[selector];

                    if (cut.action == FacetCutAction.Add && info.facet != address(0)) {
                        revert SelectorAlreadyExists(selector);
                    }

                    if (info.facet == address(0)) {
                        // New selector - add to array
                        info.selectorPosition = uint16(d.selectors.length);
                        d.selectors.push(selector);
                    }

                    info.facet = cut.facet;
                }
            } else if (cut.action == FacetCutAction.Remove) {
                // Remove selectors
                for (uint256 j = 0; j < cut.selectors.length; ++j) {
                    bytes4 selector = cut.selectors[j];

                    LibDiamondStorage.FacetInfo storage info = d.facets[selector];

                    if (info.facet == address(0)) {
                        revert SelectorNotFound(selector);
                    }

                    // Swap-and-pop from selectors array
                    uint16 pos = info.selectorPosition;
                    bytes4 lastSelector = d.selectors[d.selectors.length - 1];

                    d.selectors[pos] = lastSelector;
                    d.facets[lastSelector].selectorPosition = pos;

                    d.selectors.pop();
                    delete d.facets[selector];
                }
            }
        }

        emit DiamondCut(cuts);
    }

    // ========== INTERNAL DELEGATE HELPER ==========

    /// @notice Explicitly delegatecall a facet without using fallback
    /// @dev Useful for hot-path pricing and oracle calls from BAMMCore
    /// @param facet Facet address to call
    /// @param data Encoded function call
    /// @return Returned data from facet
    function _delegateTo(address facet, bytes memory data) internal returns (bytes memory) {
        (bool ok, bytes memory ret) = facet.delegatecall(data);

        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }

        return ret;
    }

    // ========== EVENTS ==========

    event DiamondCut(FacetCut[] cuts);

    // ========== ERRORS ==========

    error FacetNotFound(bytes4 selector);
    error SelectorAlreadyExists(bytes4 selector);
    error SelectorNotFound(bytes4 selector);
}
