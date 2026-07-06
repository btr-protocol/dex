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
    // bit 6 (was RESERVED, ex-STAKEABLE): PROTOCOL_PAUSED. A guardian-set emergency halt, kept SEPARATE
    // from FROZEN_BIT so unpausing never clobbers an independent per-asset risk freeze. Read on the swap
    // hot path via the same const mask in checkRisk (+0 runtime gas). ABI/flag-audit note: bit reclaimed.
    uint16 internal constant PROTOCOL_PAUSED_BIT = 1 << 6;
    uint16 internal constant BRIDGEABLE_BIT = 1 << 7;
    // Halt mask — an asset is halted for ALL value-moving ops (swap, flash, deposit, interior-hop
    // transit) if EITHER a per-asset risk FREEZE or a guardian PROTOCOL_PAUSE is set. Use this single
    // mask at every gate so the two halt bits can never silently diverge (a pause that stops swaps but
    // leaves flash loans / interior-hop routing open is exactly the bypass this prevents).
    uint16 internal constant HALT_MASK = FROZEN_BIT | PROTOCOL_PAUSED_BIT;

    // --- On-chain EMA (ExternalOracle reference price) ---
    /// @notice Rate-clamp gain: a single push may move the EMA at most K_BAND·confidence (bps) toward
    ///         the mark. Trust the mark within k·(its 1σ CI); a manipulated push displaces ≤ α·band.
    uint256 internal constant K_BAND = 8;
    /// @notice Absolute cap on the per-push EMA clamp band (bps). Bounds worst-case displacement even
    ///         when a push claims a huge confidence — a RATE clamp (not absolute min/max) so it tracks
    ///         real crashes over successive pushes yet never bricks like a LUNA/Venus minAnswer floor.
    uint256 internal constant MAX_BAND_BPS = 2000; // 20%
    /// @notice Global halt: a swap reverts if the quoted feed's 1σ CI (confidence, bps) exceeds this.
    ///         Past this the mark is too uncertain to price against; fail-closed like the depeg band.
    uint16 internal constant MAX_CONFIDENCE_HALT_BPS = 1000; // 10%

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

    // --- R44-1 (T3-HIGH1): hook-fee inflation cap (admin-trusted hook hardening) ---
    /// @notice Max extra fee a hook may charge as a fraction of swap output. 500 = 5% in BPS (10000=100%).
    /// @dev    Defense-in-depth vs malicious/compromised admin-registered hook returning huge `extraFee`
    ///         that would drain output-token reserves under prior accounting. Clamp applied at
    ///         `PoolHookExec.applyHookFee` entry.
    uint16 internal constant MAX_HOOK_EXTRA_FEE_BPS = 500;

    // --- R44-2 (T3-HIGH2): base-token depeg halt threshold ---
    /// @notice Max allowed deviation of base-token oracle price from 1e18 (unit-of-account parity).
    ///         500 = 5% in BPS. Swaps revert with `Err.BaseDepegged` when |1e18 - basePrice| / 1e18 exceeds this.
    /// @dev    Closes the prior hardcoded `basePrice = 1e18` blindness in `Pricing._cacheEndpoint` /
    ///         `_executeLeg`. Only enforced when `$.baseTokenOracle != address(0)`; unset = stable-base
    ///         backwards-compat mode (no halt).
    uint16 internal constant BASE_DEPEG_HALT_BPS = 500;

    // --- Internal-oracle stableswap mode ---
    /// @notice OracleConfig.mode selector. EXTERNAL (default): quote off the keeper mark. INTERNAL:
    ///         quote off a per-asset constant peg (pegB64); the external feed only GATES (depeg breaker).
    uint8 internal constant ORACLE_MODE_EXTERNAL = 0;
    uint8 internal constant ORACLE_MODE_INTERNAL = 1;
    /// @notice Synthetic σ (PBPS, 1e6 base) for the internal constant-peg feed. Low but nonzero so the
    ///         S_vol spread band stays alive (a peg is not zero-vol — it can jump-depeg).
    uint32 internal constant STABLE_SIGMA = 1_000; // 0.1% (PBPS 1e6 base; = @btr-shared ONE_PCT_PBPS/10)
    /// @notice Max external depeg-band width (bps) admissible for INTERNAL mode. Enforces the fixed-peg
    ///         ELIGIBILITY rule on-chain: a loosely/variable-pegged unit (rebaser, FX/yield-bearing)
    ///         cannot sit inside so tight a band, so it is rejected at config and must use EXTERNAL mode.
    uint16 internal constant MAX_STABLE_DEPEG_BAND_BPS = 50;

    /// @notice Protocol-wide minimum path spread floor (PBPS). 1 PBPS = 0.0001% = 0.01 bp
    ///         (100 PBPS = 1 bp). Finest on-chain quantum — enables sub-1 bp quotes at σ=0.
    uint16 internal constant MIN_FEE_PBPS = 1;

    // --- σ-EMA (on-chain fold of keeper Parkinson sample) ---
    /// @notice Per full-α push: σ may rise by max(relative band, SIGMA_BAND_FLOOR_PBPS).
    uint16 internal constant SIGMA_UP_BPS = 10_000; // 100%
    /// @notice Per full-α push: σ may fall by at most this fraction of current σ.
    uint16 internal constant SIGMA_DOWN_BPS = 2_500; // 25%
    /// @notice Absolute minimum up-band (PBPS) so σ≈0 cannot brick ratchet-up.
    uint32 internal constant SIGMA_BAND_FLOOR_PBPS = 1_000; // 0.1%
    /// @notice Cap on σ-EMA and pushed samples (10_000% = 100× in PBPS units).
    uint32 internal constant MAX_SIGMA_PBPS = 100_000_000;

    // --- Greek var legend (auditors) ---
    // ψ inventorySkew [-100,+100] · π progress [0,1] · γ gamma BPS · ν vega BPS
    // η haircutSuppressor BPS · σ volatility PBPS · Δ delta PBPS · κ dispersion PBPS
    // Coverage: c = (R*WAD)/L · Spread S = 100 + (σ*ν)/100 · ψ = sign*γ*π/100 · Fee φ = (x*S)/(2*PBPS)
}
