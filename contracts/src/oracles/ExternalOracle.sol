// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IExternalOracle} from "../interfaces/IExternalOracle.sol";
import {BaseOracle} from "./BaseOracle.sol";
import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";
import {LibUtils} from "../libraries/LibUtils.sol";

/// @title ExternalOracle
/// @notice Multi-asset external oracle for pushing off-chain price feeds
/// @dev Supports dual TWAP (fast/slow) and dual volatility (fast/slow) with role-based access control
/// @dev Extends BaseOracle and implements IExternalOracle for standardized oracle interface
contract ExternalOracle is BaseOracle, IExternalOracle, OwnableRoles {
    // ========== CONSTANTS ==========

    uint256 public constant ORACLE_ROLE = 1 << 0;  // bit 0: Can push prices

    // MAX_VOLATILITY and MAX_DEVIATION_BPS inherited from BaseOracle

    // ========== STORAGE ==========

    /// @notice Oracle data by feedId = keccak256(abi.encodePacked(baseAsset, quoteAsset))
    /// @dev Uses IOracle.FeedData for single-slot storage efficiency (32 bytes, fully packed)
    ///      FeedData.maxDeviation: Deviation threshold triggering update (0.0001% precision: 10_000 = 1%)
    ///      FeedData.ttl: Per-feed staleness threshold (no global config)
    ///      Feed existence check: feedData.updatedAt != 0
    mapping(bytes32 => FeedData) public oracleData;

    /// @notice Registered feed IDs list
    bytes32[] public registeredOracleIds;

    // Events and errors are defined in IExternalOracle interface

    // ========== CONSTRUCTOR ==========

    /// @notice Initialize external oracle
    /// @param owner_ Owner address (can manage config and roles)
    /// @param oracle_ Initial oracle address (can push prices)
    constructor(
        address owner_,
        address oracle_
    ) {
        LibUtils.requireNonZero(owner_);
        LibUtils.requireNonZero(oracle_);

        // Set owner and grant oracle role
        _initializeOwner(owner_);
        _grantRoles(oracle_, ORACLE_ROLE);
    }

    // ========== OWNER FUNCTIONS ==========

    /// @notice Add a new oracle pair (base/quote)
    /// @param baseAsset Asset being priced
    /// @param quoteAsset Quote currency (pricing basis)
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
    ) external override onlyOwner {
        LibUtils.requireNonZero(baseAsset);
        LibUtils.requireNonZero(quoteAsset);
        if (fastEMA == 0 || slowEMA == 0) revert ZeroPrice();
        if (fastVolEMAEMA > MAX_VOLATILITY || slowVolEMAEMA > MAX_VOLATILITY) {
            revert InvalidVolatility();
        }
        if (maxDeviation > MAX_DEV_THRESHOLD) revert InvalidDeviation();
        if (ttl == 0) revert InvalidParameter();

        // Compute feed ID
        bytes32 feedId = keccak256(abi.encodePacked(baseAsset, quoteAsset));
        if (oracleData[feedId].updatedAt != 0) revert AssetAlreadyExists();

        // Add oracle entry (single-slot write)
        oracleData[feedId] = FeedData({
            fastEMA: fastEMA,
            slowEMA: slowEMA,
            fastVolEMA: fastVolEMAEMA,
            slowVolEMA: slowVolEMAEMA,
            updatedAt: uint32(block.timestamp),
            maxDeviation: maxDeviation,
            ttl: ttl
        });

        registeredOracleIds.push(feedId);

        emit AssetAdded(
            feedId,
            baseAsset,
            quoteAsset,
            fastEMA,
            slowEMA,
            fastVolEMAEMA,
            slowVolEMAEMA,
            maxDeviation
        );
    }

    /// @notice Update oracle pair configuration
    /// @param feedId Oracle identifier
    /// @param maxDeviation New deviation threshold (0.0001% precision: 10_000 = 1%, max 65_000 = 6.5%)
    /// @param ttl New time-to-live in seconds
    function updateOracleConfig(
        bytes32 feedId,
        uint16 maxDeviation,
        uint16 ttl
    ) external override onlyOwner {
        if (oracleData[feedId].updatedAt == 0) revert AssetNotFound();
        if (maxDeviation > MAX_DEV_THRESHOLD) revert InvalidDeviation();
        if (ttl == 0) revert InvalidParameter();

        oracleData[feedId].maxDeviation = maxDeviation;
        oracleData[feedId].ttl = ttl;

        emit AssetConfigUpdated(feedId, maxDeviation);
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
    ) external override {
        if (!hasAnyRole(msg.sender, ORACLE_ROLE)) revert Unauthorized();

        _updateOracleInternal(feedId, newFastEMA, newSlowEMA, newFastVolEMA, newSlowVolEMA);

        emit AssetUpdated(feedId, newFastEMA, newSlowEMA, newFastVolEMA, newSlowVolEMA, msg.sender);
    }

    /// @notice Batch update oracle data for multiple oracle pairs (oracle role only)
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
    ) external override {
        if (!hasAnyRole(msg.sender, ORACLE_ROLE)) revert Unauthorized();

        uint256 length = feedIds.length;
        if (
            length == 0 ||
            fastEMAs.length != length ||
            slowEMAs.length != length ||
            fastVolEMAs.length != length ||
            slowVolEMAs.length != length
        ) revert InvalidArrayLength();

        // Update all oracles
        for (uint256 i = 0; i < length; i++) {
            _updateOracleInternal(
                feedIds[i],
                fastEMAs[i],
                slowEMAs[i],
                fastVolEMAs[i],
                slowVolEMAs[i]
            );
        }

        emit BatchUpdated(feedIds, msg.sender);
    }

    /// @notice Internal function to update a single oracle
    function _updateOracleInternal(
        bytes32 feedId,
        uint64 newFastEMA,
        uint64 newSlowEMA,
        uint32 newFastVolEMA,
        uint32 newSlowVolEMA
    ) internal {
        FeedData storage feed = oracleData[feedId];

        if (feed.updatedAt == 0) revert AssetNotFound();
        if (newFastEMA == 0 || newSlowEMA == 0) revert ZeroPrice();
        if (newFastVolEMA > MAX_VOLATILITY || newSlowVolEMA > MAX_VOLATILITY) {
            revert InvalidVolatility();
        }

        // Validate price change for fast EMA (primary price)
        // maxDeviation uses 0.0001% precision: 10_000 = 1%
        if (feed.fastEMA > 0 && feed.maxDeviation > 0) {
            uint256 oldPrice = M.decodePriceTo1e18(feed.fastEMA);
            uint256 newPrice = M.decodePriceTo1e18(newFastEMA);

            uint256 priceDelta = newPrice > oldPrice
                ? newPrice - oldPrice
                : oldPrice - newPrice;

            uint256 maxChange = (oldPrice * feed.maxDeviation) / DEV_THRESHOLD_PRECISION;

            if (priceDelta > maxChange) revert PriceChangeTooLarge();
        }

        // Update data (single SSTORE - all fields packed in one 256-bit slot)
        feed.fastEMA = newFastEMA;
        feed.slowEMA = newSlowEMA;
        feed.fastVolEMA = newFastVolEMA;
        feed.slowVolEMA = newSlowVolEMA;
        feed.updatedAt = uint32(block.timestamp);
    }

    // ========== VIEW FUNCTIONS (IOracle-like per feed ID) ==========

    /// @notice Get oracle data for a specific feed ID
    /// @param feedId Oracle identifier
    /// @return data Oracle data with fast/slow TWAPs, volatility, and timestamp
    function getFeedData(bytes32 feedId) external view override returns (FeedData memory data) {
        FeedData storage feed = oracleData[feedId];
        if (feed.updatedAt == 0) revert AssetNotFound();

        return feed;
    }

    /// @notice Check if oracle data is fresh against custom max age
    /// @param feedId Oracle identifier
    /// @param maxAge Maximum acceptable age in seconds
    /// @return True if data is fresh
    function isFresh(bytes32 feedId, uint32 maxAge) external view override returns (bool) {
        FeedData storage feed = oracleData[feedId];
        if (feed.updatedAt == 0) return false;
        return block.timestamp - feed.updatedAt <= maxAge;
    }

    /// @notice Check if oracle data is fresh using feed's configured TTL
    /// @dev ALWAYS uses FeedData.ttl (no external config)
    /// @param feedId Oracle identifier
    /// @return True if fresh, false if stale
    function isFreshDefault(bytes32 feedId) external view override returns (bool) {
        FeedData storage feed = oracleData[feedId];
        if (feed.updatedAt == 0) return false;
        return block.timestamp - feed.updatedAt <= feed.ttl;
    }

    /// @notice Get just the fast price EMA (most gas efficient)
    /// @param feedId Oracle identifier
    /// @return fastEMA Current fast EMA in b64 format
    function getFastPrice(bytes32 feedId) external view override returns (uint64 fastEMA) {
        FeedData storage feed = oracleData[feedId];
        if (feed.updatedAt == 0) revert AssetNotFound();
        return feed.fastEMA;
    }

    /// @notice Check if an address has oracle role
    /// @param account Address to check
    /// @return hasRole True if has oracle role
    function hasOracleRole(address account) external view override returns (bool hasRole) {
        return hasAnyRole(account, ORACLE_ROLE);
    }

    /// @notice Get all registered feed IDs
    /// @return feedIds Array of oracle identifiers
    function getRegisteredOracleIds() external view override returns (bytes32[] memory feedIds) {
        return registeredOracleIds;
    }

    /// @notice Get count of registered oracle pairs
    /// @return count Number of oracle pairs
    function getOracleCount() external view override returns (uint256 count) {
        return registeredOracleIds.length;
    }

    /// @notice Check if oracle exists
    /// @param feedId Oracle identifier
    /// @return exists True if oracle is configured
    function oracleExists(bytes32 feedId) external view override returns (bool exists) {
        return oracleData[feedId].updatedAt != 0;
    }
}
