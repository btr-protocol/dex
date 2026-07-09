//! AIMM simulation harness — the Rust reference model for the BTR DEX AMM
//! (`evm/src/libraries/Pricing.sol`). Relocated from `prime/crates/ml` (2026-07-09) so the sim lives
//! in the same repo as the contracts it mirrors — the sim↔Solidity parity (spread, inventory skew,
//! convex coverage toll, staleness premium) is a single-repo invariant now, not a cross-repo drift risk.
//!
//! `amm::aimm` is the BTR AIMM; the siblings (`curve`, `univ2`, `univ3`, `wombat`, `as_mm`) are
//! baselines for comparison, and `engine`/`router` drive the GBM / real-tape simulations.

pub mod amm;
