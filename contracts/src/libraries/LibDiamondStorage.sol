// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title LibDiamondStorage
/// @notice Minimal diamond proxy storage for routing facet selectors
/// @dev Separates diamond routing state from BAMM business logic state
library LibDiamondStorage {

    /// @notice Diamond storage slot using EIP-7201
    /// @dev keccak256(abi.encode(uint256(keccak256("bamm.diamond.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant DIAMOND_STORAGE_SLOT =
        0x17ef48b26ab70f0b0e2af8d38d2ac3e7bedb4a7d8f7d5c6e50c9a37a90a28600;

    /// @notice Facet information stored for each selector
    struct FacetInfo {
        address facet;          // Facet implementation address
        uint16 selectorPosition; // Position in selectors array for O(1) removal
    }

    /// @notice Diamond storage structure
    struct DiamondStorage {
        mapping(bytes4 => FacetInfo) facets;  // selector → FacetInfo
        bytes4[] selectors;                    // Array of all registered selectors
        address owner;                         // Diamond owner (for diamondCut)
    }

    /// @notice Get diamond storage pointer using EIP-7201
    /// @return d Diamond storage reference
    function ds() internal pure returns (DiamondStorage storage d) {
        bytes32 slot = DIAMOND_STORAGE_SLOT;
        assembly {
            d.slot := slot
        }
    }

    /// @notice Get facet address for a selector
    /// @param selector Function selector
    /// @return facet Implementation address (address(0) if not registered)
    function getFacet(bytes4 selector) internal view returns (address facet) {
        DiamondStorage storage d = ds();
        facet = d.facets[selector].facet;
    }

    /// @notice Check if a selector is registered
    /// @param selector Function selector
    /// @return registered True if selector is registered
    function isRegistered(bytes4 selector) internal view returns (bool registered) {
        DiamondStorage storage d = ds();
        registered = d.facets[selector].facet != address(0);
    }

    /// @notice Get total number of registered selectors
    /// @return count Number of selectors
    function selectorCount() internal view returns (uint256 count) {
        DiamondStorage storage d = ds();
        count = d.selectors.length;
    }

    /// @notice Get selector at index
    /// @param index Array index
    /// @return selector Selector at index
    function selectorAt(uint256 index) internal view returns (bytes4 selector) {
        DiamondStorage storage d = ds();
        if (index >= d.selectors.length) revert IndexOutOfBounds();
        selector = d.selectors[index];
    }

    // ========== ERRORS ==========

    error IndexOutOfBounds();
    error FacetAlreadyAdded();
    error FacetNotFound();
    error SelectorAlreadyExists();
}
