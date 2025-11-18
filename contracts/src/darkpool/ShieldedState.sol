// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {Poseidon} from "../libraries/Poseidon.sol";

/// @title ShieldedState
/// @notice Global shared state for all DarkPool proxies
/// @dev Implements a single global Merkle tree and nullifier set (Zcash/Tornado pattern)
/// @dev This centralizes anonymity set across all BAMM pools
/// @dev Tree insertion logic is embedded here to eliminate external call overhead (~1M gas per insert)
contract ShieldedState is Ownable {
    // ========== CONSTANTS ==========

    uint8 public constant TREE_HEIGHT = 32;
    uint32 public constant ROOT_HISTORY_SIZE = 100;

    /// @notice Precomputed zero values for each tree level
    /// @dev These are constant and never change, eliminating recomputation overhead
    bytes32 public constant ZERO_L0 = bytes32(0x0000000000000000000000000000000000000000000000000000000000000000); // Level 0
    bytes32 public constant ZERO_L1 = bytes32(0x21cc8c5dd5758a6e3ef26d6b2ae1b4670eadbe58dd5ac3c5a7d56ef6ce75d462); // Level 1
    bytes32 public constant ZERO_L2 = bytes32(0x0b0a000000000000000000000000000000000000000000000000000000000000); // Level 2+

    // TODO: Generate full ZEROS array using scripts/trusted-setup-ceremony.sh

    /// @notice Get zero value for a tree level
    function getZeroForLevel(uint8 level) public pure returns (bytes32) {
        if (level == 0) return ZERO_L0;
        if (level == 1) return ZERO_L1;
        return ZERO_L2; // Default for all higher levels
    }

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

    /// @notice DarkPool whitelist - only whitelisted DarkPool instances can modify tree
    mapping(address => bool) public isDarkPool;

    // ========== MODIFIERS ==========

    modifier onlyDarkPool() {
        if (!isDarkPool[msg.sender]) revert Unauthorized();
        _;
    }

    // ========== EVENTS ==========

    event RootAdded(bytes32 indexed newRoot, uint32 nextLeafIndex);
    event NullifierSpent(bytes32 indexed nullifier);
    event DarkPoolAdded(address indexed darkPool);
    event DarkPoolRemoved(address indexed darkPool);

    // ========== INITIALIZATION ==========

    /// @notice Initialize with owner
    /// @param _owner Initial owner address
    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        _initializeOwner(_owner);
    }

    // ========== DARKPOOL MANAGEMENT ==========

    /// @notice Add a DarkPool instance to whitelist
    /// @param darkPool DarkPool contract address
    function addDarkPool(address darkPool) external onlyOwner {
        if (darkPool == address(0)) revert ZeroAddress();
        isDarkPool[darkPool] = true;
        emit DarkPoolAdded(darkPool);
    }

    /// @notice Remove a DarkPool instance from whitelist
    /// @param darkPool DarkPool contract address
    function removeDarkPool(address darkPool) external onlyOwner {
        if (darkPool == address(0)) revert ZeroAddress();
        isDarkPool[darkPool] = false;
        emit DarkPoolRemoved(darkPool);
    }

    // ========== MERKLE TREE OPERATIONS ==========

    /// @notice Insert a leaf into the Merkle tree and return new root
    /// @dev Called by DarkPool.depositToken() and DarkPool.depositAndMintLP()
    /// @dev Computes full tree update in single transaction (no external calls)
    /// @param leaf The leaf commitment to insert
    /// @return leafIndex Index of inserted leaf (for events)
    /// @return newRoot Updated Merkle root
    function insertLeaf(bytes32 leaf)
        external
        onlyDarkPool
        returns (uint32 leafIndex, bytes32 newRoot)
    {
        if (leaf == bytes32(0)) revert ZeroLeaf();

        leafIndex = nextLeafIndex;
        bytes32 h = leaf;
        uint32 idx = leafIndex;

        // Traverse tree from leaf to root, updating filled subtrees
        for (uint8 level = 0; level < TREE_HEIGHT; ) {
            if ((idx & 1) == 0) {
                // Leaf is at left position, use zero for right sibling
                filledSubtrees[level] = h;
                h = bytes32(Poseidon.hash2(uint256(h), uint256(getZeroForLevel(level))));
            } else {
                // Leaf is at right position, use filled subtree for left sibling
                h = bytes32(Poseidon.hash2(uint256(filledSubtrees[level]), uint256(h)));
            }
            idx >>= 1;
            unchecked { ++level; }
        }

        // Update tree state
        nextLeafIndex = leafIndex + 1;
        currentRoot = h;
        rootInHistory[h] = true;

        // Add to circular root history
        rootHistory[rootHistoryIndex] = h;
        unchecked {
            rootHistoryIndex = (rootHistoryIndex + 1) % ROOT_HISTORY_SIZE;
        }

        emit RootAdded(h, leafIndex);
        return (leafIndex, h);
    }

    /// @notice Check if a root is in history
    /// @param root Root to check
    /// @return True if root exists in history
    function isKnownRoot(bytes32 root) external view returns (bool) {
        return rootInHistory[root];
    }

    // ========== NULLIFIER MANAGEMENT ==========

    /// @notice Mark a nullifier as spent
    /// @dev Called by DarkPool.transact() via LibVerifier
    /// @param nullifier Nullifier to mark as spent
    function spendNullifier(bytes32 nullifier) external onlyDarkPool {
        if (nullifier == bytes32(0)) revert ZeroNullifier();
        if (nullifierSpent[nullifier]) revert NullifierAlreadySpent(nullifier);

        nullifierSpent[nullifier] = true;
        emit NullifierSpent(nullifier);
    }

    /// @notice Mark multiple nullifiers as spent (batch operation)
    /// @dev Called by DarkPool.transact() via LibVerifier
    /// @param nullifiers Array of nullifiers to mark as spent
    function spendNullifiers(bytes32[] calldata nullifiers) external onlyDarkPool {
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

    // ========== ERRORS ==========

    error ZeroAddress();
    error ZeroLeaf();
    error ZeroNullifier();
    error NullifierAlreadySpent(bytes32 nullifier);
}
