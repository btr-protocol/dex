//! AIMM simulation harness — the Rust reference model for the BTR DEX AMM
//! (`evm/src/libraries/Pricing.sol`). Originally from the retired `prime/crates/ml` crate (relocated 2026-07-09) so the sim lives
//! in the same repo as the contracts it mirrors — the sim↔Solidity parity (spread, inventory skew,
//! convex coverage toll, staleness premium) is a single-repo invariant now, not a cross-repo drift risk.
//!
//! `amm::aimm` is the BTR AIMM; the siblings (`curve`, `univ2`, `univ3`, `wombat`, `as_mm`) are
//! baselines for comparison, and `engine`/`router` drive the GBM / real-tape simulations.

// Reference-sim lint scope. Sim prices/quotes are finite (no NaN), so `!(a < b)` is intentional
// (neg_cmp). The remaining allows are false-positive-ish on this numerical code: `crypto` is unwrapped
// after an `is_some` guard across a mixed &ref/&mut borrow (can't bind once), and the router loops index
// parallel per-venue arrays by the same `i`. Correctness lints stay on; only these style nits are muted.
#![allow(clippy::neg_cmp_op_on_partial_ord)]
#![allow(clippy::unnecessary_unwrap)]
#![allow(clippy::needless_range_loop)]
#![allow(clippy::doc_lazy_continuation)]

pub mod amm;
