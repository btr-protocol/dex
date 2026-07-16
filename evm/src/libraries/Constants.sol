// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title Constants — AIMM-specific constants (dex-local)
/// @dev Generic precision/timelock/sentinel constants live in @btr-shared/Constants.sol.
library Constants {
  // --- Risk flags ---
  uint16 internal constant FROZEN_BIT = 1 << 0;
  uint16 internal constant SWAP_ENABLED_BIT = 1 << 1;
  uint16 internal constant LIABILITY_SWAP_ENABLED_BIT = 1 << 2;
  uint16 internal constant DECAY_ENABLED_BIT = 1 << 3;
  uint16 internal constant FLASH_ENABLED_BIT = 1 << 4;
  // bit 5 reserved (ex FEE_ON_TRANSFER — unused; pull always uses balance-delta)
  /// @dev Guardian emergency halt, separate from FROZEN so unpause never clears a risk freeze.
  uint16 internal constant ASSET_PAUSED_BIT = 1 << 6;
  // bit 7 reserved (ex BRIDGEABLE — bridgeability is Bridge token-config only)
  /// @dev Halt = freeze | pause. Single mask at every value-moving gate.
  uint16 internal constant HALT_MASK = FROZEN_BIT | ASSET_PAUSED_BIT;

  /// @dev Share↔value index base. value = lp·index/WAD.
  uint256 internal constant LIQUIDITY_INDEX_INIT = 1e12;

  /// @notice Global halt: a swap reverts if the quoted feed's 1σ CI (confidence, bps) exceeds this.
  ///         Past this the mark is too uncertain to price against; fail-closed like the depeg band.
  uint16 internal constant MAX_CONFIDENCE_HALT_BPS = 1000; // 10%

  // --- Flow guard ---
  /// @notice JIT cooldown (seconds) -chain-agnostic safe default.
  uint16 internal constant DEFAULT_FLOW_COOLDOWN = 15;

  // --- R44-2 (T3-HIGH2): base-token depeg halt threshold ---
  /// @notice Max allowed deviation of base-token oracle price from 1e18 (unit-of-account parity).
  ///         500 = 5% in BPS. Swaps revert with `Err.BaseDepegged` when |1e18 - basePrice| / 1e18 exceeds this.
  /// @dev    The source is the base asset's normal, timelocked OracleConfig. There is no separate
  ///         untimelocked base-oracle authority.
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

  /// @notice Cap on stored σ and signed samples (10_000% = 100× in PBPS units).
  uint32 internal constant MAX_SIGMA_PBPS = 100_000_000;

  /// @notice Angle Merkl Distributor — canonical multi-chain address (same on BSC/Base/Arbitrum/…).
  ///         Off-chain proof-carrying rewards (Morpho, Euler rEUL, generic ERC4626) claim here.
  // ceiling: verify BSC live address at deploy; owner may override via YieldHook.setMerklDistributor.
  address internal constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

  // --- Pool hooks (lean: unified pre-outflow + optional postInflow) ---
  uint32 internal constant HOOK_PRE_OUTFLOW = 1 << 0;
  uint32 internal constant HOOK_POST_INFLOW = 1 << 1;
  /// @notice Known flag bits only; unknown bits rejected at setAssetHook.
  uint32 internal constant HOOK_FLAGS_MASK = HOOK_PRE_OUTFLOW | HOOK_POST_INFLOW;
}
