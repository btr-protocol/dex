// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibDarkPoolStorage as LibStorage} from "./LibDarkPoolStorage.sol";
import {DarkPoolErrors as Errors} from "../darkpool/DarkPoolErrors.sol";
import {Poseidon} from "./generated/Poseidon.sol";
import {Zeros} from "./generated/Zeros.sol";

/// @title LibMerkleTree
/// @notice Incremental Poseidon Merkle Tree implementation
/// @dev Uses Poseidon hash for zkSNARK-friendly operations
library LibMerkleTree {
    // ========== STORAGE ==========

    using LibStorage for LibStorage.DarkPoolStorage;

    // ========== EVENTS ==========

    event LeafInserted(uint32 indexed leafIndex, bytes32 leaf, bytes32 newRoot);

    // ========== ZERO VALUES ==========

    /// @notice Get pre-computed zero value for empty subtree at given level
    /// @dev Uses generated Zeros library with actual Poseidon hashes
    /// @dev zeros[i] = Poseidon(zeros[i-1], zeros[i-1]) for i > 0
    /// @dev zeros[0] = 0
    /// @param level Tree level (0 = leaf, 32 = root)
    /// @return Zero value as bytes32
    function getZeroValue(uint8 level) internal pure returns (bytes32) {
        return Zeros.getZero(level);
    }

    // ========== POSEIDON HASH ==========

    /// @notice Poseidon hash of two field elements
    /// @param left Left input
    /// @param right Right input
    /// @return Hash output
    /// @dev Uses generated Poseidon library (poseidon-solidity package)
    function poseidon2(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return bytes32(Poseidon.hash2(uint256(left), uint256(right)));
    }

    // ========== TREE OPERATIONS ==========

    /// @notice Insert a leaf into the tree
    /// @param leaf Leaf to insert
    /// @return leafIndex Index where leaf was inserted
    function insertLeaf(bytes32 leaf) internal returns (uint32 leafIndex) {
        LibStorage.DarkPoolStorage storage $ = LibStorage.getStorage();

        // Check tree is not full
        leafIndex = $.nextLeafIndex;
        if (leafIndex >= uint32(2 ** $.treeHeight)) {
            revert Errors.TreeFull();
        }

        // Compute new root
        bytes32 newRoot = _computeRoot(leaf, leafIndex);

        // Update storage
        $.nextLeafIndex = leafIndex + 1;
        LibStorage.addRoot(newRoot);

        emit LeafInserted(leafIndex, leaf, newRoot);

        return leafIndex;
    }

    /// @notice Compute merkle root for a new leaf using incremental tree algorithm
    /// @param leaf Leaf to insert
    /// @param leafIndex Index to insert at
    /// @return root New merkle root
    /// @dev Uses "filled subtrees" technique: stores rightmost filled subtree at each level
    /// @dev When inserting at index i, if bit j is set in i, the sibling comes from filledSubtrees[j]
    function _computeRoot(bytes32 leaf, uint32 leafIndex) private returns (bytes32 root) {
        LibStorage.DarkPoolStorage storage $ = LibStorage.getStorage();

        bytes32 currentHash = leaf;
        uint32 currentIndex = leafIndex;

        for (uint8 level = 0; level < $.treeHeight; level++) {
            bytes32 sibling;

            // If the current index is even (left node), sibling is to the right (empty)
            if (currentIndex % 2 == 0) {
                // Right sibling is zero (not yet filled)
                sibling = getZeroValue(level);

                // Store current hash as the filled subtree at this level
                // This will be used as a sibling for future insertions
                $.filledSubtrees[level] = currentHash;

                // Compute parent
                currentHash = poseidon2(currentHash, sibling);
            } else {
                // Current is right node, sibling is left (use stored filled subtree)
                // The left sibling is the most recent filled subtree at this level
                sibling = $.filledSubtrees[level];

                // Compute parent
                currentHash = poseidon2(sibling, currentHash);

                // No need to update filledSubtrees here as we're combining with existing left
            }

            currentIndex = currentIndex / 2;
        }

        return currentHash;
    }

    /// @notice Verify a merkle proof
    /// @param leaf Leaf to verify
    /// @param leafIndex Index of the leaf
    /// @param siblings Sibling hashes for the path
    /// @param root Expected root
    /// @return True if proof is valid
    function verifyProof(
        bytes32 leaf,
        uint32 leafIndex,
        bytes32[] memory siblings,
        bytes32 root
    ) internal pure returns (bool) {
        bytes32 currentHash = leaf;
        uint32 currentIndex = leafIndex;

        for (uint256 i = 0; i < siblings.length; i++) {
            bytes32 sibling = siblings[i];

            if (currentIndex % 2 == 0) {
                // Current is left, sibling is right
                currentHash = poseidon2(currentHash, sibling);
            } else {
                // Current is right, sibling is left
                currentHash = poseidon2(sibling, currentHash);
            }

            currentIndex = currentIndex / 2;
        }

        return currentHash == root;
    }
}
