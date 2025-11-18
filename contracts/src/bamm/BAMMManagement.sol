// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IInternalOracle} from "../interfaces/IInternalOracle.sol";
import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {LibStorage as S} from "../libraries/LibStorage.sol";
import {LibUtils} from "../libraries/LibUtils.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";
import {LibLiquiditySegments as SegLib} from "../libraries/LibLiquiditySegments.sol";
import {LibValidation as V} from "../libraries/LibValidation.sol";
import {BAMMStorage} from "./BAMMStorage.sol";
import {BAMMErrors as E} from "./BAMMErrors.sol";
import {Rescuable} from "../utils/Rescuable.sol";

/// @title BAMMManagement
/// @notice Ultra-lean management contract (<300 LOC, zero bloat)
/// @dev NO Optional structs, NO wrapper functions, NO string errors, hardcoded validation
abstract contract BAMMManagement is BAMMStorage, IBAMM, Initializable, ReentrancyGuard, OwnableRoles, Rescuable {
    // ========== PAUSE STORAGE (EIP-7201) ==========
    /// @dev keccak256(abi.encode(uint256(keccak256("bamm.pausable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PAUSABLE_SLOT = 0x58f2cb0e92b91e614ad1e64243011f8b8e2263e6c0e2a3b8c5857a3ce2e1e900;

    function _getPaused() internal view returns (bool paused) {
        assembly { paused := sload(PAUSABLE_SLOT) }
    }

    function _setPaused(bool paused) internal {
        assembly { sstore(PAUSABLE_SLOT, paused) }
    }

    function _requireNotPaused() internal view virtual {
        if (_getPaused()) revert E.PoolPaused();
    }

    // ========== ROLES ==========
    uint256 public constant GUARDIAN_ROLE = 1 << 0;
    uint256 public constant TREASURY_ROLE = 1 << 1;

    // ========== MODIFIERS ==========
    modifier whenNotPaused() {
        if (_getPaused()) revert E.PoolPaused();
        _;
    }

    modifier onlyGuardian() {
        if (!hasAnyRole(msg.sender, GUARDIAN_ROLE)) revert E.Unauthorized();
        _;
    }

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner() && !hasAnyRole(msg.sender, GUARDIAN_ROLE)) revert E.Unauthorized();
        _;
    }

    // ========== INITIALIZATION ==========

    function initialize(
        FeeConfig calldata /* baseFees */,
        OracleConfig calldata /* baseOracle */,
        RiskConfig calldata /* baseRisk */,
        LiquidtyConfig calldata /* baseProfile */,
        address owner_,
        address guardian_,
        address treasury_
    ) external initializer {
        LibUtils.requireNonZero(owner_);
        LibUtils.requireNonZero(guardian_);
        LibUtils.requireNonZero(treasury_);

        _initializeOwner(owner_);
        _grantRoles(guardian_, GUARDIAN_ROLE);
        _grantRoles(treasury_, TREASURY_ROLE);

        IBAMM.BAMMStorage storage $ = _sb();
        $.baseToken = address(this);  // Placeholder, set in addAsset

        // No global config needed - all per-asset
    }

    // ========== ASSET MANAGEMENT ==========

    function addAsset(
        address token,
        FeeConfig calldata fees,
        OracleConfig calldata oracle,
        RiskConfig calldata risk,
        LiquidtyConfig calldata profile
    ) external override onlyOwner {
        LibUtils.requireNonZero(token);

        IBAMM.BAMMStorage storage $ = _sb();
        Asset storage asset = $.assets[token];
        if (asset.decimals != 0) revert E.AssetAlreadyExists();

        // Validate fees (hardcoded caps from LibValidation)
        if (fees.minFeeBps > fees.maxFeeBps) revert E.InvalidParameter();
        if (fees.maxFeeBps > V.MAX_SWAP_FEE_BPS) revert E.InvalidParameter();
        if (fees.depositFeeBps > V.MAX_DEPOSIT_FEE_BPS) revert E.InvalidParameter();
        if (fees.withdrawalFeeBps > V.MAX_WITHDRAWAL_FEE_BPS) revert E.InvalidParameter();
        if (fees.flashFeeBps > V.MAX_FLASH_FEE_BPS) revert E.InvalidParameter();
        if (fees.protocolFeeBps > V.MAX_PROTOCOL_FEE_BPS) revert E.InvalidParameter();

        // Validate risk
        if (risk.minLiquidity == 0) revert E.InvalidParameter();
        if (risk.decayAmplification > 0 && risk.decaySlope == 0) revert E.InvalidParameter();

        // Validate profile
        if (profile.weights.length < 2 || profile.weights.length > 32) revert E.InvalidParameter();
        if (profile.weights.length != profile.endOffsets.length) revert E.InvalidParameter();
        if (profile.weights.length != profile.slopes.length) revert E.InvalidParameter();

        // Get decimals
        uint8 decimals = _getDecimals(token);

        // Initialize Asset (2 slots)
        asset.reserves = 0;
        asset.liabilities = 0;
        asset.fees = fees;
        asset.decimals = decimals;
        asset.segmentCount = uint8(profile.weights.length);

        // Initialize LPState (separate mapping)
        $.lpStates[token] = LPState({
            totalScaledSupply: 0,
            liquidityIndex: 1e18,
            decayStartTime: 0,
            coverageAtStart: 0,
            lastUpdateTime: 0
        });

        // Initialize cold storage (separate mappings)
        $.liquidityProfiles[token] = _buildLiquidityProfile(profile);
        $.riskConfigs[token] = risk;
        $.oracleConfigs[token] = oracle;

        // Initialize internal oracle if needed
        address mainOracle = oracle.mainOracle == address(0) ? address(this) : oracle.mainOracle;
        if (mainOracle == address(this) && oracle.extension.length > 0) {
            bytes32 feedId = keccak256(abi.encodePacked(token, $.baseToken));
            (uint64 price, uint32 fastVolEMA, uint32 slowVolEMA, uint16 maxChange, uint32 fastWin, uint32 slowWin) =
                abi.decode(oracle.extension, (uint64, uint32, uint32, uint16, uint32, uint32));

            // Initialize oracle entry directly
            uint32 now32 = uint32(block.timestamp);
            $.internalFeeds[feedId] = IInternalOracle.InternalFeedData({
                base: IOracle.FeedData({
                    fastEMA: price,
                    slowEMA: price,
                    fastVolEMA: fastVolEMA,
                    slowVolEMA: slowVolEMA,
                    updatedAt: now32,
                    maxDeviation: maxChange,
                    ttl: 3600  // 1 hour default TTL
                }),
                priceAccumulator: 0,
                fastAccumSnapshot: 0,
                slowAccumSnapshot: 0,
                currentPrice: price,
                fastSnapshotTime: now32,
                slowSnapshotTime: now32,
                fastWindow: uint24(fastWin),
                slowWindow: uint24(slowWin),
                maxTWAPChange: maxChange
            });
        }

        // Register asset
        $.registeredAssets.push(token);

        emit AssetAdded(token, risk.minLiquidity);
    }

    // ========== CONFIG UPDATES ==========

    function updateFeeConfig(address token, FeeConfig calldata fees) external override onlyOwner {
        Asset storage asset = _getAsset(token);
        if (asset.decimals == 0) revert E.AssetNotFound();

        // Validate (hardcoded caps)
        if (fees.minFeeBps > fees.maxFeeBps) revert E.InvalidParameter();
        if (fees.maxFeeBps > V.MAX_SWAP_FEE_BPS) revert E.InvalidParameter();
        if (fees.depositFeeBps > V.MAX_DEPOSIT_FEE_BPS) revert E.InvalidParameter();
        if (fees.withdrawalFeeBps > V.MAX_WITHDRAWAL_FEE_BPS) revert E.InvalidParameter();
        if (fees.flashFeeBps > V.MAX_FLASH_FEE_BPS) revert E.InvalidParameter();
        if (fees.protocolFeeBps > V.MAX_PROTOCOL_FEE_BPS) revert E.InvalidParameter();

        // Update hot storage
        asset.fees = fees;

        emit FeeConfigUpdated(token, fees);
    }

    function updateOracleConfig(address token, OracleConfig calldata oracle) external override onlyOwner {
        Asset storage asset = _getAsset(token);
        if (asset.decimals == 0) revert E.AssetNotFound();

        IBAMM.BAMMStorage storage $ = _sb();
        address mainOracle = oracle.mainOracle == address(0) ? address(this) : oracle.mainOracle;

        // Validate oracles have code (if external)
        if (mainOracle != address(this) && mainOracle.code.length == 0) revert E.InvalidParameter();
        if (oracle.fallbackOracle != address(0) && oracle.fallbackOracle != address(this) && oracle.fallbackOracle.code.length == 0) {
            revert E.InvalidParameter();
        }

        // Update Asset struct
        // Oracle config now stored in $.oracleConfigs[token]

        // Initialize internal oracle if extension provided
        if (mainOracle == address(this) && oracle.extension.length > 0) {
            bytes32 feedId = keccak256(abi.encodePacked(token, $.baseToken));
            (uint64 price, uint32 fastVolEMA, uint32 slowVolEMA, uint16 maxChange, uint32 fastWin, uint32 slowWin) =
                abi.decode(oracle.extension, (uint64, uint32, uint32, uint16, uint32, uint32));

            // Initialize oracle entry directly
            uint32 now32 = uint32(block.timestamp);
            $.internalFeeds[feedId] = IInternalOracle.InternalFeedData({
                base: IOracle.FeedData({
                    fastEMA: price,
                    slowEMA: price,
                    fastVolEMA: fastVolEMA,
                    slowVolEMA: slowVolEMA,
                    updatedAt: now32,
                    maxDeviation: maxChange,
                    ttl: 3600  // 1 hour default TTL
                }),
                priceAccumulator: 0,
                fastAccumSnapshot: 0,
                slowAccumSnapshot: 0,
                currentPrice: price,
                fastSnapshotTime: now32,
                slowSnapshotTime: now32,
                fastWindow: uint24(fastWin),
                slowWindow: uint24(slowWin),
                maxTWAPChange: maxChange
            });
        }

        emit OracleConfigUpdated(token, mainOracle, oracle.fallbackOracle);
    }

    function updateRiskConfig(address token, RiskConfig calldata risk) external override onlyOwner {
        Asset storage asset = _getAsset(token);
        if (asset.decimals == 0) revert E.AssetNotFound();

        // Validate
        if (risk.minLiquidity == 0) revert E.InvalidParameter();
        if (risk.decayAmplification > 0 && risk.decaySlope == 0) revert E.InvalidParameter();

        // Update RiskConfig storage
        _sb().riskConfigs[token] = risk;

        emit RiskConfigUpdated(token, risk);
    }

    function updateLiquidityProfile(address token, LiquidtyConfig calldata profile) external override {
        if (!hasAnyRole(msg.sender, GUARDIAN_ROLE) && msg.sender != owner()) revert E.Unauthorized();

        Asset storage asset = _getAsset(token);
        if (asset.decimals == 0) revert E.AssetNotFound();

        // Validate
        if (profile.weights.length < 2 || profile.weights.length > 32) revert E.InvalidParameter();
        if (profile.weights.length != profile.endOffsets.length) revert E.InvalidParameter();
        if (profile.weights.length != profile.slopes.length) revert E.InvalidParameter();

        // Update cold storage + hot path segmentCount
        _sb().liquidityProfiles[token] = _buildLiquidityProfile(profile);
        asset.segmentCount = uint8(profile.weights.length);

        emit LiquidityProfileUpdated(token, asset.segmentCount);
    }

    // ========== FLAG SETTERS (INLINE BIT OPS) ==========

    function freezeAsset(address token, string calldata reason) external override onlyOwnerOrGuardian {
        RiskConfig storage risk = _sb().riskConfigs[token];
        risk.flags |= 0x01;  // Set bit0
        emit AssetFrozen(token, reason);
    }

    function unfreezeAsset(address token) external override onlyOwnerOrGuardian {
        RiskConfig storage risk = _sb().riskConfigs[token];
        risk.flags &= 0xFFFE;  // Clear bit0
        emit AssetUnfrozen(token);
    }

    function enableFlashLoans(address token) external override onlyOwner {
        RiskConfig storage risk = _sb().riskConfigs[token];
        risk.flags |= 0x10;  // Set bit4
        emit FlashLoansEnabled(token);
    }

    function disableFlashLoans(address token) external override onlyOwner {
        RiskConfig storage risk = _sb().riskConfigs[token];
        risk.flags &= 0xFFEF;  // Clear bit4
        emit FlashLoansDisabled(token);
    }

    function enableDecay(address token) external override onlyOwner {
        RiskConfig storage risk = _sb().riskConfigs[token];
        risk.flags |= 0x08;  // Set bit3
    }

    function disableDecay(address token) external override onlyOwner {
        RiskConfig storage risk = _sb().riskConfigs[token];
        risk.flags &= 0xFFF7;  // Clear bit3
    }

    function enableLiabilitySwap(address token) external override onlyOwner {
        RiskConfig storage risk = _sb().riskConfigs[token];
        risk.flags |= 0x04;  // Set bit2
    }

    function disableLiabilitySwap(address token) external override onlyOwner {
        RiskConfig storage risk = _sb().riskConfigs[token];
        risk.flags &= 0xFFFB;  // Clear bit2
    }

    // ========== PAUSE/UNPAUSE ==========

    function pausePool() external override onlyOwner {
        _setPaused(true);
        emit PoolPaused();
    }

    function unpausePool() external override onlyOwner {
        _setPaused(false);
        emit PoolUnpaused();
    }

    // ========== ORACLE UPDATE (GUARDIAN) ==========

    function updateOracle(address token, uint64 newPrice, uint32 newVolEMA) external override {
        if (!hasAnyRole(msg.sender, GUARDIAN_ROLE) && msg.sender != owner()) revert E.Unauthorized();

        IBAMM.BAMMStorage storage $ = _sb();
        Asset storage asset = _getAsset(token);
        if (asset.decimals == 0) revert E.AssetNotFound();
        if ($.oracleConfigs[token].mainOracle != address(this)) revert E.InvalidParameter();
        bytes32 feedId = keccak256(abi.encodePacked(token, $.baseToken));
        IInternalOracle(address(this)).updateOracle(feedId, newPrice, newVolEMA);
    }

    // ========== BLACKLIST ==========

    function blacklistAddress(address account) external override onlyGuardian {
        LibUtils.requireNonZero(account);
        _sb().blacklisted[account] = true;
        emit AddressBlacklisted(account);
    }

    function removeFromBlacklist(address account) external override onlyOwnerOrGuardian {
        _sb().blacklisted[account] = false;
        emit AddressRemovedFromBlacklist(account);
    }

    function isBlacklisted(address account) external view override returns (bool) {
        return _sb().blacklisted[account];
    }

    // ========== RESCUE ==========

    function requestRescue(address token, uint256 amount, address receiver) external onlyOwner {
        _requestRescue(token, amount, receiver);
    }

    function executeRescue() external onlyOwner {
        _executeRescue();
    }

    function cancelRescue() external onlyOwner {
        _cancelRescue();
    }

    // ========== INTERNAL HELPERS ==========

    function _buildLiquidityProfile(LiquidtyConfig calldata config) internal pure returns (LiquidityProfile memory) {
        // Pack segments (implementation in LibLiquiditySegments)
        return LiquidityProfile({
            baseBreadth: config.baseBreadth,
            maxBreadth: config.maxBreadth,
            volKappa: config.volKappa,
            segments: _packSegments(config.weights, config.endOffsets, config.slopes)
        });
    }

    function _packSegments(
        uint8[] calldata weights,
        int8[] calldata offsets,
        int32[] calldata slopes
    ) internal pure returns (SegLib.PackedSegments memory result) {
        // Pack segments into fixed array
        // Each uint256 holds 5 segments (51 bits each: 8+8+32+3 padding)
        uint256 count = weights.length;
        for (uint256 i = 0; i < count && i < 32; ++i) {
            uint256 slot = i / 5;
            uint256 offset = (i % 5) * 51;
            uint256 packed = (uint256(uint8(weights[i])) << 43)
                           | (uint256(uint8(offsets[i])) << 35)
                           | uint256(uint32(slopes[i]));
            result.data[slot] |= packed << offset;
        }
    }

    function _getDecimals(address token) internal view virtual returns (uint8);
}
