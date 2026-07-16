//! AIMM economic simulation harness for the BTR DEX AMM. The f64 core mirrors the settlement order
//! and convex coverage wall in `evm/src/libraries/Pricing.sol`; bit-exact parity remains in Foundry.
//! Non-production oracle/fee experiments are explicitly reported as `AIMM-Research`.
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
