// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IDarkPoolStorage
/// @notice EIP-7201 namespaced storage layout for DarkPool
/// @dev Constants moved to LibStorage for Solidity 0.8.x compatibility
interface IDarkPoolStorage {

    /// @notice Main storage structure for DarkPool - OPTIMIZED
    /// @custom:storage-location erc7201:darkpool.storage.v1
    /// @dev Optimized storage layout with flags:
    ///      Slot 0: bammPool(20) + shieldedState(20) = 40 bytes
    ///      Slot 1: verifier(20) + flags(1) = 21 bytes (11 spare)
    ///      Slot 2: poseidon2(20) + poseidonN(20) = 40 bytes
    ///      Mappings: aspRootExpiry (for ASP validation)
    struct DarkPoolStorage {
        // Slot 0: BAMM and ShieldedState addresses
        address bammPool;           // 20 bytes
        address shieldedState;      // 20 bytes (reference to global merkle tree/nullifier set)

        // Slot 1: Verifier and flags
        address verifier;           // 20 bytes
        uint8 flags;                // 1 byte: bit0=paused, bit1=requireASP
        uint8[11] _pad;             // 11 bytes spare for future use

        // Slot 2: Poseidon implementations
        address poseidon2;          // 20 bytes (compact Poseidon for 2-input)
        address poseidonN;          // 20 bytes (compact Poseidon for N-input)

        // Mappings (separate slots via keccak256)
        // Association Set Roots with expiration
        mapping(bytes32 => uint256) aspRootExpiry; // timestamp when ASP root expires (0 = not approved)

        // Reserved for future upgrades
        uint256[50] __gap;
    }
}
