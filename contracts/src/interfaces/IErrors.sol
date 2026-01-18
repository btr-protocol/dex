// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title IErrors
/// @notice Minimal error set with resource/caller type enums for context
/// @dev All contracts inherit from this to avoid duplicate error declarations
interface IErrors {
    // ═══════════════════════════════════════════════════════════════════════════
    // RESOURCE TYPES (for contextual errors)
    // ═══════════════════════════════════════════════════════════════════════════

    enum Resource {
        POOL,
        ASSET,
        ORACLE,
        BRIDGE,
        BRIDGE_PEER,
        STAKING,
        DISTRIBUTION,
        TREASURY,
        FLASH,
        SWAP,
        LIABILITY_SWAP,
        REWARD_TOKEN,
        CAMPAIGN,
        ROLE,
        PROFILE,
        ANCHOR,
        CLAIM,
        VESTING,
        TRANSFER
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CORE ERRORS (14 total - down from 60+)
    // ═══════════════════════════════════════════════════════════════════════════

    // Zero value errors
    error ZeroValue();                                      // Covers ZeroAddress, ZeroAmount, ZeroPrice, ZeroRate

    // Amount/balance errors
    error InsufficientAmount(uint256 available, uint256 required);  // Covers all balance/amount checks
    error ExcessiveAmount(uint256 amount, uint256 limit);           // Covers AmountTooLarge, DailyLimitExceeded, etc.
    error ExceedsMaxSupply();                                        // Token supply exceeds max cap

    // Authorization errors
    // Note: Unauthorized() is inherited from Solady's Ownable - not redeclared here to avoid conflicts

    // State errors
    error InvalidState();                                   // Covers NotInitialized, AlreadyInitialized, Paused, NotPaused, StillLocked, etc.
    error FeatureDisabled(Resource resource);               // Covers SwapDisabled, FlashDisabled, BridgePaused, etc.

    // Configuration errors
    error NotConfigured(Resource resource, address target); // Covers OracleNotConfigured, StakingNotConfigured, PeerNotConfigured, TokenNotSupported
    error AlreadyConfigured(Resource resource, address target); // Covers AssetAlreadyExists, StakingAlreadyConfigured, RewardTokenAlreadyAdded
    error NotFound(Resource resource, address target);      // Covers AssetNotFound, RewardTokenNotFound

    // Validation errors
    error InvalidInput();                                   // Covers InvalidParameter, InvalidProfile, EmptyProfile, InvalidWeightSum, IdenticalTokens, InvalidDeviation, InvalidOpType
    error ThresholdViolation(uint256 value, uint256 threshold); // Covers MinLiquidityViolation, SlippageExceeded, VolatilityTooHigh, etc.

    // Operation errors
    error OperationFailed();                                // Covers CallFailed, TransferFailed, FlashLoanCallbackFailed, FeeQuoteFailed, InvalidHookResult
    error PendingTimelock(uint48 executeAt);                // Covers TimelockNotExpired, NoPendingOperation, PendingOperation
    error DeploymentFailed();                               // CREATE3 deployment failed

    // Oracle errors
    error StaleData(uint32 age, uint32 maxAge);             // Covers OracleStale

    // Reentrancy
    error ReentrancyDetected();

    // Flow guard (JIT protection)
    error CooldownActive(uint32 remainingSeconds);          // Deposit→withdraw or stake→unstake cooldown not elapsed

    // Price floor violation
    error PriceBelowReservation(uint64 price, uint64 reservationPrice);  // Swap would push price below reservation floor
}
