// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IExternalOracle} from "../interfaces/IExternalOracle.sol";
import {BaseOracle} from "./BaseOracle.sol";
import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";

/// @title ExternalOracle
/// @notice Multi-asset external oracle for pushing off-chain price feeds
/// @dev Supports dual TWAP (fast/slow) and dual volatility (fast/slow) with role-based access control
/// @dev Extends BaseOracle and implements IExternalOracle for standardized oracle interface
contract ExternalOracle is BaseOracle, IExternalOracle, OwnableRoles {
    // ========== CONSTANTS ==========

    uint256 public constant ORACLE_ROLE = 1 << 0;  // bit 0: Can push prices

    // MAX_VOLATILITY and MAX_DEVIATION_BPS inherited from BaseOracle

    // ========== STORAGE ==========

    /// @notice Oracle data per oracle ID (base/quote pair)
    struct OracleEntryData {
        uint64 fastTWAP;           // Fast TWAP in b64 format
        uint64 slowTWAP;           // Slow TWAP in b64 format
        uint32 fastVolatility;     // Fast volatility (1e6 base)
        uint32 slowVolatility;     // Slow volatility (1e6 base)
        uint32 lastUpdate;         // Timestamp of last update
        uint16 maxDeviationBps;    // Maximum price deviation per update (basis points)
        bool exists;               // Whether this oracle entry is configured
    }

    /// @notice Global oracle configuration
    struct GlobalConfig {
        uint32 minUpdateInterval;  // Minimum seconds between updates (rate limit)
        uint32 staleAfter;         // Maximum age before oracle is considered stale
    }

    /// @notice Oracle data by oracleId = keccak256(abi.encodePacked(baseAsset, quoteAsset))
    mapping(bytes32 => OracleEntryData) public oracleData;

    /// @notice Registered oracle IDs list
    bytes32[] public registeredOracleIds;

    /// @notice Global configuration
    GlobalConfig public config;

    // Events and errors are defined in IExternalOracle interface

    // ========== CONSTRUCTOR ==========

    /// @notice Initialize external oracle
    /// @param owner_ Owner address (can manage config and roles)
    /// @param oracle_ Initial oracle address (can push prices)
    /// @param minUpdateInterval_ Minimum seconds between updates (e.g., 60 for 1 minute)
    /// @param staleAfter_ Maximum age before stale (e.g., 172800 for 48 hours)
    constructor(
        address owner_,
        address oracle_,
        uint32 minUpdateInterval_,
        uint32 staleAfter_
    ) {
        if (owner_ == address(0) || oracle_ == address(0)) revert Unauthorized();

        // Set owner and grant oracle role
        _initializeOwner(owner_);
        _grantRoles(oracle_, ORACLE_ROLE);

        // Initialize global config
        config = GlobalConfig({
            minUpdateInterval: minUpdateInterval_,
            staleAfter: staleAfter_
        });

        emit GlobalConfigUpdated(minUpdateInterval_, staleAfter_);
    }

    // ========== OWNER FUNCTIONS ==========

    /// @notice Add a new oracle pair (base/quote)
    /// @param baseAsset Asset being priced
    /// @param quoteAsset Quote currency (pricing basis)
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
    ) external override onlyOwner {
        if (baseAsset == address(0) || quoteAsset == address(0)) revert ZeroAddress();
        if (initialFastPrice == 0 || initialSlowPrice == 0) revert ZeroPrice();
        if (initialFastVol > MAX_VOLATILITY || initialSlowVol > MAX_VOLATILITY) {
            revert InvalidVolatility();
        }
        if (maxDeviationBps > MAX_DEVIATION_BPS) revert InvalidDeviation();

        // Compute oracle ID
        bytes32 oracleId = keccak256(abi.encodePacked(baseAsset, quoteAsset));
        if (oracleData[oracleId].exists) revert AssetAlreadyExists();

        // Add oracle entry
        oracleData[oracleId] = OracleEntryData({
            fastTWAP: initialFastPrice,
            slowTWAP: initialSlowPrice,
            fastVolatility: initialFastVol,
            slowVolatility: initialSlowVol,
            lastUpdate: uint32(block.timestamp),
            maxDeviationBps: maxDeviationBps,
            exists: true
        });

        registeredOracleIds.push(oracleId);

        emit AssetAdded(
            oracleId,
            baseAsset,
            quoteAsset,
            initialFastPrice,
            initialSlowPrice,
            initialFastVol,
            initialSlowVol,
            maxDeviationBps
        );
    }

    /// @notice Update oracle pair configuration
    /// @param oracleId Oracle identifier
    /// @param maxDeviationBps New maximum deviation in basis points
    function updateOracleConfig(
        bytes32 oracleId,
        uint16 maxDeviationBps
    ) external override onlyOwner {
        if (!oracleData[oracleId].exists) revert AssetNotFound();
        if (maxDeviationBps > MAX_DEVIATION_BPS) revert InvalidDeviation();

        oracleData[oracleId].maxDeviationBps = maxDeviationBps;

        emit AssetConfigUpdated(oracleId, maxDeviationBps);
    }

    /// @notice Update global oracle configuration
    /// @param minUpdateInterval New minimum update interval
    /// @param staleAfter New staleness threshold
    function updateGlobalConfig(
        uint32 minUpdateInterval,
        uint32 staleAfter
    ) external override onlyOwner {
        config = GlobalConfig({
            minUpdateInterval: minUpdateInterval,
            staleAfter: staleAfter
        });

        emit GlobalConfigUpdated(minUpdateInterval, staleAfter);
    }

    /// @notice Grant oracle role to an address
    /// @param oracle Address to grant oracle role
    function grantOracleRole(address oracle) external override onlyOwner {
        if (oracle == address(0)) revert Unauthorized();
        _grantRoles(oracle, ORACLE_ROLE);
    }

    /// @notice Revoke oracle role from an address
    /// @param oracle Address to revoke oracle role
    function revokeOracleRole(address oracle) external override onlyOwner {
        _removeRoles(oracle, ORACLE_ROLE);
    }

    // ========== ORACLE ROLE FUNCTIONS ==========

    /// @notice Update oracle data for a single oracle pair (oracle role only)
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
    ) external override {
        if (!hasAnyRole(msg.sender, ORACLE_ROLE)) revert Unauthorized();

        _updateOracleInternal(oracleId, newFastTWAP, newSlowTWAP, newFastVol, newSlowVol);

        emit AssetUpdated(oracleId, newFastTWAP, newSlowTWAP, newFastVol, newSlowVol, msg.sender);
    }

    /// @notice Batch update oracle data for multiple oracle pairs (oracle role only)
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
    ) external override {
        if (!hasAnyRole(msg.sender, ORACLE_ROLE)) revert Unauthorized();

        uint256 length = oracleIds.length;
        if (
            length == 0 ||
            fastTWAPs.length != length ||
            slowTWAPs.length != length ||
            fastVols.length != length ||
            slowVols.length != length
        ) revert InvalidArrayLength();

        // Update all oracles
        for (uint256 i = 0; i < length; i++) {
            _updateOracleInternal(
                oracleIds[i],
                fastTWAPs[i],
                slowTWAPs[i],
                fastVols[i],
                slowVols[i]
            );
        }

        emit BatchUpdated(oracleIds, msg.sender);
    }

    /// @notice Internal function to update a single oracle
    function _updateOracleInternal(
        bytes32 oracleId,
        uint64 newFastTWAP,
        uint64 newSlowTWAP,
        uint32 newFastVol,
        uint32 newSlowVol
    ) internal {
        OracleEntryData storage oracle = oracleData[oracleId];

        if (!oracle.exists) revert AssetNotFound();
        if (newFastTWAP == 0 || newSlowTWAP == 0) revert ZeroPrice();
        if (newFastVol > MAX_VOLATILITY || newSlowVol > MAX_VOLATILITY) {
            revert InvalidVolatility();
        }

        // Check minimum update interval (rate limit)
        if (block.timestamp < oracle.lastUpdate + config.minUpdateInterval) {
            revert UpdateTooFrequent();
        }

        // Validate price change for fast TWAP (primary price)
        if (oracle.fastTWAP > 0 && oracle.maxDeviationBps > 0) {
            uint256 oldPrice = M.decodePriceTo1e18(oracle.fastTWAP);
            uint256 newPrice = M.decodePriceTo1e18(newFastTWAP);

            uint256 priceDelta = newPrice > oldPrice
                ? newPrice - oldPrice
                : oldPrice - newPrice;

            uint256 maxChange = (oldPrice * oracle.maxDeviationBps) / 10000;

            if (priceDelta > maxChange) revert PriceChangeTooLarge();
        }

        // Update data
        oracle.fastTWAP = newFastTWAP;
        oracle.slowTWAP = newSlowTWAP;
        oracle.fastVolatility = newFastVol;
        oracle.slowVolatility = newSlowVol;
        oracle.lastUpdate = uint32(block.timestamp);
    }

    // ========== VIEW FUNCTIONS (IOracle-like per oracle ID) ==========

    /// @notice Get oracle data for a specific oracle ID
    /// @param oracleId Oracle identifier
    /// @return data Oracle data with fast/slow TWAPs, volatility, and timestamp
    function getOracleData(bytes32 oracleId) external view override returns (OracleData memory data) {
        OracleEntryData storage oracle = oracleData[oracleId];
        if (!oracle.exists) revert AssetNotFound();

        return OracleData({
            fastTWAP: oracle.fastTWAP,
            slowTWAP: oracle.slowTWAP,
            fastVolatility: oracle.fastVolatility,
            slowVolatility: oracle.slowVolatility,
            lastUpdate: oracle.lastUpdate
        });
    }

    /// @notice Check if oracle data is fresh
    /// @param oracleId Oracle identifier
    /// @param maxAge Maximum acceptable age in seconds
    /// @return isFresh True if data is fresh
    function isFresh(bytes32 oracleId, uint32 maxAge) external view override returns (bool) {
        OracleEntryData storage oracle = oracleData[oracleId];
        if (!oracle.exists) return false;
        return block.timestamp - oracle.lastUpdate <= maxAge;
    }

    /// @notice Check if oracle data is fresh using configured staleAfter
    /// @param oracleId Oracle identifier
    /// @return True if fresh, false if stale
    function isFreshDefault(bytes32 oracleId) external view returns (bool) {
        OracleEntryData storage oracle = oracleData[oracleId];
        if (!oracle.exists) return false;
        return block.timestamp - oracle.lastUpdate <= config.staleAfter;
    }

    /// @notice Get just the fast TWAP (most gas efficient)
    /// @param oracleId Oracle identifier
    /// @return fastTWAP Current fast TWAP in b64 format
    function getFastPrice(bytes32 oracleId) external view override returns (uint64 fastTWAP) {
        OracleEntryData storage oracle = oracleData[oracleId];
        if (!oracle.exists) revert AssetNotFound();
        return oracle.fastTWAP;
    }

    /// @notice Check if an address has oracle role
    /// @param account Address to check
    /// @return hasRole True if has oracle role
    function hasOracleRole(address account) external view override returns (bool hasRole) {
        return hasAnyRole(account, ORACLE_ROLE);
    }

    /// @notice Get all registered oracle IDs
    /// @return oracleIds Array of oracle identifiers
    function getRegisteredOracleIds() external view override returns (bytes32[] memory oracleIds) {
        return registeredOracleIds;
    }

    /// @notice Get count of registered oracle pairs
    /// @return count Number of oracle pairs
    function getOracleCount() external view override returns (uint256 count) {
        return registeredOracleIds.length;
    }

    /// @notice Check if oracle exists
    /// @param oracleId Oracle identifier
    /// @return exists True if oracle is configured
    function oracleExists(bytes32 oracleId) external view override returns (bool exists) {
        return oracleData[oracleId].exists;
    }
}
