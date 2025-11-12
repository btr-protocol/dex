// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title BAMM Custom Errors
/// @notice Centralized error definitions for gas efficiency
library BAMMErrors {
    // Common errors
    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error InvalidParameter();
    error Overflow();
    error AlreadyInitialized();
    error NotInitialized();
    error Locked();
    error Expired();
    error Paused();
    error DivisionByZero();

    // Asset errors
    error AssetFrozen();
    error AssetNotFound();
    error InsufficientReserves();
    error BelowMinimumLiquidity();

    // Oracle errors
    error InvalidPrice();
    error PriceChangeTooLarge();
    error OracleStale();

    // LP errors
    error InsufficientBalance();
    error SlippageExceeded();

    // Role errors
    error PendingAcceptance();
    error NoAcceptance();
    error InvalidRole();

    // Blacklist errors
    error Blacklisted();

    // Hook errors
    error InvalidHookContract(address hook, string missingFunction);

    // Flash loan errors
    error FlashLoanCallbackFailed();
    error PoolPaused();
}

/// @title BAMM Events
/// @notice Centralized event definitions
library BAMMEvents {
    // Pool events
    event Swap(address indexed sender, address indexed receiver, address indexed tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 feeBps);
    event BatchSwap(address indexed sender, address indexed receiver, address[] path, uint256[] amounts);
    event Deposit(address indexed sender, address indexed token, uint256 amount, uint256 lpTokens);
    event Withdraw(address indexed sender, address indexed token, uint256 lpTokens, uint256 amount, uint256 feeBps);
    event ProtocolFeesCollected(address indexed treasury, address[] tokens, uint256[] amounts);

    // Asset events
    event AssetAdded(address indexed token, uint128 minLiquidity);
    event AssetFrozen(address indexed token, string reason);
    event AssetUnfrozen(address indexed token);
    event BaseAssetUpdated(address indexed oldBase, address indexed newBase);
    event MinLiquidityUpdated(address indexed token, uint128 oldMinLiquidity, uint128 newMinLiquidity);
    event OracleUpdated(address indexed token, address indexed mainOracle, address indexed fallbackOracle);

    // Oracle events
    event OracleUpdate(bytes32 indexed oracleId, uint64 fastPrice, uint64 slowPrice, uint32 fastVol, uint32 slowVol, address indexed updater);
    event VolatilityWeightsUpdated(uint8 fastWeight, uint8 slowWeight);
    event LiquidityProfileUpdated(address indexed token, uint8 segments);
    event CircuitBreakerTriggered(address indexed token, int256 deviationBps, uint256 timestamp);

    // Owner events
    event PoolPaused();
    event PoolUnpaused();
    event RoleGrantPending(address indexed account, bytes32 indexed role, address indexed replacing);
    event RoleAccepted(address indexed account, bytes32 indexed role);
    event RoleRevoked(address indexed account, bytes32 indexed role);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // Blacklist events
    event AddressBlacklisted(address indexed account);
    event AddressRemovedFromBlacklist(address indexed account);

    // Rescue events
    event RescueRequested(address indexed receiver, address indexed token, uint256 amount);
    event RescueExecuted(address indexed receiver, address indexed token, uint256 amount);
    event RescueCancelled(address indexed receiver, address indexed token);

    // Hook events
    event HooksUpdated(address indexed token, address indexed hookAddress);

    // Flash loan events
    event FlashLoansEnabled(address indexed token);
    event FlashLoansDisabled(address indexed token);
    event FlashFeeUpdated(address indexed token, uint16 oldFlashFeeBps, uint16 newFlashFeeBps);
}