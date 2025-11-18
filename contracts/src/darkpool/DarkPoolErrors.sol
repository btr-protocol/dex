// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title DarkPool Custom Errors
/// @notice Centralized error definitions for gas efficiency
library DarkPoolErrors {
    // Common errors
    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error InvalidParameter();
    error AlreadyInitialized();
    error NotInitialized();
    error Paused();

    // Proof verification errors
    error InvalidProof();
    error InvalidRoot();
    error RootNotFound();
    error NullifierAlreadySpent(bytes32 nullifier);
    error ExtDataHashMismatch();

    // Merkle tree errors
    error TreeFull();
    error InvalidLeafIndex();

    // BAMM interaction errors
    error BAMMOperationFailed();
    error InsufficientLPTokens();
    error InsufficientTokenBalance();
    error SlippageExceeded();

    // Association set errors
    error ASPRequired();
    error ASPNotApproved(bytes32 aspRoot);
    error ASPRootZero();

    // Factory errors
    error DarkPoolAlreadyExists(address bammPool);
    error InvalidBeacon();
    error InvalidImplementation();

    // Action type errors
    error InvalidActionType(uint8 actionType);
    error ActionExecutionFailed();

    // Array length errors
    error ArrayLengthMismatch();
    error EmptyArray();
    error TooManyInputs();
    error TooManyOutputs();

    // ShieldedState interaction errors
    error NullifierSpendingFailed();
}

/// @title DarkPool Events
/// @notice Centralized event definitions
/// @dev Events are defined in IDarkPool interface for better compatibility
library DarkPoolEvents {
    // Re-export events from IDarkPool for convenience
    // Actual events are in the interface to avoid duplication
}
