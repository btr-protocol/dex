// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOracle} from "./IOracle.sol";

/// @title IExternalOracle
/// @notice Interface for external multi-asset oracle contracts
/// @dev External oracles are standalone contracts that can serve price/volatility data
///      for multiple assets. They support batch updates and asset management.
///      All prices use b64 float format, all volatility uses 1e6 base.
///      Implements IOracle for uniform oracle reading interface.
interface IExternalOracle is IOracle {

    // ========== EVENTS ==========
    // Note: IOracle view functions (getFeedData, isFresh, getFastPrice) are inherited

    /// @notice Emitted when a new oracle pair is added
    event AssetAdded(
        bytes32 indexed feedId,
        address indexed baseAsset,
        address indexed quoteAsset,
        uint64 fastEMA,
        uint64 slowEMA,
        uint32 fastVolEMA,
        uint32 slowVolEMA,
        uint16 maxDeviationBps
    );

    /// @notice Emitted when an oracle is updated
    event AssetUpdated(
        bytes32 indexed feedId,
        uint64 fastTWAP,
        uint64 slowTWAP,
        uint32 fastVolEMA,
        uint32 slowVolEMA,
        address indexed updater
    );

    /// @notice Emitted when multiple oracles are updated in a batch
    event BatchUpdated(
        bytes32[] feedIds,
        address indexed updater
    );

    /// @notice Emitted when oracle-specific configuration is updated
    event AssetConfigUpdated(
        bytes32 indexed feedId,
        uint16 maxDeviationBps
    );

    // ========== ERRORS ==========

    error InvalidPrice();
    error InvalidVolatility();
    error InvalidDeviation();
    error PriceChangeTooLarge();
    error UpdateTooFrequent();
    error ZeroPrice();
    error ZeroAddress();
    error AssetNotFound();
    error AssetAlreadyExists();
    error InvalidArrayLength();
    error InvalidParameter();

    // ========== ASSET MANAGEMENT VIEW FUNCTIONS ==========
    // These are external-oracle-specific (not in base IOracle)

    /// @notice Check if an address has oracle role (can update prices)
    /// @param account Address to check
    /// @return hasRole True if has oracle role
    function hasOracleRole(address account) external view returns (bool hasRole);

    /// @notice Get all registered feed IDs
    /// @return feedIds Array of registered feed IDs
    function getRegisteredOracleIds() external view returns (bytes32[] memory feedIds);

    /// @notice Get count of registered oracles
    /// @return count Number of oracles
    function getOracleCount() external view returns (uint256 count);

    /// @notice Check if feed ID exists in this oracle
    /// @param feedId Oracle identifier
    /// @return exists True if oracle is configured
    function oracleExists(bytes32 feedId) external view returns (bool exists);

    // ========== ORACLE ROLE FUNCTIONS ==========

    /// @notice Update oracle data for a single feed ID (oracle role only)
    /// @param feedId Oracle identifier
    /// @param newFastEMA New fast price EMA in b64 format
    /// @param newSlowEMA New slow price EMA in b64 format
    /// @param newFastVolEMA New fast volatility EMA (1e6 base)
    /// @param newSlowVolEMA New slow volatility EMA (1e6 base)
    function updateOracle(
        bytes32 feedId,
        uint64 newFastEMA,
        uint64 newSlowEMA,
        uint32 newFastVolEMA,
        uint32 newSlowVolEMA
    ) external;

    /// @notice Batch update oracle data for multiple feed IDs (oracle role only)
    /// @param feedIds Array of oracle identifiers
    /// @param fastEMAs Array of fast price EMAs in b64 format
    /// @param slowEMAs Array of slow price EMAs in b64 format
    /// @param fastVolEMAs Array of fast volatility EMAs (1e6 base)
    /// @param slowVolEMAs Array of slow volatility EMAs (1e6 base)
    function batchUpdateOracles(
        bytes32[] calldata feedIds,
        uint64[] calldata fastEMAs,
        uint64[] calldata slowEMAs,
        uint32[] calldata fastVolEMAs,
        uint32[] calldata slowVolEMAs
    ) external;

    // ========== OWNER FUNCTIONS ==========

    /// @notice Add a new oracle pair (owner only)
    /// @param baseAsset Base asset address (asset being priced)
    /// @param quoteAsset Quote asset address (pricing currency)
    /// @param fastEMA Initial fast price EMA (b64 format)
    /// @param slowEMA Initial slow price EMA (b64 format)
    /// @param fastVolEMAEMA Initial fast volatility EMA (1e6 base)
    /// @param slowVolEMAEMA Initial slow volatility EMA (1e6 base)
    /// @param maxDeviation Deviation threshold triggering update (0.0001% precision: 10_000 = 1%, max 65_000 = 6.5%)
    /// @param ttl Time-to-live in seconds (e.g., 3600 = 1 hour)
    function addOraclePair(
        address baseAsset,
        address quoteAsset,
        uint64 fastEMA,
        uint64 slowEMA,
        uint32 fastVolEMAEMA,
        uint32 slowVolEMAEMA,
        uint16 maxDeviation,
        uint16 ttl
    ) external;

    /// @notice Update oracle-specific configuration (owner only)
    /// @param feedId Oracle identifier
    /// @param maxDeviation New deviation threshold (0.0001% precision: 10_000 = 1%, max 65_000 = 6.5%)
    /// @param ttl New time-to-live in seconds
    function updateOracleConfig(
        bytes32 feedId,
        uint16 maxDeviation,
        uint16 ttl
    ) external;

    /// @notice Grant oracle role to an address (owner only)
    /// @param oracle Address to grant oracle role
    function grantOracleRole(address oracle) external;

    /// @notice Revoke oracle role from an address (owner only)
    /// @param oracle Address to revoke oracle role
    function revokeOracleRole(address oracle) external;
}
