//! Solidity-mirrored constants — the single Rust encoding of every numeric the pricer shares with
//! the deployed contracts.
//!
//! DIRECTION OF TRUTH: Solidity is normative. `dex/evm` is the deployed artifact; this crate is its
//! reference model and must follow it. Where a Solidity comment credits `dex/sim` for a formula
//! (e.g. `Pricing.sol` on `cov_q`) it records provenance — where the design was derived — not
//! authority. When the two disagree, the sim is wrong.
//!
//! Every value below carries the file it mirrors. `tests/solidity_parity.rs` re-reads those files
//! and fails when a value drifts, so this module cannot silently fall out of date.

/// 1e18 fixed point (`shared/evm/src/Constants.sol` `WAD`).
pub const WAD: f64 = 1e18;
/// 0.01% precision (`shared/evm/src/Constants.sol` `BPS`).
pub const BPS: f64 = 1e4;
/// 0.0001% precision — fees, offsets, dispersion (`shared/evm/src/Constants.sol` `PBPS`).
pub const PBPS: f64 = 1e6;
/// 0.00001% — sim-local scale for the oracle deviation Δ. No Solidity counterpart: on-chain Δ is
/// carried in the packed oracle word, so there is nothing to drift against.
pub const ORACLE_PBPS: f64 = 1e7;

/// Max linear impact on the no-profile fallback, WAD-relative (`Pricing.sol` `MAX_IMPACT = 2*WAD`).
pub const MAX_IMPACT: f64 = 2.0;
/// Floor on the sell-side impact adjustment (`Pricing.sol` `MIN_ADJ = WAD/1000`).
pub const MIN_ADJ: f64 = 0.001;
/// Spline offset floor in PBPS (`Pricing.sol` `SPLINE_MIN_OFFSET_PBPS = -PBPS*90/100`).
pub const SPLINE_MIN_OFFSET_PBPS: f64 = -PBPS * 90.0 / 100.0;
/// Absolute execution-price floor, bps of mark (`Pricing.sol` `MIN_EXEC_PRICE_BPS = 500`).
pub const MIN_EXEC_PRICE_BPS: f64 = 500.0;
/// Staleness-premium coefficient for the A-S σ√excess keeper-lag defense (`Pricing.sol` `STALE_Z`).
pub const STALE_Z: f64 = 100.0;
/// Keeper-grace ceiling in seconds: grace = min(ttl/2, this) (`Pricing.sol` `STALE_GRACE_CAP_S`).
pub const STALE_GRACE_CAP_S: usize = 30;

/// Hard segment cap — the packed header holds 14×uint16 boundaries (`NUQuartic.sol` `MAX_SEGS`).
pub const MAX_SEGS: usize = 14;
/// Curve flag bit0: preset only valid on coverage-walled assets (`NUQuartic.sol`
/// `FLAG_REQUIRES_WALL`).
pub const FLAG_REQUIRES_WALL: u8 = 1;
/// Packed coefficient bound: |k_i| ≤ uint64::MAX/2 in pbps·Q (`NUQuartic.sol` `_buildSeg`).
/// Expressed here in pbps (the sim's units) by dividing out Q = 1e9.
pub const SEG_COEFF_LIMIT_PBPS: f64 = ((u64::MAX / 2) as f64) / 1e9;
/// Packed prefix-integral bound: S ∈ int128 in pbps·Q·x units (`NUQuartic.sol` `_buildSeg`).
pub const PREFIX_LIMIT_PBPS: f64 = (i128::MAX as f64) / 1e9;
