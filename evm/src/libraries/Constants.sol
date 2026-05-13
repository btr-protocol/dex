// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

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

    // --- Greek var legend (auditors) ---
    // ψ inventorySkew [-100,+100] · π progress [0,1] · γ gamma BPS · ν vega BPS · λ lambda BPS
    // η haircutSuppressor BPS · σ volatility PBPS · Δ delta PBPS · κ dispersion PBPS
    // Coverage: c = (R*WAD)/L · Spread S = 100 + (σ*ν)/100 · ψ = sign*γ*π/100 · Fee φ = (x*S)/(2*PBPS)
}
