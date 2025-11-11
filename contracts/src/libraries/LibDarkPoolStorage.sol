// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title LibDarkPoolStorage
/// @notice EIP-7201 namespaced storage for DarkPool
library LibDarkPoolStorage {
    // ========== CONSTANTS ==========

    uint8 constant TREE_HEIGHT = 32;
    uint32 constant ROOT_HISTORY_SIZE = 100;
    uint256 constant PRECISION = 1e18;
    uint8 constant NOTE_TYPE_TOKEN = 0;
    uint8 constant NOTE_TYPE_LP = 1;

    // Action types
    uint8 constant ACTION_TRANSFER = 0;
    uint8 constant ACTION_SWAP = 1;
    uint8 constant ACTION_LP_DEPOSIT = 2;
    uint8 constant ACTION_LP_WITHDRAW = 3;

    // ========== STORAGE STRUCT ==========

    /// @custom:storage-location erc7201:darkpool.storage.v1
    struct DarkPoolStorage {
        // Associated BAMM Pool
        address bammPool;

        // Merkle Tree State
        uint32 nextLeafIndex;
        bytes32 currentRoot;
        bytes32[ROOT_HISTORY_SIZE] rootHistory;
        uint32 rootHistoryIndex;
        uint256 rootTimestamp; // Timestamp of current root for expiration tracking

        // Incremental Merkle Tree: filled subtrees at each level
        // filledSubtrees[level] = rightmost filled subtree hash at that level
        mapping(uint8 => bytes32) filledSubtrees;

        // Nullifier Tracking
        mapping(bytes32 => bool) nullifierSpent;

        // Verifier & Config
        address verifier;
        uint8 treeHeight;
        uint32 rootHistorySize;
        bool paused;
        bool requireASP;

        // Association Set Roots with expiration
        mapping(bytes32 => uint256) aspRootExpiry; // timestamp when ASP root expires (0 = not approved)

        // Reserved for future upgrades
        uint256[37] __gap;
    }

    // ========== STORAGE LOCATION ==========

    /// @dev keccak256(abi.encode(uint256(keccak256("darkpool.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION =
        0x8f5e61c5c5e9c2e8e1e3e5e7e9eaece0e2e4e6e8eaeceee0e2e4e6e8eaecee00;

    /// @notice Get the storage struct
    /// @return $ Storage struct reference
    function getStorage() internal pure returns (DarkPoolStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }

    // ========== HELPER FUNCTIONS ==========

    /// @notice Check if a root is in the history and not expired
    /// @param root Root to check
    /// @return True if root is in history and still valid
    function isKnownRoot(bytes32 root) internal view returns (bool) {
        DarkPoolStorage storage $ = getStorage();

        // Current root is always valid
        if ($.currentRoot == root) return true;

        for (uint256 i = 0; i < ROOT_HISTORY_SIZE; i++) {
            if ($.rootHistory[i] == root) {
                // Found the root - it's valid if within history
                return true;
            }
        }
        return false;
    }

    /// @notice Add a root to the history with timestamp
    /// @param root Root to add
    function addRoot(bytes32 root) internal {
        DarkPoolStorage storage $ = getStorage();
        $.rootHistory[$.rootHistoryIndex] = root;
        $.rootHistoryIndex = uint32(($.rootHistoryIndex + 1) % ROOT_HISTORY_SIZE);
        $.currentRoot = root;
        $.rootTimestamp = block.timestamp;
    }
}
