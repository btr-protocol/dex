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
    // Note: IOracle view functions (getOracleData, isFresh, getFastPrice) are inherited

    /// @notice Emitted when a new oracle pair is added
    event AssetAdded(
        bytes32 indexed oracleId,
        address indexed baseAsset,
        address indexed quoteAsset,
        uint64 initialFastPrice,
        uint64 initialSlowPrice,
        uint32 initialFastVol,
        uint32 initialSlowVol,
        uint16 maxDeviationBps
    );

    /// @notice Emitted when an oracle is updated
    event AssetUpdated(
        bytes32 indexed oracleId,
        uint64 fastTWAP,
        uint64 slowTWAP,
        uint32 fastVolatility,
        uint32 slowVolatility,
        address indexed updater
    );

    /// @notice Emitted when multiple oracles are updated in a batch
    event BatchUpdated(
        bytes32[] oracleIds,
        address indexed updater
    );

    /// @notice Emitted when oracle-specific configuration is updated
    event AssetConfigUpdated(
        bytes32 indexed oracleId,
        uint16 maxDeviationBps
    );

    /// @notice Emitted when global oracle configuration is updated
    event GlobalConfigUpdated(
        uint32 minUpdateInterval,
        uint32 staleAfter
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

    // ========== ASSET MANAGEMENT VIEW FUNCTIONS ==========
    // These are external-oracle-specific (not in base IOracle)

    /// @notice Check if an address has oracle role (can update prices)
    /// @param account Address to check
    /// @return hasRole True if has oracle role
    function hasOracleRole(address account) external view returns (bool hasRole);

    /// @notice Get all registered oracle IDs
    /// @return oracleIds Array of registered oracle IDs
    function getRegisteredOracleIds() external view returns (bytes32[] memory oracleIds);

    /// @notice Get count of registered oracles
    /// @return count Number of oracles
    function getOracleCount() external view returns (uint256 count);

    /// @notice Check if oracle ID exists in this oracle
    /// @param oracleId Oracle identifier
    /// @return exists True if oracle is configured
    function oracleExists(bytes32 oracleId) external view returns (bool exists);

    // ========== ORACLE ROLE FUNCTIONS ==========

    /// @notice Update oracle data for a single oracle ID (oracle role only)
    /// @param oracleId Oracle identifier
    /// @param newFastTWAP New fast TWAP in b64 format
    /// @param newSlowTWAP New slow TWAP in b64 format
    /// @param newFastVol New fast volatility (1e6 base)
    /// @param newSlowVol New slow volatility (1e6 base)
    function updateOracle(
        bytes32 oracleId,
        uint64 newFastTWAP,
        uint64 newSlowTWAP,
        uint32 newFastVol,
        uint32 newSlowVol
    ) external;

    /// @notice Batch update oracle data for multiple oracle IDs (oracle role only)
    /// @param oracleIds Array of oracle identifiers
    /// @param fastTWAPs Array of fast TWAPs in b64 format
    /// @param slowTWAPs Array of slow TWAPs in b64 format
    /// @param fastVols Array of fast volatilities (1e6 base)
    /// @param slowVols Array of slow volatilities (1e6 base)
    function batchUpdateOracles(
        bytes32[] calldata oracleIds,
        uint64[] calldata fastTWAPs,
        uint64[] calldata slowTWAPs,
        uint32[] calldata fastVols,
        uint32[] calldata slowVols
    ) external;

    // ========== OWNER FUNCTIONS ==========

    /// @notice Add a new oracle pair (owner only)
    /// @param baseAsset Base asset address (asset being priced)
    /// @param quoteAsset Quote asset address (pricing currency)
    /// @param initialFastPrice Initial fast TWAP price (b64 format)
    /// @param initialSlowPrice Initial slow TWAP price (b64 format)
    /// @param initialFastVol Initial fast volatility (1e6 base)
    /// @param initialSlowVol Initial slow volatility (1e6 base)
    /// @param maxDeviationBps Max price change per update (e.g., 500 for 5%)
    function addOraclePair(
        address baseAsset,
        address quoteAsset,
        uint64 initialFastPrice,
        uint64 initialSlowPrice,
        uint32 initialFastVol,
        uint32 initialSlowVol,
        uint16 maxDeviationBps
    ) external;

    /// @notice Update oracle-specific configuration (owner only)
    /// @param oracleId Oracle identifier
    /// @param maxDeviationBps New maximum deviation in basis points
    function updateOracleConfig(
        bytes32 oracleId,
        uint16 maxDeviationBps
    ) external;

    /// @notice Update global oracle configuration (owner only)
    /// @param minUpdateInterval New minimum update interval in seconds
    /// @param staleAfter New staleness threshold in seconds
    function updateGlobalConfig(
        uint32 minUpdateInterval,
        uint32 staleAfter
    ) external;

    /// @notice Grant oracle role to an address (owner only)
    /// @param oracle Address to grant oracle role
    function grantOracleRole(address oracle) external;

    /// @notice Revoke oracle role from an address (owner only)
    /// @param oracle Address to revoke oracle role
    function revokeOracleRole(address oracle) external;
}
