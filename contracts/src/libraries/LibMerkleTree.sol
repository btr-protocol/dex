// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibStorage as S} from "./LibStorage.sol";
import {IDarkPoolStorage} from "../interfaces/IDarkPoolStorage.sol";
import {DarkPoolErrors as Errors} from "../darkpool/DarkPoolErrors.sol";
import {IDarkPool} from "../interfaces/IDarkPool.sol";
import {Poseidon} from "./Poseidon.sol";

interface IShieldedState {
    function setNextLeafIndex(uint32 _nextLeafIndex) external;
    function setFilledSubtree(uint8 level, bytes32 hash) external;
    function filledSubtrees(uint8 level) external view returns (bytes32);
    function nextLeafIndex() external view returns (uint32);
}

/// @title LibMerkleTree
/// @notice Incremental Poseidon Merkle Tree implementation with global state
/// @dev Uses Poseidon hash for zkSNARK-friendly operations
/// @dev Tree state stored in ShieldedState for sharing across all DarkPools
library LibMerkleTree {
    // ========== STORAGE ==========
    // Note: Tree state is stored in ShieldedState (global), not in individual DarkPool storage

    // ========== EVENTS ==========
    // Note: Event is declared in IDarkPool interface and inherited by DarkPool contract
    // We redeclare here so library code can compile, but actual emission happens in calling contract context
    event LeafInserted(uint32 indexed leafIndex, bytes32 leaf, bytes32 newRoot);

    // ========== ZERO VALUES ==========

    /// @notice Get zero value for tree level
    /// @dev zeros[i] = Poseidon2(zeros[i-1], zeros[i-1]) for i > 0
    /// @param level Tree level (0 = leaf, 32 = root)
    /// @return Zero value as bytes32
    function getZeroValue(uint8 level) internal pure returns (bytes32) {
        if (level == 0) return bytes32(0);
        bytes32 zero = bytes32(0);
        for (uint8 i = 0; i < level; ) {
            zero = bytes32(Poseidon.hash2(uint256(zero), uint256(zero)));
            unchecked { i++; }
        }
        return zero;
    }

    /// @notice Poseidon2 hash of two field elements
    function poseidon2(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return bytes32(Poseidon.hash2(uint256(left), uint256(right)));
    }

    // ========== TREE OPERATIONS ==========

    /// @notice Insert a leaf into the tree via ShieldedState
    /// @param leaf Leaf to insert
    /// @return leafIndex Index where leaf was inserted
    function insertLeaf(bytes32 leaf) internal returns (uint32 leafIndex) {
        IDarkPoolStorage.DarkPoolStorage storage $ = S.darkPool();
        address shieldedStateAddr = $.shieldedState;
        if (shieldedStateAddr == address(0)) revert Errors.ZeroAddress();

        IShieldedState shieldedState = IShieldedState(shieldedStateAddr);

        // Get current leaf index from ShieldedState
        leafIndex = shieldedState.nextLeafIndex();

        // Check tree is not full (using bitshift instead of exponentiation)
        if (leafIndex >= (1 << S.TREE_HEIGHT)) {
            revert Errors.TreeFull();
        }

        // Compute new root
        bytes32 newRoot = _computeRoot(leaf, leafIndex, shieldedState);

        // Update nextLeafIndex in ShieldedState
        unchecked {
            shieldedState.setNextLeafIndex(leafIndex + 1);
        }

        // Add root to ShieldedState
        S.addRoot(newRoot);

        emit LeafInserted(leafIndex, leaf, newRoot);

        return leafIndex;
    }

    /// @notice Compute merkle root for a new leaf using incremental tree algorithm
    /// @param leaf Leaf to insert
    /// @param leafIndex Index to insert at
    /// @param shieldedState Reference to global ShieldedState
    /// @return root New merkle root
    /// @dev Uses "filled subtrees" technique: stores rightmost filled subtree at each level
    /// @dev Optimized with bitwise operations and unchecked arithmetic for gas efficiency
    function _computeRoot(
        bytes32 leaf,
        uint32 leafIndex,
        IShieldedState shieldedState
    ) private returns (bytes32 root) {
        bytes32 h = leaf;
        uint32 idx = leafIndex;
        uint8 height = S.TREE_HEIGHT; // Cache constant to avoid repeated reads

        for (uint8 level = 0; level < height; ) {
            // Use bitwise AND instead of modulo: (idx & 1) == 0 means even (left node)
            if ((idx & 1) == 0) {
                // Left node; right sibling is zero; record subtree
                shieldedState.setFilledSubtree(level, h);
                h = poseidon2(h, getZeroValue(level));
            } else {
                // Right node; left sibling is last filled subtree
                bytes32 filledSubtree = shieldedState.filledSubtrees(level);
                h = poseidon2(filledSubtree, h);
            }

            // Bitwise right shift instead of division
            idx >>= 1;

            // Unchecked increment (level < height always holds)
            unchecked { level++; }
        }

        return h;
    }

    /// @notice Verify a merkle proof
    /// @param leaf Leaf to verify
    /// @param leafIndex Index of the leaf
    /// @param siblings Sibling hashes for the path
    /// @param root Expected root
    /// @return True if proof is valid
    /// @dev Optimized with bitwise operations and unchecked arithmetic
    function verifyProof(
        bytes32 leaf,
        uint32 leafIndex,
        bytes32[] memory siblings,
        bytes32 root
    ) internal pure returns (bool) {
        bytes32 h = leaf;
        uint32 idx = leafIndex;
        uint256 len = siblings.length; // Cache length

        for (uint256 i = 0; i < len; ) {
            bytes32 sibling = siblings[i];

            // Use bitwise AND instead of modulo
            if ((idx & 1) == 0) {
                // Current is left, sibling is right
                h = poseidon2(h, sibling);
            } else {
                // Current is right, sibling is left
                h = poseidon2(sibling, h);
            }

            // Bitwise right shift instead of division
            idx >>= 1;

            // Unchecked increment (i < len always holds)
            unchecked { i++; }
        }

        return h == root;
    }
}
