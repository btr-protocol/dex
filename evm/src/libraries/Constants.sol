// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title Constants -AIMM-specific constants (dex-local)
/// @dev Generic precision/timelock/sentinel constants live in @btr-shared/Constants.sol.
library Constants {
    // Phase 42H.B.3d -ERC-7201 storage locations removed (plain state vars on Pool).

    // --- Risk flags ---
    uint16 internal constant FROZEN_BIT = 1 << 0;
    uint16 internal constant SWAP_ENABLED_BIT = 1 << 1;
    uint16 internal constant LIABILITY_SWAP_ENABLED_BIT = 1 << 2;
    uint16 internal constant DECAY_ENABLED_BIT = 1 << 3;
    uint16 internal constant FLASH_ENABLED_BIT = 1 << 4;
    uint16 internal constant FEE_ON_TRANSFER_BIT = 1 << 5;
    uint16 internal constant STAKEABLE_BIT = 1 << 6;
    uint16 internal constant BRIDGEABLE_BIT = 1 << 7;

    // --- Oracle modes ---
    uint16 internal constant MODE_USE_INTERNAL = 1 << 0;
    uint16 internal constant MODE_USE_EXTERNAL = 1 << 1;
    uint16 internal constant MODE_ALLOW_FALLBACK = 1 << 2;

    // --- Hook flags ---
    uint32 internal constant HOOK_PRE_INIT = 1 << 0;
    uint32 internal constant HOOK_POST_INIT = 1 << 1;
    uint32 internal constant HOOK_PRE_DEPOSIT = 1 << 2;
    uint32 internal constant HOOK_POST_DEPOSIT = 1 << 3;
    uint32 internal constant HOOK_PRE_WITHDRAW = 1 << 4;
    uint32 internal constant HOOK_POST_WITHDRAW = 1 << 5;
    uint32 internal constant HOOK_PRE_SWAP = 1 << 6;
    uint32 internal constant HOOK_POST_SWAP = 1 << 7;
    uint32 internal constant HOOK_PRE_DONATE = 1 << 8;
    uint32 internal constant HOOK_POST_DONATE = 1 << 9;
    uint32 internal constant HOOK_PRE_FLASH_LOAN = 1 << 10;
    uint32 internal constant HOOK_POST_FLASH_LOAN = 1 << 11;

    // --- Flow guard ---
    /// @notice JIT cooldown (seconds) -chain-agnostic safe default.
    uint16 internal constant DEFAULT_FLOW_COOLDOWN = 15;

    // --- Timelock IDs (precomputed keccak256) ---
    bytes32 internal constant TIMELOCK_ID_OWNERSHIP = 0xb23d8fa2f62c8a954db45521d1249908693b29ffd3d2dab6348898c4198996b2;
    bytes32 internal constant TIMELOCK_ID_MODULE = 0x9711820581f0923b8ce766818550d8de681ea05c98d406ede2cb99f547946483;
    bytes32 internal constant TIMELOCK_ID_BASE_MIGRATION = 0x481ddbaf0bd6c8dbe0481df731f218348c8e6a7d7c2688a8461149748efe26b2;
    // Oracle: keccak256(abi.encodePacked("ORACLE_UPDATE", token))
    bytes32 internal constant TIMELOCK_ID_STAKING = 0x31d5d9f75ffb4c90ed2cfe65e740a9e01a63f5c56e0230dcfebcfa5d5d4dabd2;
    bytes32 internal constant TIMELOCK_ID_DISTRIBUTION = 0x96c0232a810ff94a1df4a4c89c2aa471f0a4ca4008e0c532f71f233529af9490;
    bytes32 internal constant TIMELOCK_ID_FEE_PARAMS = 0x8b78c6d8bcad3b5cb6b93b4e61d52c5a7b9e8f4c2d1a0e3f6b5c4d8a7e9f1c2d;
    bytes32 internal constant TIMELOCK_ID_BRIDGE = 0x183169b8f82d189401b48b883d17402cedfd43bd2085165ddeb902945cc01676;
    bytes32 internal constant TIMELOCK_ID_TREASURY = 0x7c5d1f6de8c0b8f9c4a6d5b3e2a1c9f8d7e6b5a4c3d2e1f0a9b8c7d6e5f4a3b2;

    // --- Greek var legend (auditors) ---
    // ψ inventorySkew [-100,+100] · π progress [0,1] · γ gamma BPS · ν vega BPS · λ lambda BPS
    // η haircutSuppressor BPS · σ volatility PBPS · Δ delta PBPS · κ dispersion PBPS
    // Coverage: c = (R*WAD)/L · Spread S = 100 + (σ*ν)/100 · ψ = sign*γ*π/100 · Fee φ = (x*S)/(2*PBPS)
}
