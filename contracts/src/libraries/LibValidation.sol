// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IInternalOracle} from "../interfaces/IInternalOracle.sol";
import {LibStorage as S} from "./LibStorage.sol";
import {BAMMErrors as E} from "../bamm/BAMMErrors.sol";

/// @title LibValidation
/// @notice Common validation helpers to reduce code duplication
library LibValidation {
    // ========== VALIDATION CONSTANTS ==========

    /// @dev Maximum fee caps (hardcoded, no flexibility needed)
    uint256 internal constant MAX_SWAP_FEE_BPS = 100_000;      // 10% max swap fee
    uint256 internal constant MAX_DEPOSIT_FEE_BPS = 10_000;    // 1% max deposit fee
    uint256 internal constant MAX_WITHDRAWAL_FEE_BPS = 10_000; // 1% max withdrawal fee
    uint256 internal constant MAX_FLASH_FEE_BPS = 1_000;       // 0.1% max flash fee
    uint256 internal constant MAX_PROTOCOL_FEE_BPS = 50_000;   // 50% max protocol split

    /// @notice Validate asset is registered and return it
    /// @param token Token address
    /// @param assets Asset mapping
    /// @return asset Asset storage reference
    function requireAssetRegistered(
        address token,
        mapping(address => IBAMM.Asset) storage assets
    ) internal view returns (IBAMM.Asset storage asset) {
        asset = assets[token];
        if (asset.segmentCount == 0) revert E.AssetNotFound();
    }

    /// @notice Validate asset exists (has reserves) and return it
    /// @param token Token address
    /// @param assets Asset mapping
    /// @return asset Asset storage reference
    function requireAssetExists(
        address token,
        mapping(address => IBAMM.Asset) storage assets
    ) internal view returns (IBAMM.Asset storage asset) {
        asset = assets[token];
        if (asset.reserves == 0) revert E.AssetNotFound();
    }

    /// @notice Validate asset is registered and not frozen
    /// @param token Token address
    /// @param assets Asset mapping
    /// @return asset Asset storage reference
    function requireAssetActive(
        address token,
        mapping(address => IBAMM.Asset) storage assets,
        mapping(address => IBAMM.RiskConfig) storage riskConfigs
    ) internal view returns (IBAMM.Asset storage asset) {
        asset = assets[token];
        if (asset.segmentCount == 0) revert E.AssetNotFound();
        if (S._isFrozen(riskConfigs[token])) revert E.AssetFrozen();
    }

    /// @notice Validate oracle exists and is fresh
    /// @param oracle Oracle entry
    /// @param maxAge Maximum acceptable age in seconds
    function requireOracleFresh(
        IInternalOracle.InternalFeedData storage oracle,
        uint32 maxAge
    ) internal view {
        if (oracle.base.updatedAt == 0) revert E.InvalidParameter();
        if (block.timestamp - oracle.base.updatedAt > maxAge) {
            revert E.OracleStale();
        }
    }

    /// @notice Validate oracle exists or has fallback
    /// @param oracle Main oracle entry
    /// @param oracleConfig Oracle configuration with potential fallback
    function requireOracleOrFallback(
        IInternalOracle.InternalFeedData storage oracle,
        IBAMM.OracleConfig storage oracleConfig
    ) internal view {
        // staleAfter is returned by oracle itself (dynamic), use reasonable default
        bool mainStale = block.timestamp - oracle.base.updatedAt > 24 hours;
        if (mainStale && oracleConfig.fallbackOracle == address(0)) {
            revert E.OracleStale();
        }
    }

    /// @notice Validate blacklist status
    /// @param addr Address to check
    /// @param blacklist Blacklist mapping
    function requireNotBlacklisted(
        address addr,
        mapping(address => bool) storage blacklist
    ) internal view {
        if (blacklist[addr]) revert E.Blacklisted();
    }

    /// @notice Validate fee bounds
    /// @param minFeeBps Minimum fee
    /// @param maxFeeBps Maximum fee
    /// @param precision Basis point precision (e.g., 10000)
    function requireValidFeeBounds(
        uint16 minFeeBps,
        uint16 maxFeeBps,
        uint16 precision
    ) internal pure {
        if (minFeeBps > maxFeeBps) revert E.InvalidParameter();
        if (maxFeeBps > precision) revert E.InvalidParameter();
    }

    /// @notice Validate liquidity is sufficient
    /// @param reserves Current reserves
    /// @param minLiquidity Minimum required
    function requireSufficientLiquidity(
        uint128 reserves,
        uint96 minLiquidity
    ) internal pure {
        if (reserves < minLiquidity) revert E.BelowMinimumLiquidity();
    }
}
