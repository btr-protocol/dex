// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title Err — shared error selectors.
/// @notice Canonical declarations for errors used across multiple contracts. Contract-specific
///         errors live with their contract. Bytecode cost = 4-byte selector at the revert site.
library Err {
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

    error ZeroValue();
    error InsufficientAmount(uint256 available, uint256 required);
    error ExcessiveAmount(uint256 amount, uint256 limit);
    error ExceedsMaxSupply();

    // NB: auth failures use Solady's Ownable.Unauthorized()

    error InvalidState();
    error FeatureDisabled(Resource resource);

    error NotConfigured(Resource resource, address target);
    error AlreadyConfigured(Resource resource, address target);
    error NotFound(Resource resource, address target);

    error InvalidInput();
    error ThresholdViolation(uint256 value, uint256 threshold);

    error OperationFailed();
    error PendingTimelock(uint48 executeAt);
    error DeploymentFailed();

    error StaleData(uint32 age, uint32 maxAge);

    error ReentrancyDetected();
    error CooldownActive(uint32 remainingSeconds);
    error PriceBelowReservation(uint64 price, uint64 reservationPrice);
}
