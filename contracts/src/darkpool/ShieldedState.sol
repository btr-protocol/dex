// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";

/// @title ShieldedState
/// @notice Global shared state for all DarkPool proxies
/// @dev Implements a single global Merkle tree and nullifier set (Zcash/Tornado pattern)
/// @dev This centralizes anonymity set across all BAMM pools
contract ShieldedState is Ownable {
    // ========== CONSTANTS ==========

    uint8 public constant TREE_HEIGHT = 32;
    uint32 public constant ROOT_HISTORY_SIZE = 100;

    // ========== STATE ==========

    /// @notice Current Merkle root
    bytes32 public currentRoot;

    /// @notice Next leaf index (monotonically increasing)
    uint32 public nextLeafIndex;

    /// @notice Index for circular root history
    uint32 public rootHistoryIndex;

    /// @notice Root history (circular buffer of size ROOT_HISTORY_SIZE)
    bytes32[100] public rootHistory;

    /// @notice Filled subtrees for incremental tree (one per level)
    bytes32[32] public filledSubtrees;

    /// @notice Mapping to check if a root is in history (O(1) lookup)
    mapping(bytes32 => bool) public rootInHistory;

    /// @notice Global nullifier set
    mapping(bytes32 => bool) public nullifierSpent;

    // ========== EVENTS ==========

    event RootAdded(bytes32 indexed newRoot, uint32 nextLeafIndex);
    event NullifierSpent(bytes32 indexed nullifier);

    // ========== INITIALIZATION ==========

    /// @notice Initialize with owner
    /// @param _owner Initial owner address
    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        _initializeOwner(_owner);
    }

    // ========== ROOT MANAGEMENT ==========

    /// @notice Add a new root to the history (internal use only)
    /// @param newRoot Root to add
    function addRoot(bytes32 newRoot) external onlyOwner {
        if (newRoot == bytes32(0)) revert ZeroRoot();

        currentRoot = newRoot;
        rootInHistory[newRoot] = true;

        // Add to circular buffer
        rootHistory[rootHistoryIndex] = newRoot;
        unchecked {
            rootHistoryIndex = (rootHistoryIndex + 1) % ROOT_HISTORY_SIZE;
        }

        emit RootAdded(newRoot, nextLeafIndex);
    }

    /// @notice Check if a root is known (in history)
    /// @param root Root to check
    /// @return True if root is in history
    function isKnownRoot(bytes32 root) external view returns (bool) {
        return rootInHistory[root];
    }

    // ========== NULLIFIER MANAGEMENT ==========

    /// @notice Mark a nullifier as spent
    /// @param nullifier Nullifier to mark
    function spendNullifier(bytes32 nullifier) external onlyOwner {
        if (nullifier == bytes32(0)) revert ZeroNullifier();
        if (nullifierSpent[nullifier]) revert NullifierAlreadySpent(nullifier);

        nullifierSpent[nullifier] = true;
        emit NullifierSpent(nullifier);
    }

    /// @notice Mark multiple nullifiers as spent
    /// @param nullifiers Array of nullifiers
    function spendNullifiers(bytes32[] calldata nullifiers) external onlyOwner {
        uint256 len = nullifiers.length;
        for (uint256 i = 0; i < len; ) {
            bytes32 nullifier = nullifiers[i];
            if (nullifier == bytes32(0)) revert ZeroNullifier();
            if (nullifierSpent[nullifier]) revert NullifierAlreadySpent(nullifier);

            nullifierSpent[nullifier] = true;
            emit NullifierSpent(nullifier);

            unchecked { i++; }
        }
    }

    // ========== TREE OPERATIONS ==========

    /// @notice Update next leaf index (for leaf insertion tracking)
    /// @param _nextLeafIndex New next leaf index
    function setNextLeafIndex(uint32 _nextLeafIndex) external onlyOwner {
        nextLeafIndex = _nextLeafIndex;
    }

    /// @notice Update a filled subtree at given level
    /// @param level Level (0-31)
    /// @param hash Hash to store
    function setFilledSubtree(uint8 level, bytes32 hash) external onlyOwner {
        if (level >= TREE_HEIGHT) revert InvalidLevel();
        filledSubtrees[level] = hash;
    }

    // ========== ERRORS ==========

    error ZeroAddress();
    error ZeroRoot();
    error ZeroNullifier();
    error NullifierAlreadySpent(bytes32 nullifier);
    error InvalidLevel();
}
