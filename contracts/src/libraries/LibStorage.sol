// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {LibPricing as P} from "./LibPricing.sol";

/// @title LibStorage
/// @notice Centralized EIP-7201 namespaced storage for the entire protocol
/// @dev Consolidates BAMM, DarkPool, and Oracle storage layouts
library LibStorage {

    // ========================================
    // ORACLE STORAGE
    // ========================================

    /// @notice Oracle data stored per oracleId (base/quote pair)
    /// @dev Separates oracle state from Asset struct to support quote currency changes
    struct OracleEntry {
        uint256 priceAccumulator;      // Σ(price × timeElapsed) - cumulative price-seconds
        uint64 currentPrice;            // Current spot price in b64 format
        uint256 fastAccumSnapshot;      // Accumulator value at last fast snapshot
        uint32 fastSnapshotTime;        // When fast snapshot was taken
        uint256 slowAccumSnapshot;      // Accumulator value at last slow snapshot
        uint32 slowSnapshotTime;        // When slow snapshot was taken
        uint32 fastWindow;             // Fast TWAP window in seconds (e.g., 6 hours)
        uint32 slowWindow;             // Slow TWAP window in seconds (e.g., 7 days)
        uint32 fastVolatility;         // Fast volatility EMA (1e6 base)
        uint32 slowVolatility;         // Slow volatility EMA (1e6 base)
        uint32 lastOracleUpdate;       // Timestamp of last update
        uint16 maxTWAPChange;          // Max price change per update in bps
        bool exists;                   // Whether this oracle entry is initialized
    }

    /// @notice Compute oracle ID from base and quote assets
    /// @param baseAsset Asset being priced
    /// @param quoteAsset Pricing currency (e.g., pool's baseToken)
    /// @return oracleId keccak256 hash of packed addresses
    function computeOracleId(address baseAsset, address quoteAsset) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(baseAsset, quoteAsset));
    }

    // ========================================
    // BAMM STORAGE
    // ========================================

    /// @notice Base asset migration state (for paginated updates)
    struct BaseAssetMigration {
        address newBase;           // Target base asset
        address oldBase;           // Current base asset (snapshot)
        uint256 conversionRate;    // Conversion rate (1e18 precision)
        uint256 nextIndex;         // Next asset index to process
        uint256 totalAssets;       // Total number of assets to migrate
        bool inProgress;           // Migration in progress flag
        uint256 startedAt;         // Timestamp when migration started
        bytes oracleReinitData;    // Oracle reinitialization data for internal oracles
    }

    /// @notice Main storage structure for BAMM
    /// @custom:storage-location erc7201:bamm.storage
    struct BAMMStorage {
        address baseToken;
        bool isPoolPaused;
        uint256 cachedTotalValue;       // Delta-based cache: sum of (reserves * price) for all assets
        uint256 cachedTotalLiabilities; // Delta-based cache: sum of (liabilities * price) for all assets
        uint256 cacheTimestamp;
        address[] registeredAssets;
        mapping(address => IBAMM.Asset) assets;
        mapping(address => IBAMM.LiquidityProfile) liquidityProfiles;
        mapping(address => IBAMM.LPState) lpStates;
        mapping(address => IBAMM.CircuitBreaker) circuitBreakers;
        mapping(address => mapping(address => uint256)) scaledBalances;
        mapping(address => uint256) protocolFees;
        mapping(address => bool) blacklisted;
        P.FeeParams feeParams;
        uint8 fastTWAPWeight;
        uint8 slowTWAPWeight;
        BaseAssetMigration baseAssetMigration;  // Paginated migration state
        mapping(bytes32 => OracleEntry) oracleEntries;  // Oracle data by oracleId
    }

    /// @notice EIP-7201 storage slot for BAMM
    /// @dev keccak256(abi.encode(uint256(keccak256("bamm.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant BAMM_STORAGE_SLOT =
        0x8757882912c4910e2fa81a635c8b91b57e7ace2779ba7ca50d0cf6d4b7658b00;

    /// @notice Get BAMM storage pointer using EIP-7201
    function getStorage() internal pure returns (BAMMStorage storage $) {
        assembly { $.slot := BAMM_STORAGE_SLOT }
    }

    // ========================================
    // DARKPOOL STORAGE
    // ========================================

    // DarkPool constants
    uint8 internal constant TREE_HEIGHT = 32;
    uint32 internal constant ROOT_HISTORY_SIZE = 100;
    uint256 internal constant PRECISION = 1e18;
    uint8 internal constant NOTE_TYPE_TOKEN = 0;
    uint8 internal constant NOTE_TYPE_LP = 1;

    // Action types
    uint8 internal constant ACTION_TRANSFER = 0;
    uint8 internal constant ACTION_SWAP = 1;
    uint8 internal constant ACTION_LP_DEPOSIT = 2;
    uint8 internal constant ACTION_LP_WITHDRAW = 3;

    /// @notice Main storage structure for DarkPool
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

    /// @dev keccak256(abi.encode(uint256(keccak256("darkpool.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DARKPOOL_STORAGE_SLOT =
        0xd520fb88501ea3fd6f848e11ec42e1ae44feb0f5d56e27f3b5b3569dc75a5d00;

    /// @notice Get DarkPool storage pointer using EIP-7201
    function getDarkPoolStorage() internal pure returns (DarkPoolStorage storage $) {
        assembly { $.slot := DARKPOOL_STORAGE_SLOT }
    }

    // ========================================
    // DARKPOOL HELPER FUNCTIONS
    // ========================================

    /// @notice Check if a root is in the history and not expired
    /// @param root Root to check
    /// @return True if root is in history and still valid
    function isKnownRoot(bytes32 root) internal view returns (bool) {
        DarkPoolStorage storage $ = getDarkPoolStorage();

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
        DarkPoolStorage storage $ = getDarkPoolStorage();
        $.rootHistory[$.rootHistoryIndex] = root;
        $.rootHistoryIndex = uint32(($.rootHistoryIndex + 1) % ROOT_HISTORY_SIZE);
        $.currentRoot = root;
        $.rootTimestamp = block.timestamp;
    }

    // ========================================
    // RESERVED STORAGE SLOTS (FUTURE USE)
    // ========================================

    /// @notice Reserved EIP-7201 storage slot for Oracle (future use)
    /// @dev keccak256(abi.encode(uint256(keccak256("oracle.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev Currently oracle data stored in BAMMStorage.oracleEntries
    bytes32 internal constant ORACLE_STORAGE_SLOT =
        0xbe7d32a8927afa9d36aa1d622b13e4698467d622ffee9b72c594522d41542300;

    /// @notice Reserved EIP-7201 storage slot for Hooks (future use)
    /// @dev keccak256(abi.encode(uint256(keccak256("hook.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev Currently hook addresses stored in Asset.hooks field
    bytes32 internal constant HOOK_STORAGE_SLOT =
        0x39ad489ed614fb1cd2c7d913838f5a7d7a73df8b6bd3a3202be6a193febd1000;
}
