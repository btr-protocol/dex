// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {LibPricing as P} from "./LibPricing.sol";

/// @title LibStorage
/// @notice Centralized storage structure for BAMM protocol
/// @dev Uses EIP-7201 namespaced storage pattern
library LibStorage {

    /// @notice Base asset migration state (for paginated updates)
    struct BaseAssetMigration {
        address newBase;           // Target base asset
        address oldBase;           // Current base asset (snapshot)
        uint256 conversionRate;    // Conversion rate (1e18 precision)
        uint256 nextIndex;         // Next asset index to process
        uint256 totalAssets;       // Total number of assets to migrate
        bool inProgress;           // Migration in progress flag
        uint256 startedAt;         // Timestamp when migration started
    }

    /// @notice Main storage structure for BAMM
    /// @custom:storage-location erc7201:bamm.storage
    struct BAMMStorage {
        address baseToken;
        bool isPoolPaused;
        uint256 cachedTotalValue;
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
    }

    /// @notice EIP-7201 storage slot for BAMM
    bytes32 internal constant STORAGE_SLOT = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;

    /// @notice Get storage pointer using EIP-7201
    function getStorage() internal pure returns (BAMMStorage storage $) {
        assembly { $.slot := STORAGE_SLOT }
    }
}
