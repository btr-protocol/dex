// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IBAMMHooks} from "../interfaces/IBAMMHooks.sol";
import {IERC165} from "../interfaces/IERC165.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {BAMMErrors as E} from "./BAMMEvents.sol";
import {BAMMEvents as Events} from "./BAMMEvents.sol";
import {Rescuable} from "../utils/Rescuable.sol";
import {LibPricing as P} from "../libraries/LibPricing.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";
import {LibStorage} from "../libraries/LibStorage.sol";
import {LibUtils} from "../libraries/LibUtils.sol";

/// @title BAMMManagement
/// @notice Management functions for BAMM - access control, initialization, asset management, pausing, freezing, blacklisting, etc.
abstract contract BAMMManagement is IBAMM, Initializable, ReentrancyGuard, OwnableRoles, Rescuable {
    using SafeTransferLib for address;

    // ========== ROLE CONSTANTS ==========
    // OwnableRoles uses uint256 bit flags for roles

    uint256 public constant GUARDIAN_ROLE = 1 << 0;  // bit 0
    uint256 public constant TREASURY_ROLE = 1 << 1;  // bit 1
    uint256 public constant KEEPER_ROLE = 1 << 2;    // bit 2

    // ========== STORAGE ACCESS (must be implemented by child) ==========

    /// @notice Get full storage struct (implemented by BAMM)
    function _s() internal pure virtual returns (LibStorage.BAMMStorage storage);

    /// @notice Get asset storage for given token (virtual - implemented by child)
    function _getAsset(address token) internal view virtual returns (IBAMM.Asset storage);

    /// @notice Get all registered assets (virtual - returns array copy)
    function _getRegisteredAssets() internal view virtual returns (address[] memory) {
        return _s().registeredAssets;
    }

    /// @notice Set TWAP weights
    function _setTWAPWeights(uint8 fastWeight, uint8 slowWeight) internal {
        LibStorage.BAMMStorage storage $ = _s();
        $.fastTWAPWeight = fastWeight;
        $.slowTWAPWeight = slowWeight;
    }

    /// @notice Get fast TWAP for asset (helper for circuit breakers and base asset updates)
    function _getFastTWAP(IBAMM.Asset storage asset) internal view virtual returns (uint64);


    /// @notice Get token decimals
    function _getDecimals(address token) internal view virtual returns (uint8);

    /// @notice Read oracle or revert (from InternalOracle)
    function _readOracleOrRevert(address mainOracle, address fallbackOracle) internal view virtual returns (uint64 fastTWAP, uint64 slowTWAP, uint32 fastVol, uint32 slowVol);

    /// @notice Update oracle internal (from InternalOracle) - implemented by child
    function _updateOracleInternal(address token, uint64 newPrice, uint32 newVolatility) internal virtual;

    /// @notice Update oracle config internal (from InternalOracle) - implemented by child
    function _updateOracleConfigInternal(address token, address mainOracle, address fallbackOracle) internal virtual;

    // ========== MODIFIERS ==========

    modifier notPaused() {
        LibUtils.requireNotPaused(_s().isPoolPaused);
        _;
    }

    modifier onlyGuardianRole() {
        _checkRoles(GUARDIAN_ROLE);
        _;
    }

    modifier onlyTreasuryRole() {
        _checkRoles(TREASURY_ROLE);
        _;
    }

    modifier onlyKeeperRole() {
        _checkRoles(KEEPER_ROLE);
        _;
    }

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner() && !hasAnyRole(msg.sender, GUARDIAN_ROLE)) {
            revert E.Unauthorized();
        }
        _;
    }

    // ========== ROLE MANAGEMENT ==========
    // Role management is handled by OwnableRoles from Solady
    // Exposing these functions for backward compatibility

    /// @notice Grant a role to an account
    /// @param role Role to grant (use role constants)
    /// @param account Address to grant role to
    function grantRole(uint256 role, address account) external onlyOwner {
        _grantRoles(account, role);
    }

    /// @notice Revoke a role from an account
    /// @param role Role to revoke
    /// @param account Address to revoke role from
    function revokeRole(uint256 role, address account) external onlyOwner {
        _removeRoles(account, role);
    }

    /// @notice Check if an account has a specific role
    /// @param role Role to check
    /// @param account Address to check
    /// @return True if account has the role
    function hasRole(uint256 role, address account) public view returns (bool) {
        return hasAnyRole(account, role);
    }

    /// @notice Get the admin/owner address
    /// @return The owner address
    function admin() public view virtual returns (address) {
        return owner();
    }

    // ========== ASSET RECOVERY ==========

    /// @notice Request emergency asset recovery
    /// @dev 4-day timelock + 3-day acceptance window
    ///      Snapshots balance at request time for predictability
    /// @param token Token to rescue (address(0) for ETH)
    /// @param amount Amount to rescue (0 = snapshot entire balance)
    /// @param receiver Destination address (address(0) = defaults to msg.sender)
    function requestRescue(
        address token,
        uint256 amount,
        address receiver
    ) external onlyOwner {
        _requestRescue(token, amount, receiver);
    }

    /// @notice Execute rescue after timelock expires
    function executeRescue() external onlyOwner {
        _executeRescue();
    }

    /// @notice Cancel a pending rescue request
    function cancelRescue() external onlyOwner {
        _cancelRescue();
    }

    // ========== FEE PARAMETER MANAGEMENT (TRI-FACTOR MODEL) ==========

    /// @notice Update inventory factor parameters (coverage-based ALM)
    function updateInventoryParams(
        uint16 _invMinMult,
        uint16 _invMaxMult,
        uint16 _invMaxDivergence
    ) external onlyOwner {
        P.FeeParams storage fp = _s().feeParams;
        fp.invMinMult = _invMinMult;
        fp.invMaxMult = _invMaxMult;
        fp.invMaxDivergence = _invMaxDivergence;
    }

    /// @notice Update baseline volatility parameters (unified for breadth + fees)
    function updateBaselineVolatilityParams(
        uint16 _volWeight,
        uint32 _volFloor,
        uint32 _volMax,
        uint16 _breadthShockKappa
    ) external onlyOwner {
        P.FeeParams storage fp = _s().feeParams;
        fp.volWeight = _volWeight;
        fp.volFloor = _volFloor;
        fp.volMax = _volMax;
        fp.breadthShockKappa = _breadthShockKappa;
    }

    /// @notice Update volatility shock factor parameters
    function updateVolatilityParams(
        uint16 _volBeta,
        uint16 _volRMax,
        uint16 _volMaxMult,
        uint16 _volEpsilon
    ) external onlyOwner {
        P.FeeParams storage fp = _s().feeParams;
        fp.volBeta = _volBeta;
        fp.volRMax = _volRMax;
        fp.volMaxMult = _volMaxMult;
        fp.volEpsilon = _volEpsilon;
    }

    /// @notice Update price divergence factor parameters
    function updateDivergenceParams(
        uint16 _pdD1Max,
        uint16 _pdD2Max,
        uint16 _pdAlpha,
        uint16 _pdMaxMult
    ) external onlyOwner {
        P.FeeParams storage fp = _s().feeParams;
        fp.pdD1Max = _pdD1Max;
        fp.pdD2Max = _pdD2Max;
        fp.pdAlpha = _pdAlpha;
        fp.pdMaxMult = _pdMaxMult;
    }

    /// @notice Update base fee parameters (vol-aware)
    function updateBaseFeeParams(
        uint16 _baseK,
        uint16 _baseMin,
        uint16 _baseMax
    ) external onlyOwner {
        P.FeeParams storage fp = _s().feeParams;
        fp.baseK = _baseK;
        fp.baseMin = _baseMin;
        fp.baseMax = _baseMax;
    }

    /// @notice Update global fee multiplier caps and legacy params
    function updateGlobalFeeParams(
        uint16 _minMult,
        uint16 _maxMult,
        uint16 _maxTWAPChange,
        uint16 _protocolFeeBps,
        uint16 _withdrawalFeeBps
    ) external onlyOwner {
        if (_protocolFeeBps > M.BPS_PRECISION) revert E.InvalidParameter();
        P.FeeParams storage fp = _s().feeParams;
        fp.minMult = _minMult;
        fp.maxMult = _maxMult;
        fp.maxTWAPChange = _maxTWAPChange;
        fp.protocolFeeBps = _protocolFeeBps;
        fp.withdrawalFeeBps = _withdrawalFeeBps;
    }

    function getFeeParams() external view returns (P.FeeParams memory) {
        return _s().feeParams;
    }

    /// @notice Update volatility EMA weights
    /// @dev Admin only. Weights represent percentage of old value in volatility EMA calculation.
    /// @dev NOTE: Price TWAPs now use accumulator (Uniswap V3 style), these weights only affect volatility smoothing
    /// @param _fastWeight Weight for fast volatility (0-100, e.g., 90 = 90% old, 10% new)
    /// @param _slowWeight Weight for slow volatility (0-100, e.g., 95 = 95% old, 5% new)
    /// Conversion from half-life (h) to weight (w): w = 100 * 0.5^(1/h)
    /// Examples: h=7 → w≈90, h=14 → w≈95, h=10 → w≈93
    function updateVolatilityWeights(uint8 _fastWeight, uint8 _slowWeight) external onlyOwner {
        if (_fastWeight > 100 || _slowWeight > 100) revert E.InvalidParameter();
        if (_fastWeight >= _slowWeight) revert E.InvalidParameter();  // Fast must be more responsive than slow

        _setTWAPWeights(_fastWeight, _slowWeight);

        emit Events.VolatilityWeightsUpdated(_fastWeight, _slowWeight);
    }

    function getVolatilityWeights() external view returns (uint8 fastWeight, uint8 slowWeight) {
        LibStorage.BAMMStorage storage $ = _s();
        return ($.fastTWAPWeight, $.slowTWAPWeight);
    }

    function getProtocolFees(address token) external view returns (uint256) {
        return _s().protocolFees[token];
    }

    // ========== POOL PAUSE/UNPAUSE ==========

    function pausePool() external onlyOwner {
        LibStorage.BAMMStorage storage $ = _s(); // Cache once
        // No-op guard: skip if already paused to save gas
        if ($.isPoolPaused) return;

        $.isPoolPaused = true;
        emit Events.PoolPaused();
    }

    function unpausePool() external onlyOwner {
        LibStorage.BAMMStorage storage $ = _s(); // Cache once
        // No-op guard: skip if already unpaused to save gas
        if (!$.isPoolPaused) return;

        $.isPoolPaused = false;
        emit Events.PoolUnpaused();
    }

    // ========== ASSET FREEZE/UNFREEZE ==========

    function freezeAsset(address token, string calldata reason) external virtual override onlyOwnerOrGuardian {
        IBAMM.Asset storage asset = _getAsset(token);
        LibUtils.requireRegistered(asset);

        // No-op guard: skip if already frozen to save gas
        if (asset.isFrozen) return;

        asset.isFrozen = true;
        emit Events.AssetFrozen(token, reason);
    }

    function unfreezeAsset(address token) external virtual override onlyOwnerOrGuardian {
        IBAMM.Asset storage asset = _getAsset(token);
        LibUtils.requireRegistered(asset);

        // No-op guard: skip if already unfrozen to save gas
        if (!asset.isFrozen) return;

        asset.isFrozen = false;
        emit Events.AssetUnfrozen(token);
    }

    // ========== BLACKLIST MANAGEMENT ==========

    /// @notice Add address to blacklist (guardian role)
    /// @param account Address to blacklist
    function blacklistAddress(address account) external virtual override onlyGuardianRole {
        LibUtils.requireNonZero(account);
        LibStorage.BAMMStorage storage $ = _s(); // Cache once

        if (!$.blacklisted[account]) {
            $.blacklisted[account] = true;
            emit Events.AddressBlacklisted(account);
        }
    }

    /// @notice Remove address from blacklist (admin or guardian)
    /// @param account Address to remove from blacklist
    function removeFromBlacklist(address account) external virtual override onlyOwnerOrGuardian {
        LibStorage.BAMMStorage storage $ = _s(); // Cache once

        if ($.blacklisted[account]) {
            $.blacklisted[account] = false;
            emit Events.AddressRemovedFromBlacklist(account);
        }
    }

    /// @notice Check if address is blacklisted
    /// @param account Address to check
    /// @return true if blacklisted
    function isBlacklisted(address account) external view virtual override returns (bool) {
        return _s().blacklisted[account];
    }

    // ========== HOOK MANAGEMENT ==========

    /// @notice Update hook contract for an asset
    /// @param token Asset token address
    /// @param hookAddress Hook contract address (address(0) = disabled)
    function updateHooks(
        address token,
        address hookAddress
    ) external virtual override onlyGuardianRole {
        IBAMM.Asset storage asset = _getAsset(token);
        if (asset.segmentCount == 0) revert E.AssetNotFound();

        // No-op guard: skip if address unchanged to save gas
        if (asset.hooks == hookAddress) return;

        // Validate hook contract if non-zero
        if (hookAddress != address(0)) {
            // Code-length check: reject EOAs early (caveat: constructor/selfdestruct edge cases)
            if (hookAddress.code.length == 0) revert E.InvalidParameter();

            // ERC-165 validation: verify contract implements IBAMMHooks interface
            // This is cheaper and clearer than probing each hook function individually
            try IERC165(hookAddress).supportsInterface(type(IBAMMHooks).interfaceId) returns (bool supported) {
                if (!supported) revert E.InvalidParameter();
            } catch {
                // Contract doesn't implement ERC-165 or reverts
                revert E.InvalidParameter();
            }
        }

        asset.hooks = hookAddress;

        emit Events.HooksUpdated(token, hookAddress);
    }

    /// @notice Get hook contract for an asset
    /// @param token Asset token address
    /// @return hookAddress Current hook contract address
    function getHooks(address token) external view virtual override returns (address hookAddress) {
        return _getAsset(token).hooks;
    }

    // ========== ORACLE MANAGEMENT ==========

    /// @notice Update oracle data for an asset (internal oracle only)
    /// @param token Token address
    /// @param newPrice New spot price in b64 format
    /// @param newVolatility New volatility measurement (base 1e6: 1_000_000 = 1%)
    /// @dev Updates accumulator and volatility EMAs
    function updateOracle(address token, uint64 newPrice, uint32 newVolatility) external virtual override onlyKeeperRole {
        _updateOracleInternal(token, newPrice, newVolatility);
    }

    /// @notice Update oracle configuration for an asset
    /// @param token Token address
    /// @param mainOracle Main oracle (address(this)=internal, else=external IOracle contract)
    /// @param fallbackOracle Fallback oracle (address(0)=disabled, address(this)=internal)
    function updateOracleConfig(
        address token,
        address mainOracle,
        address fallbackOracle
    ) external virtual override onlyGuardianRole {
        _updateOracleConfigInternal(token, mainOracle, fallbackOracle);
    }

    // ========== ASSET CONFIGURATION ==========

    /// @notice Start paginated base asset migration (STEP 1 of 3)
    /// @dev Initializes migration state without modifying prices
    /// @param newBaseToken New base token address
    function startBaseAssetUpdate(address newBaseToken) external onlyOwner {
        LibUtils.requireNonZero(newBaseToken);

        LibStorage.BAMMStorage storage $ = _s();
        LibStorage.BaseAssetMigration storage migration = $.baseAssetMigration;

        // Prevent starting new migration if one is in progress
        if (migration.inProgress) revert E.AlreadyInitialized();

        address oldBase = $.baseToken;

        // Short-circuit if new base equals current base
        if (newBaseToken == oldBase) revert E.InvalidParameter();

        IBAMM.Asset storage oldBaseAsset = _getAsset(oldBase);
        IBAMM.Asset storage newBaseAsset = _getAsset(newBaseToken);

        uint64 oldBaseFastTWAP = _getFastTWAP(oldBaseAsset);
        uint64 newBaseFastTWAP = _getFastTWAP(newBaseAsset);

        if (oldBaseFastTWAP == 0 || newBaseFastTWAP == 0) revert E.InvalidPrice();

        // Calculate conversion rate with fullMulDiv for precision
        uint256 conversionRate = FixedPointMathLib.fullMulDiv(
            uint256(oldBaseFastTWAP),
            M.PRICE_PRECISION,
            uint256(newBaseFastTWAP)
        );

        // Initialize migration state
        migration.newBase = newBaseToken;
        migration.oldBase = oldBase;
        migration.conversionRate = conversionRate;
        migration.nextIndex = 0;
        migration.totalAssets = $.registeredAssets.length;
        migration.inProgress = true;
        migration.startedAt = block.timestamp;

        emit Events.BaseAssetUpdated(oldBase, newBaseToken);
    }

    /// @notice Process batch of asset price conversions (STEP 2 of 3, call repeatedly)
    /// @dev Processes up to batchSize assets, can be called multiple times
    /// @param batchSize Number of assets to process in this batch (max 50 recommended)
    function updateAssetBatch(uint256 batchSize) external onlyOwner {
        LibStorage.BAMMStorage storage $ = _s();
        LibStorage.BaseAssetMigration storage migration = $.baseAssetMigration;

        if (!migration.inProgress) revert E.NotInitialized();
        if (batchSize == 0 || batchSize > 50) revert E.InvalidParameter();

        address[] memory assets = $.registeredAssets;
        uint256 startIdx = migration.nextIndex;
        uint256 endIdx = startIdx + batchSize;
        if (endIdx > assets.length) endIdx = assets.length;

        uint256 pricePrecision = M.PRICE_PRECISION;
        uint256 conversionRate = migration.conversionRate;

        unchecked {
            for (uint256 i = startIdx; i < endIdx; ++i) {
                address token = assets[i];
                if (token == migration.newBase) continue;

                IBAMM.Asset storage asset = _getAsset(token);

                // Skip assets with zero price
                if (asset.currentPrice == 0) continue;

                // Convert prices using fullMulDiv
                asset.currentPrice = uint64(FixedPointMathLib.fullMulDiv(
                    uint256(asset.currentPrice),
                    conversionRate,
                    pricePrecision
                ));

                asset.priceAccumulator = FixedPointMathLib.fullMulDiv(
                    asset.priceAccumulator,
                    conversionRate,
                    pricePrecision
                );

                asset.fastAccumSnapshot = FixedPointMathLib.fullMulDiv(
                    asset.fastAccumSnapshot,
                    conversionRate,
                    pricePrecision
                );

                asset.slowAccumSnapshot = FixedPointMathLib.fullMulDiv(
                    asset.slowAccumSnapshot,
                    conversionRate,
                    pricePrecision
                );
            }
        }

        migration.nextIndex = endIdx;
    }

    /// @notice Complete base asset migration (STEP 3 of 3)
    /// @dev Finalizes migration by updating baseToken and resetting migration state
    function finishBaseAssetUpdate() external onlyOwner {
        LibStorage.BAMMStorage storage $ = _s();
        LibStorage.BaseAssetMigration storage migration = $.baseAssetMigration;

        if (!migration.inProgress) revert E.NotInitialized();

        // Verify all assets have been processed
        if (migration.nextIndex < migration.totalAssets) revert E.InvalidParameter();

        // Set new base asset to 1.0 in new base terms
        IBAMM.Asset storage newBaseAsset = _getAsset(migration.newBase);
        newBaseAsset.currentPrice = uint64(M.PRICE_PRECISION);
        newBaseAsset.priceAccumulator = 0;
        newBaseAsset.fastAccumSnapshot = 0;
        newBaseAsset.slowAccumSnapshot = 0;

        // Update base token in storage
        $.baseToken = migration.newBase;

        // Clear migration state
        delete $.baseAssetMigration;
    }

    /// @notice Cancel an in-progress base asset migration
    /// @dev Admin can abort migration if needed
    function cancelBaseAssetUpdate() external onlyOwner {
        LibStorage.BAMMStorage storage $ = _s();
        if (!$.baseAssetMigration.inProgress) revert E.NotInitialized();

        delete $.baseAssetMigration;
    }

    /// @notice Legacy single-transaction base asset update (DEPRECATED - use paginated version)
    /// @dev WARNING: This function may fail with out-of-gas for pools with 50+ assets
    /// @dev DEPRECATED: Use startBaseAssetUpdate → updateAssetBatch → finishBaseAssetUpdate instead
    /// @param newBaseToken New base token address
    function updateBaseAsset(address newBaseToken) external onlyOwner {
        LibUtils.requireNonZero(newBaseToken);

        // Cache storage reference once
        LibStorage.BAMMStorage storage $ = _s();
        address oldBase = $.baseToken;

        // Short-circuit if new base equals current base to save gas
        if (newBaseToken == oldBase) return;
        address[] memory assets = $.registeredAssets;

        IBAMM.Asset storage oldBaseAsset = _getAsset(oldBase);
        IBAMM.Asset storage newBaseAsset = _getAsset(newBaseToken);

        uint64 oldBaseFastTWAP = _getFastTWAP(oldBaseAsset);
        uint64 newBaseFastTWAP = _getFastTWAP(newBaseAsset);

        if (oldBaseFastTWAP > 0 && newBaseFastTWAP > 0) {
            // Calculate conversion rate with fullMulDiv for precision
            // conversionRate = (oldBaseFastTWAP * PRICE_PRECISION) / newBaseFastTWAP
            uint256 conversionRate = FixedPointMathLib.fullMulDiv(
                uint256(oldBaseFastTWAP),
                M.PRICE_PRECISION,
                uint256(newBaseFastTWAP)
            );

            // Cache constants to stack to reduce repeated materialization
            uint256 pricePrecision = M.PRICE_PRECISION;

            uint256 length = assets.length;
            unchecked {
                for (uint256 i; i < length; ++i) {
                    address token = assets[i];
                    if (token == newBaseToken) continue;

                    IBAMM.Asset storage asset = _getAsset(token);

                    // Skip assets with zero price to avoid unnecessary writes
                    if (asset.currentPrice == 0) continue;

                    // Convert prices using fullMulDiv for precision and overflow safety
                    asset.currentPrice = uint64(FixedPointMathLib.fullMulDiv(
                        uint256(asset.currentPrice),
                        conversionRate,
                        pricePrecision
                    ));

                    asset.priceAccumulator = FixedPointMathLib.fullMulDiv(
                        asset.priceAccumulator,
                        conversionRate,
                        pricePrecision
                    );

                    asset.fastAccumSnapshot = FixedPointMathLib.fullMulDiv(
                        asset.fastAccumSnapshot,
                        conversionRate,
                        pricePrecision
                    );

                    asset.slowAccumSnapshot = FixedPointMathLib.fullMulDiv(
                        asset.slowAccumSnapshot,
                        conversionRate,
                        pricePrecision
                    );
                }
            }

            // Set new base asset to 1.0 in new base terms
            newBaseAsset.currentPrice = uint64(pricePrecision);
            newBaseAsset.priceAccumulator = 0;
            newBaseAsset.fastAccumSnapshot = 0;
            newBaseAsset.slowAccumSnapshot = 0;
        }

        // Update base token in storage
        $.baseToken = newBaseToken;

        emit Events.BaseAssetUpdated(oldBase, newBaseToken);
    }

    function updateCircuitBreaker(
        address token, address referenceAsset, uint16 maxDeviation
    ) external onlyOwner {
        IBAMM.Asset storage asset = _getAsset(token);
        LibUtils.requireRegistered(asset);
        if (referenceAsset != address(0)) {
            LibUtils.requireRegistered(_getAsset(referenceAsset));
        }

        IBAMM.CircuitBreaker storage breaker = _s().circuitBreakers[token];
        breaker.referenceAsset = referenceAsset;
        breaker.maxDeviation = maxDeviation;
    }

    function updateMinLiquidity(
        address token,
        uint128 newMinLiquidity
    ) external onlyOwner {
        IBAMM.Asset storage asset = _getAsset(token);
        LibUtils.requireRegistered(asset);

        uint128 oldMinLiquidity = asset.minLiquidity;
        asset.minLiquidity = newMinLiquidity;

        emit Events.MinLiquidityUpdated(token, oldMinLiquidity, newMinLiquidity);
    }

    function updateAssetFeeBounds(
        address token,
        uint16 minFeeBps,
        uint16 maxFeeBps
    ) external onlyOwner {
        IBAMM.Asset storage asset = _getAsset(token);
        LibUtils.requireRegistered(asset);
        if (minFeeBps > maxFeeBps || maxFeeBps > M.BPS_PRECISION) revert E.InvalidParameter();

        asset.minFeeBps = minFeeBps;
        asset.maxFeeBps = maxFeeBps;
    }

    // ========== CIRCUIT BREAKER ==========

    /// @notice Check and trigger circuit breaker if deviation exceeds threshold
    /// @dev CRITICAL FIX: Only freezes asset if deviation actually exceeds maxDeviation
    /// @dev Renamed from checkCircuitBreaker to triggerCircuitBreaker for clarity
    /// @param token Asset to check
    /// @return triggered True if circuit breaker was triggered and asset frozen
    function checkCircuitBreaker(address token) external virtual override onlyGuardianRole returns (bool triggered) {
        LibStorage.BAMMStorage storage $ = _s(); // Cache once
        IBAMM.CircuitBreaker storage breaker = $.circuitBreakers[token];

        // Exit early if no reference asset configured
        if (breaker.referenceAsset == address(0)) return false;

        IBAMM.Asset storage asset = _getAsset(token);
        IBAMM.Asset storage refAsset = _getAsset(breaker.referenceAsset);

        // SECURITY: Validate reference asset freshness to prevent griefing via stale oracle
        // Allow 1 hour staleness tolerance for reference asset
        if (block.timestamp > refAsset.lastOracleUpdate + 1 hours) {
            revert E.InvalidParameter(); // Stale reference oracle
        }

        // Calculate TWAPs once
        uint64 assetFastTWAP = _getFastTWAP(asset);
        uint64 refFastTWAP = _getFastTWAP(refAsset);

        // Guard against zero reference price
        if (refFastTWAP == 0) return false;

        // Calculate deviation in basis points
        int256 deviationBps = ((int256(uint256(assetFastTWAP)) - int256(uint256(refFastTWAP))) * 10000) /
                               int256(uint256(refFastTWAP));

        // Take absolute value for comparison
        uint256 absDeviationBps = deviationBps >= 0 ? uint256(deviationBps) : uint256(-deviationBps);

        // CRITICAL: Only freeze if threshold is exceeded
        if (absDeviationBps <= breaker.maxDeviation) return false;

        // Threshold exceeded - freeze asset
        asset.isFrozen = true;
        triggered = true;

        // If base asset circuit breaker triggered, freeze entire pool
        if (token == $.baseToken) {
            $.isPoolPaused = true;
            emit Events.PoolPaused();
        }

        // Emit structured event with threshold and measured deviation for monitoring
        emit Events.CircuitBreakerTriggered(token, deviationBps, block.timestamp);
        emit Events.AssetFrozen(token, "Circuit breaker");
    }

    // ========== TREASURY FUNCTIONS ==========

    /// @notice Collect accrued protocol fees
    /// @dev Only callable by treasury role
    /// @param tokens Array of token addresses to collect fees from
    function collectProtocolFees(address[] calldata tokens) external virtual override onlyTreasuryRole nonReentrant {
        LibStorage.BAMMStorage storage $ = _s(); // Cache once
        uint256 length = tokens.length;
        uint256[] memory amounts = new uint256[](length);

        unchecked {
            for (uint256 i; i < length; ++i) {
                address token = tokens[i];
                uint256 amount = $.protocolFees[token];

                if (amount > 0) {
                    // Reset protocol fee counter
                    $.protocolFees[token] = 0;
                    amounts[i] = amount;

                    // Transfer fees to treasury (msg.sender is treasury role holder)
                    token.safeTransfer(msg.sender, amount);
                }
            }
        }

        emit Events.ProtocolFeesCollected(msg.sender, tokens, amounts);
    }

    // ========== INITIALIZATION ==========

    /// @notice Initialize the BAMM with base asset and roles (Factory-compatible overload)
    /// @dev This overload accepts flat parameters from BAMMFactory.deployPool()
    /// @param _baseToken Base token address
    /// @param _baseMainOracle Main oracle for base asset
    /// @param _baseFallbackOracle Fallback oracle for base asset
    /// @param _baseMinLiquidity Minimum liquidity for base asset
    /// @param _admin Admin address
    /// @param _keeper Keeper address
    /// @param _treasury Treasury address (optional, defaults to admin)
    /// @param _baseFee Base fee in bps
    /// @param _maxFee Max fee in bps
    /// @param _withdrawalFee Withdrawal fee in bps
    /// @param _maxTWAPChange Max TWAP change in bps
    /// @param _protocolFeeBps Protocol fee in bps
    function initialize(
        address _baseToken,
        address _baseMainOracle,
        address _baseFallbackOracle,
        uint128 _baseMinLiquidity,
        address _admin,
        address _keeper,
        address _treasury,
        uint16 _baseFee,
        uint16 _maxFee,
        uint16 _withdrawalFee,
        uint16 _maxTWAPChange,
        uint16 _protocolFeeBps
    ) external initializer {
        // Construct structs from flat parameters
        IBAMM.LiquidityConfig memory liquidityConfig = IBAMM.LiquidityConfig({
            minLiquidity: _baseMinLiquidity,
            segmentCount: 8,  // Default 8 segments for base asset
            segmentWeights: [uint8(32), 32, 32, 32, 32, 32, 32, 31, 0, 0, 0, 0, 0, 0, 0, 0],  // Uniform distribution
            twapOffsets: [int8(-4), -3, -2, -1, 0, 1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0, 0],  // Symmetric offsets
            minBreadth: 5000,     // 0.005% min spread
            maxBreadth: 1000000   // 1% max spread
        });

        IBAMM.OracleConfig memory oracleConfig = IBAMM.OracleConfig({
            mainOracle: _baseMainOracle,
            fallbackOracle: _baseFallbackOracle,
            maxTWAPChange: _maxTWAPChange,
            fastWindow: 6 hours,
            slowWindow: 7 days,
            extension: abi.encode(_baseToken, uint64(100000000), uint32(0), uint32(0))  // Default: 1.0 price, 0 vol
        });

        IBAMM.FeeConfig memory feeConfig = IBAMM.FeeConfig({
            minFeeBps: _baseFee,
            maxFeeBps: _maxFee,
            protocolFeeBps: _protocolFeeBps,
            depositFeeBps: 0,
            withdrawalFeeBps: _withdrawalFee
        });

        // Call the main initialize function
        _initializeInternal(liquidityConfig, oracleConfig, feeConfig, _admin, _keeper, _treasury);
    }

    /// @notice Initialize the BAMM with base asset and roles (Struct-based interface)
    /// @param baseAssetConfig Configuration for the base asset
    /// @param baseOracleConfig Oracle configuration for the base asset
    /// @param baseFeeConfig Fee configuration for the base asset
    /// @param _admin Admin address
    /// @param _guardian Guardian address
    /// @param _treasury Treasury address (optional, defaults to admin)
    function initialize(
        IBAMM.LiquidityConfig calldata baseAssetConfig,
        IBAMM.OracleConfig calldata baseOracleConfig,
        IBAMM.FeeConfig calldata baseFeeConfig,
        address _admin,
        address _guardian,
        address _treasury
    ) external initializer {
        _initializeInternal(baseAssetConfig, baseOracleConfig, baseFeeConfig, _admin, _guardian, _treasury);
    }

    /// @notice Internal initialization logic (shared by both overloads)
    function _initializeInternal(
        IBAMM.LiquidityConfig memory baseAssetConfig,
        IBAMM.OracleConfig memory baseOracleConfig,
        IBAMM.FeeConfig memory baseFeeConfig,
        address _admin,
        address _guardian,
        address _treasury
    ) private {
        if (baseAssetConfig.minLiquidity == 0) revert E.InvalidParameter();
        LibUtils.requireNonZero(_admin);
        LibUtils.requireNonZero(_guardian);
        if (baseFeeConfig.protocolFeeBps > M.BPS_PRECISION) revert E.InvalidParameter();

        // Get token address from oracle config extension (first parameter)
        address baseToken;
        if (baseOracleConfig.extension.length >= 32) {
            baseToken = abi.decode(baseOracleConfig.extension, (address));
        } else {
            revert E.InvalidParameter();
        }

        LibUtils.requireNonZero(baseToken);

        LibStorage.BAMMStorage storage $ = _s(); // Cache once

        // Set base token
        $.baseToken = baseToken;

        // Initialize ownership (admin becomes owner)
        _initializeOwner(_admin);

        // Grant roles
        _grantRoles(_guardian, GUARDIAN_ROLE);

        // Default treasury to admin if not specified
        address treasuryAddr = _treasury == address(0) ? _admin : _treasury;
        _grantRoles(treasuryAddr, TREASURY_ROLE);

        // Initialize tri-factor fee parameters with sensible defaults
        P.FeeParams storage fp = $.feeParams;

        // Inventory factor (coverage-based ALM)
        fp.invMinMult = 20;          // 0.2x min rebate when under-collateralized
        fp.invMaxMult = 10000;       // 100x max penalty when over-collateralized
        fp.invMaxDivergence = 5000;  // 50% max divergence for full scale

        // Baseline volatility (unified for breadth + fees)
        fp.volWeight = 70;           // 0.7 weight for fast vol (70% fast + 30% slow)
        fp.volFloor = 100000;        // 0.1% minimum baseline volatility
        fp.volMax = 50000000;        // 50% maximum baseline volatility

        // Volatility shock factor
        fp.volBeta = 150;            // 1.5x sensitivity
        fp.volRMax = 1000;           // 10x max shock ratio
        fp.volMaxMult = 10000;       // 100x max multiplier
        fp.volEpsilon = 1000;        // 0.1% minimum volatility

        // Breadth shock (optional additive term)
        fp.breadthShockKappa = 0;    // Disabled by default (set 10 for 0.1 multiplier)

        // Price divergence factor
        fp.pdD1Max = 1000;           // 10% spot-vs-fast max
        fp.pdD2Max = 1500;           // 15% fast-vs-slow max
        fp.pdAlpha = 50;             // 0.5 weight for regime shift
        fp.pdMaxMult = 10000;        // 100x max multiplier

        // Base fee (vol-aware)
        fp.baseK = 100;              // 1.0 multiplier
        fp.baseMin = baseFeeConfig.minFeeBps;
        fp.baseMax = baseFeeConfig.maxFeeBps;

        // Global caps and legacy
        fp.minMult = 20;             // 0.2x global min (from inventory rebates)
        fp.maxMult = 10000;          // 100x global max
        fp.maxTWAPChange = baseOracleConfig.maxTWAPChange;
        fp.protocolFeeBps = baseFeeConfig.protocolFeeBps;
        fp.withdrawalFeeBps = baseFeeConfig.withdrawalFeeBps;

        // Initialize volatility EMA weights (default: fast=90, slow=95)
        $.fastTWAPWeight = 90;
        $.slowTWAPWeight = 95;

        // Add base asset using the standard addAsset flow
        // Create circuit breaker config (disabled by default for base asset)
        IBAMM.CircuitBreakerConfig memory cbConfig = IBAMM.CircuitBreakerConfig({
            referenceAsset: address(0),
            maxDeviationBps: 0
        });

        // Call internal addAsset
        _addAsset(baseToken, baseAssetConfig, baseOracleConfig, baseFeeConfig, cbConfig);

        emit Events.OwnershipTransferred(address(0), _admin);
    }

    // ========== ASSET MANAGEMENT ==========

    /// @notice Add new asset to the pool
    function addAsset(
        address token,
        IBAMM.LiquidityConfig calldata liquidityConfig,
        IBAMM.OracleConfig calldata oracleConfig,
        IBAMM.FeeConfig calldata feeConfig,
        IBAMM.CircuitBreakerConfig calldata circuitBreaker
    ) external onlyOwner {
        _addAsset(token, liquidityConfig, oracleConfig, feeConfig, circuitBreaker);
    }

    /// @notice Internal function to add an asset
    function _addAsset(
        address token,
        IBAMM.LiquidityConfig memory liquidityConfig,
        IBAMM.OracleConfig memory oracleConfig,
        IBAMM.FeeConfig memory feeConfig,
        IBAMM.CircuitBreakerConfig memory circuitBreaker
    ) internal {
        LibUtils.requireNonZero(token);

        // Default to internal-only oracle if not specified
        address mainOracle = oracleConfig.mainOracle == address(0) ? address(this) : oracleConfig.mainOracle;

        // Check if asset already exists
        IBAMM.Asset storage existingAsset = _getAsset(token);
        if (existingAsset.segmentCount > 0) revert E.AlreadyInitialized();

        // Validate liquidity config
        if (liquidityConfig.segmentCount < M.MIN_SEGMENTS || liquidityConfig.segmentCount > M.MAX_SEGMENTS) {
            revert E.InvalidParameter();
        }
        if (liquidityConfig.minBreadth == 0 || liquidityConfig.maxBreadth <= liquidityConfig.minBreadth) {
            revert E.InvalidParameter();
        }

        // Validate fee config
        if (feeConfig.minFeeBps > feeConfig.maxFeeBps || feeConfig.maxFeeBps > M.BPS_PRECISION) {
            revert E.InvalidParameter();
        }
        if (feeConfig.protocolFeeBps > M.BPS_PRECISION || feeConfig.depositFeeBps > M.BPS_PRECISION ||
            feeConfig.withdrawalFeeBps > M.BPS_PRECISION) {
            revert E.InvalidParameter();
        }

        // Validate oracle config
        if (oracleConfig.maxTWAPChange == 0 || oracleConfig.maxTWAPChange > M.BPS_PRECISION) {
            revert E.InvalidParameter();
        }

        uint8 decimals = _getDecimals(token);

        // Per-asset TWAP windows (default: 6 hours fast, 7 days slow)
        uint32 fastWindow = oracleConfig.fastWindow == 0 ? 6 hours : oracleConfig.fastWindow;
        uint32 slowWindow = oracleConfig.slowWindow == 0 ? 7 days : oracleConfig.slowWindow;

        // Initialize oracle data - MUST succeed, no fallback to dangerous defaults
        uint64 initialPrice;
        uint32 initialFastVol;
        uint32 initialSlowVol;

        if (mainOracle == address(this)) {
            // Internal oracle: decode currentPrice from extension parameter
            // extension format: abi.encode(uint64 currentPrice, uint32 fastVol, uint32 slowVol)
            if (oracleConfig.extension.length == 0) revert E.InvalidParameter();
            (initialPrice, initialFastVol, initialSlowVol) =
                abi.decode(oracleConfig.extension, (uint64, uint32, uint32));

            // Validate decoded values
            if (initialPrice == 0) revert E.InvalidPrice();
            if (initialFastVol > 100_000_000 || initialSlowVol > 100_000_000) revert E.InvalidParameter();
        } else {
            // External oracle: reading MUST succeed, use their fastTWAP as our starting price
            uint64 externalFastTWAP;
            uint64 externalSlowTWAP;  // ignored, we build our own TWAPs
            (externalFastTWAP, externalSlowTWAP, initialFastVol, initialSlowVol) =
                _readOracleOrRevert(mainOracle, oracleConfig.fallbackOracle);
            initialPrice = externalFastTWAP;  // Use external TWAP as starting point
        }

        // Get asset storage and initialize
        IBAMM.Asset storage asset = _getAsset(token);
        asset.reserves = 0;
        asset.minLiquidity = liquidityConfig.minLiquidity;
        asset.priceAccumulator = 0;
        asset.currentPrice = initialPrice;
        asset.fastAccumSnapshot = 0;
        asset.fastSnapshotTime = uint32(block.timestamp);
        asset.slowAccumSnapshot = 0;
        asset.slowSnapshotTime = uint32(block.timestamp);
        asset.fastWindow = fastWindow;
        asset.slowWindow = slowWindow;
        asset.fastVolatility = initialFastVol;
        asset.slowVolatility = initialSlowVol;
        asset.minFeeBps = feeConfig.minFeeBps;
        asset.maxFeeBps = feeConfig.maxFeeBps;
        asset.protocolFeeBps = feeConfig.protocolFeeBps;
        asset.depositFeeBps = feeConfig.depositFeeBps;
        asset.withdrawalFeeBps = feeConfig.withdrawalFeeBps;
        asset.maxTWAPChange = oracleConfig.maxTWAPChange;
        asset.segmentCount = liquidityConfig.segmentCount;
        asset.decimals = decimals;
        asset.isFrozen = false;
        asset.lastOracleUpdate = uint32(block.timestamp);
        asset.mainOracle = mainOracle;
        asset.fallbackOracle = oracleConfig.fallbackOracle;

        // Set liquidity profile
        _setLiquidityProfile(
            token,
            liquidityConfig.segmentCount,
            liquidityConfig.segmentWeights,
            liquidityConfig.twapOffsets,
            liquidityConfig.minBreadth,
            liquidityConfig.maxBreadth
        );

        LibStorage.BAMMStorage storage $ = _s();

        // Set circuit breaker
        IBAMM.CircuitBreaker storage breaker = $.circuitBreakers[token];
        breaker.referenceAsset = circuitBreaker.referenceAsset;
        breaker.maxDeviation = circuitBreaker.maxDeviationBps;

        // Initialize LP state
        IBAMM.LPState storage lpState = $.lpStates[token];
        lpState.liquidityIndex = uint128(M.PRECISION);

        // Register asset
        $.registeredAssets.push(token);

        emit Events.AssetAdded(token, liquidityConfig.minLiquidity);
    }

    // ========== LIQUIDITY PROFILE MANAGEMENT ==========

    /// @notice Update liquidity profile for an asset (public interface)
    function updateLiquidityProfile(
        address token,
        IBAMM.LiquidityProfileParams calldata profile
    ) external onlyGuardianRole {
        IBAMM.Asset storage asset = _getAsset(token);
        if (asset.segmentCount == 0) revert E.AssetNotFound();

        _setLiquidityProfile(
            token,
            asset.segmentCount,  // Keep existing segment count
            profile.segmentWeights,
            profile.twapOffsets,
            profile.minBreadth,
            profile.maxBreadth
        );

        emit Events.LiquidityProfileUpdated(token, asset.segmentCount);
    }

    /// @notice Internal function to set liquidity profile
    function _setLiquidityProfile(
        address token,
        uint8 segmentCount,
        uint8[16] memory weights,
        int8[17] memory offsets,
        uint64 minBreadth,
        uint64 maxBreadth
    ) internal {
        // Validate segment count bounds early to fail fast
        if (segmentCount < M.MIN_SEGMENTS || segmentCount > M.MAX_SEGMENTS) {
            revert E.InvalidParameter();
        }

        IBAMM.LiquidityProfile storage profile = _s().liquidityProfiles[token];

        // Normalize weights to sum to WEIGHT_SUM (255) with optimized single-pass computation
        uint256 totalWeight;
        unchecked {
            for (uint256 i; i < segmentCount; ++i) {
                uint256 w = weights[i];
                if (w == 0) revert E.InvalidParameter();
                totalWeight += w;
            }
        }
        if (totalWeight == 0) revert E.InvalidParameter();

        // Optimization: Use fullMulDiv for precise normalization with reduced rounding error
        // This avoids repeated divisions and applies normalization in one operation per weight
        unchecked {
            for (uint256 i; i < segmentCount; ++i) {
                // Use fullMulDiv: normalizedWeight = weights[i] * WEIGHT_SUM / totalWeight
                uint256 normalizedWeight = FixedPointMathLib.fullMulDiv(
                    uint256(weights[i]),
                    M.WEIGHT_SUM,
                    totalWeight
                );
                if (normalizedWeight > 255) revert E.Overflow();
                profile.segmentWeights[i] = uint8(normalizedWeight);
            }
        }

        // Validate and set offsets
        unchecked {
            for (uint256 i; i <= segmentCount; ++i) {
                int8 offset = offsets[i];
                if (offset < -100 || offset > 100) revert E.InvalidParameter();
                profile.twapOffsets[i] = offset;
            }
        }

        profile.minBreadth = minBreadth;
        profile.maxBreadth = maxBreadth;
    }

}
