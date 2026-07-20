//! BTR AIMM pricer (f64). Its quote settlement order mirrors
//! `dex/evm/src/libraries/Pricing.sol`: gross output -> output-side coverage toll -> path spread.
//! The oracle experiments remain a deliberately separate research superset, not a 1:1 feed model.
//! Production quotes off a FRESH external keeper mark (external-mark primary); this sim retains the
//! OracleMode axis (incl. the legacy internal dual-EMA lagging mark) to MEASURE the LVR that
//! external-mark quoting removes. Two signals here are sim-only and dropped on-chain:
//!   · the Δ/U deviation (toxic-flow) surcharge — dropped from Pricing.sol (directional=RW + no-deferred);
//!     kept here to study the fees-paper Z-Hawkes trend-widening question (keep/port is an open design call).
//!   · the dual fast/slow vol EMA — on-chain feed collapsed to a single pushed σ.
//! Shared with production (same unit constants): coverage c=R/L → linear inventory skew ψ; volatility →
//! dispersion κ; quartic I-spline VWAP over the traversed depth band; asymmetric vol-band fee;
//! coverage-aware depth amp.

use super::nuquartic::QuarticCurve;
use super::{Amm, Fill};

/// How the pool's price mark is sourced — the single most important design axis for LVR.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum OracleMode {
    /// Mark walks from the pool's own executed fills (internal EMA). Correct only where OUR
    /// venue is the price leader (new/illiquid/exclusive listings); catastrophic pick-off for
    /// assets discovered faster elsewhere.
    Internal,
    /// A keeper snaps the mark to the external true price every `interval` steps (else stale).
    /// Models an NX-Rates TDWAP push cadence. Residual LVR = within-window adverse selection.
    External { interval: usize },
    /// Lagged recenter toward the external price each step (Curve-EMA style) with a deviation
    /// breaker at `band` (fractional) — the "safe" design: a bad feed mis-centers but can't be
    /// traded at a fake price, and a large gap snaps the center.
    Hybrid { alpha: f64, band: f64 },
    /// PRODUCTION keeper policy: the keeper watches the true price every step and snaps the mark ONLY
    /// when it has drifted past a per-asset `threshold` (fractional: 1e-4 = 1bp) OR the `heartbeat`
    /// (max steps between pushes) elapses. Bounds the steady-state stale gap to `threshold` regardless
    /// of time/vol — the arb can never catch a gap bigger than θ (+ the one-check reaction window). The
    /// spread floor keyed to ~θ then makes the threshold pick-off unprofitable. `on_step` must be called
    /// every step (push_every=1) so the keeper "observes" continuously.
    Deviation { threshold: f64, heartbeat: usize },
    /// Keeper marks remain authoritative, but the execution center approaches each fresh mark by
    /// `alpha` per observation. `breaker` snaps to truth when lag becomes too large. This is the
    /// deterministic smoothing policy under test, not a production recommendation.
    Smoothing {
        threshold: f64,
        heartbeat: usize,
        alpha: f64,
        breaker: f64,
    },
    /// Experimental fair-value discovery layered on the deviation keeper. Signed trade flow moves a
    /// bounded log-price offset around the last external mark; the offset mean-reverts every step and
    /// resets when a fresh mark lands. This is deliberately research-only: the comparison must prove
    /// that predictive flow outweighs self-induced manipulation and snap-back before any Solidity port.
    TradeOffset {
        threshold: f64,
        heartbeat: usize,
        /// Log-price response to signed trade notional / pool TVL.
        gain: f64,
        /// Per-step residual multiplier in [0,1]; lower means faster mean reversion.
        decay: f64,
        /// Absolute log-price clamp (0.001 = approximately 10 bp).
        max_offset: f64,
    },
    /// Economic keeper trigger: wait while the stale gap is covered by the live quote spread and
    /// the estimated arb surplus is below push gas, but pre-trigger for inclusion-latency risk.
    /// An age spread `age_z·sigma·sqrt(age)` starts immediately after each push.
    Adaptive {
        theta_floor: f64,
        theta_cap: f64,
        heartbeat: usize,
        age_z: f64,
        latency_z: f64,
        latency_steps: usize,
        gas_cost_base: f64,
    },
}

const BPS: f64 = 1e4; // 0.01%
const PBPS: f64 = 1e6; // 0.0001%  (fees, offsets, dispersion)
const ORACLE_PBPS: f64 = 1e7; // 0.00001% (oracle offsets)

/// Default profile = the fitted W5 "flat" (near-uniform density) preset from
/// `research/stable-core/out/spline_shared_grid.json` (wQ/1e9 → pbps), the closest quartic
/// analogue of the retired near-linear Hermite default. Fit reference dispersion 1000 pbps ⇒
/// edge offsets = ±disp/2 at any live dispersion, matching the old default's ±knot·disp/100 span.
const FLAT_INTERIOR: [f64; 9] =
    [500.0, 1000.0, 1250.0, 3000.0, 5000.0, 7000.0, 8750.0, 9000.0, 9500.0];
const FLAT_W: [f64; 14] = [
    -500.0, -463.4937, -439.1332, -402.924, -333.6537, -227.7734, -87.991, 87.991, 227.7734,
    333.6536, 402.9241, 439.1327, 463.4944, 499.9991,
];
const FLAT_DISP_REF: f64 = 1000.0;

/// Per-asset AIMM parameters (token leg). Default numeric controls match the common fixture; all
/// research-only switches default off and the production convex wall shape defaults on.
#[derive(Debug, Clone)]
pub struct AimmParams {
    pub gamma: f64, // inventory sensitivity, BPS (10000 = 1x)
    pub vega: f64,  // volatility sensitivity, BPS
    /// Research-only trend/deviation surcharge sensitivity. Production has no equivalent; the
    /// production-aligned default is zero and non-zero values label the model `AIMM-Research`.
    pub lambda: f64,
    pub min_fee: f64,  // PBPS
    pub max_fee: f64,  // PBPS
    pub min_disp: f64, // PBPS
    pub max_disp: f64, // PBPS
    pub cov_min: f64,  // 0.01% units (5000 = 50%)
    pub cov_max: f64,  // 0.01% units (20000 = 200%)
    pub depth_amp: f64,
    /// Assigned quartic I-spline price profile (fitted preset; y in pbps at `disp_ref`, scaled by
    /// disp/disp_ref per quote). `None` ≙ on-chain header==0 (unset preset): quotes fall back to
    /// the skew-anchored linear-impact model so swaps stay live pre-profile-assignment.
    pub curve: Option<QuarticCurve>,
    /// Fast/slow vol-EMA smoothing (per-swap activity EMA). PBPS-denominated α like PoolOracle.
    pub fast_vol_alpha: f64,
    pub slow_vol_alpha: f64,
    /// Fast/slow price-EMA smoothing for the internal mark offsets (per-swap activity EMA).
    pub fast_px_alpha: f64,
    pub slow_px_alpha: f64,
    /// Charge-only output coverage-wall strength as a fraction (100 on-chain bps = 0.01 here).
    /// It prevents further drain below peg but deliberately does not pay restoring-flow rebates.
    /// Production uses it for protected stable legs and leaves it zero for volatile legs.
    pub kappa_cov: f64,
    /// Coverage-potential shape. Production uses convex=true. false retains the old bounded linear
    /// spring strictly for research comparisons and labels the model `AIMM-Research` when enabled.
    pub kappa_convex: bool,
    /// Staleness-premium coefficient (Avellaneda-Stoikov σ√τ spread). A keeper-pushed mark is only
    /// fresh AT a push; between pushes the true price drifts and the deep book is picked off. The
    /// pool cannot OBSERVE the unseen true price, but it CAN observe elapsed steps since the last
    /// push (block.timestamp − lastPush on-chain) and its own vol EMA, so it widens the spread by
    /// `stale_z · σ · √(steps_since_push)` — the expected adverse-selection over the stale window.
    /// This is the defense that makes the External-keeper design cadence-ROBUST instead of a
    /// knife-edge (0% LVR only at per-step freshness). 0 = disabled (legacy). Volatiles: on.
    pub stale_z: f64,
}

impl Default for AimmParams {
    fn default() -> Self {
        Self {
            gamma: 10_000.0,
            vega: 10_000.0,
            lambda: 0.0,
            min_fee: 1_000.0,
            max_fee: 10_000.0,
            min_disp: 1_000.0,
            max_disp: 100_000.0,
            cov_min: 5_000.0,
            cov_max: 20_000.0,
            depth_amp: 10_000.0,
            curve: Some(QuarticCurve::new(&FLAT_INTERIOR, &FLAT_W, FLAT_DISP_REF)),
            fast_vol_alpha: 1_800.0,
            slow_vol_alpha: 200.0,
            fast_px_alpha: 0.125,
            slow_px_alpha: 0.025,
            kappa_cov: 0.0,
            kappa_convex: true,
            stale_z: 0.0,
        }
    }
}

/// AIMM pool state. `base_*` is the numeraire leg; `tok_*` the volatile leg.
#[derive(Debug, Clone)]
pub struct Aimm {
    pub p: AimmParams,
    pub mode: OracleMode,
    pub base_res: f64,
    pub base_liab: f64,
    pub tok_res: f64,
    pub tok_liab: f64,
    // internal oracle (token, base-per-token):
    pub mark: f64,     // last executed mark (canonical base-per-token)
    pub fast_ema: f64, // fast price EMA (the price the pool quotes around)
    pub slow_ema: f64, // slow price EMA (trend signal for the toxic surcharge)
    target_mark: f64,  // latest keeper target for deterministic smoothing
    pub fast_vol: f64, // PBPS-ish vol EMA (1e6 = 100%)
    pub slow_vol: f64,
    confidence_bps: f64,         // last pushed 1σ CI, in bps
    pending_confidence_bps: f64, // latest external observation, committed on push
    last_ext: f64,               // previous external sample (for realized-vol on the feed)
    cur_step: usize,             // current sim step (set by tick(); on-chain ≙ block.timestamp)
    last_push_step: usize,       // step of the last keeper mark push (on-chain ≙ lastPushTimestamp)
    pushes: usize,               // # keeper mark pushes performed (keeper-tx / gas-cost accounting)
    trade_offset: f64,           // experimental bounded log-price residual around the keeper mark
}

impl Aimm {
    /// Initialize a balanced (coverage = 1) pool seeded at `price` (base per token), with
    /// `base_value` of base reserves and matching token reserves.
    pub fn new(p: AimmParams, price: f64, base_value: f64) -> Self {
        let base_res = base_value;
        let tok_res = base_value / price;
        Self {
            p,
            mode: OracleMode::Internal,
            base_res,
            base_liab: base_res,
            tok_res,
            tok_liab: tok_res,
            mark: price,
            fast_ema: price,
            slow_ema: price,
            target_mark: price,
            fast_vol: 1e4, // seed 1%
            slow_vol: 1e4,
            confidence_bps: 0.0,
            pending_confidence_bps: 0.0,
            last_ext: price,
            cur_step: 0,
            last_push_step: 0,
            pushes: 0,
            trade_offset: 0.0,
        }
    }

    /// Builder: set the oracle mode.
    pub fn with_mode(mut self, mode: OracleMode) -> Self {
        self.mode = mode;
        self
    }

    /// Update the vol EMAs from an external feed sample (used in External/Hybrid modes, where
    /// the keeper computes vol off the full NX-Rates series regardless of pool activity).
    fn update_vol_from_ext(&mut self, ext_px: f64) {
        if self.last_ext > 0.0 && ext_px > 0.0 {
            let ret = (ext_px / self.last_ext).ln().abs() * PBPS;
            self.fast_vol += (self.p.fast_vol_alpha / PBPS) * (ret - self.fast_vol);
            self.slow_vol += (self.p.slow_vol_alpha / PBPS) * (ret - self.slow_vol);
        }
        self.last_ext = ext_px;
    }

    #[inline]
    fn sigma(&self) -> f64 {
        0.5 * (self.fast_vol + self.slow_vol)
    }

    /// Effective deviation Δ in ORACLE_PBPS units = max(|fast−slow|, |fast−mark|)/mark · ORACLE_PBPS.
    #[inline]
    fn delta(&self) -> f64 {
        let d_fs = (self.fast_ema - self.slow_ema).abs();
        let d_fc = (self.quote_mark() - self.mark).abs();
        (d_fs.max(d_fc) / self.mark) * ORACLE_PBPS
    }

    #[inline]
    fn quote_mark(&self) -> f64 {
        match self.mode {
            OracleMode::TradeOffset { .. } => self.fast_ema * self.trade_offset.exp(),
            _ => self.fast_ema,
        }
    }

    /// Research diagnostics: current one-sided fee (half of the full path spread), as a fraction.
    pub fn effective_spread_fraction(&self) -> f64 {
        self.spread() / (2.0 * PBPS)
    }

    /// Research diagnostics: current execution center before inventory skew and spline traversal.
    pub fn execution_center(&self) -> f64 {
        self.quote_mark()
    }

    /// Supply the CI attached to the latest external observation. Keeper modes commit it only when
    /// they push the corresponding mark, matching ExternalOracle's mark+confidence atomic update.
    pub fn set_external_confidence_bps(&mut self, confidence_bps: f64) {
        self.pending_confidence_bps = confidence_bps.max(0.0);
    }

    /// Linear inventory skew in [-100, 100] from a leg's coverage. (`Pricing.computeInventorySkew`)
    /// = reservation-price mid-shift (A-S theory, first on-chain via DODO PMM) driven by the
    /// coverage-ratio imbalance metric R/L (Platypus/Wombat). Response vs metric — two roles, not two names.
    fn skew(&self, res: f64, liab: f64) -> f64 {
        if liab <= 0.0 {
            return -100.0;
        }
        let c = res / liab;
        let crit_min = self.p.cov_min / BPS; // 5000 → 0.5
        let crit_max = self.p.cov_max / BPS; // 20000 → 2.0
        if c <= crit_min {
            return 100.0;
        }
        if c >= crit_max {
            return -100.0;
        }
        let under = c < 1.0;
        let numer = if under { 1.0 - c } else { c - 1.0 };
        let denom = if under {
            1.0 - crit_min
        } else {
            crit_max - 1.0
        };
        let progress = numer / denom;
        let s = (self.p.gamma / BPS) * 100.0 * progress;
        let s = s.min(100.0);
        if under { s } else { -s }
    }

    /// Dispersion κ in PBPS. Quiet floor = min_disp; σ·vega widens above it. (`Pricing._calculateDispersion`)
    fn dispersion(&self) -> f64 {
        let scaled = (self.sigma() * self.p.vega) / (1000.0 * BPS);
        (self.p.min_disp + scaled).clamp(self.p.min_disp, self.p.max_disp)
    }

    /// Effective pricing depth for the token leg. (`Pricing.calculateDepth`)
    fn depth(&self) -> f64 {
        let (r, l) = (self.tok_res, self.tok_liab);
        if r <= 0.0 {
            return 1.0;
        }
        if l <= 0.0 {
            return r;
        }
        let c = r / l;
        if c >= 1.0 || self.p.depth_amp == 0.0 {
            return r;
        }
        let floor = 0.5;
        if c <= floor {
            return r;
        }
        let progress = (c - floor) / (1.0 - floor);
        let exponent = PBPS / (PBPS + 2.0 * self.p.depth_amp);
        let cp = progress.powf(exponent);
        (r + (self.p.depth_amp * (l - r) * cp) / PBPS)
            .min(l)
            .max(1.0)
    }

    /// Average price (base per token) over a traded volume, by traversing the quartic-curve depth
    /// band. `selling` = the trader sells the token into the pool. (`Pricing._traverseCurveByVolume`
    /// + `_traverseCurve`: VWAP offset = area(lo,hi)/width, y-scaled by disp/disp_ref; no assigned
    /// profile ≙ header==0 → skew-anchored linear-impact fallback.)
    fn traverse(
        &self,
        twap: f64,
        disp: f64,
        skew: f64,
        amount_in_tok: f64,
        depth: f64,
        selling: bool,
    ) -> f64 {
        let Some(curve) = &self.p.curve else {
            let impact = (amount_in_tok / depth).min(2.0); // MAX_IMPACT = 200%
            let mid = skew_to_price(twap, skew, disp);
            let k = impact / 2.0;
            return if selling {
                mid * if k < 1.0 { 1.0 - k } else { 0.001 } // MIN_ADJ = 0.1%
            } else {
                mid * (1.0 + k)
            };
        };
        let start = 5000.0 + skew * 50.0; // `Pricing._skewToDepth`
        let vf = ((amount_in_tok * BPS) / depth).min(BPS);
        let end = if selling {
            (start - vf).max(0.0)
        } else {
            (start + vf).min(BPS)
        };
        let (lo, hi) = if start <= end {
            (start, end)
        } else {
            (end, start)
        };
        let width = hi - lo;
        let scale = disp / curve.disp_ref; // `Pricing._scaleY`
        if width == 0.0 {
            return offset_to_price(twap, curve.eval(start) * scale);
        }
        // SPLINE_MIN_OFFSET_PBPS floor (−90%), then the MIN_EXEC_PRICE_BPS (500) absolute floor.
        let avg_off = (curve.area(lo, hi) / width * scale).max(-PBPS * 0.9);
        let price = twap * (PBPS + avg_off) / PBPS;
        price.max(twap * 0.05)
    }

    /// Asymmetric fee (spread) in PBPS for a trade with coverage `impact`. (`Pricing` path spread
    /// + CS-4 fix: Δ is ORACLE_PBPS, rescale to PBPS before forming the surcharge.)
    fn spread(&self) -> f64 {
        let s_vol = self.p.min_fee + (self.sigma() * self.p.vega) / (100.0 * BPS);
        // U = adverse-selection (Glosten-Milgrom) surcharge, keyed on Δ (fast/slow EMA divergence =
        // stale-mark / momentum toxicity) ONLY — NOT gated on coverage direction. Coverage drives the
        // MID (inventory skew) alone; double-gating U on coverage over-taxed the healthy cooperative-
        // rebalancing arb and under-charged coverage-improving stale-mark pick-offs. U self-gates via
        // Δ: ≈0 in calm (so honest rebalancing is cheap), wide only in a dislocation (the toxic window).
        let u = (self.delta() * self.p.lambda) / (BPS * (ORACLE_PBPS / PBPS));
        // Staleness premium (A-S σ√τ) — keyed on keeper DELINQUENCY, not raw age. Under the deviation
        // policy the keeper guarantees |mark−truth| < θ as long as it honors its heartbeat, so a mark
        // that is merely OLD (flat market, no push needed) is still fresh-IN-PRICE and must NOT be
        // penalized (else we quote wide + miss trades for nothing). Only once age exceeds the heartbeat
        // (the keeper missed a push it promised) is the ≤θ guarantee void and the gap unobserved → then
        // charge stale_z·σ·√(age−heartbeat), ramping to the hard TTL revert = graceful degradation.
        let age = self.cur_step.saturating_sub(self.last_push_step);
        let excess = age.saturating_sub(self.push_grace()) as f64;
        let u_stale = if self.p.stale_z > 0.0 && excess > 0.0 {
            self.p.stale_z * self.sigma() * excess.sqrt() / BPS
        } else {
            0.0
        };
        let u_age = match self.mode {
            OracleMode::Adaptive { age_z, .. } if age_z > 0.0 => {
                age_z * self.sigma() * (age as f64).sqrt() / BPS
            }
            _ => 0.0,
        };
        let u_conf = self.confidence_bps * (PBPS / BPS);
        (s_vol + u + u_stale + u_age + u_conf).clamp(self.p.min_fee, self.p.max_fee)
    }

    /// Grace period (steps) before the staleness premium engages = the keeper's promised max quiet
    /// interval. Deviation: the heartbeat (a live keeper always pushes by then ⇒ premium stays 0 in a
    /// flat market). External: 0 (fixed-cadence legacy mode keys on raw age). Internal/Hybrid: no keeper.
    fn push_grace(&self) -> usize {
        match self.mode {
            OracleMode::Deviation { heartbeat, .. }
            | OracleMode::Smoothing { heartbeat, .. }
            | OracleMode::TradeOffset { heartbeat, .. }
            | OracleMode::Adaptive { heartbeat, .. } => heartbeat,
            _ => 0,
        }
    }

    /// Coverage potential Q(c) (≤0, max 0 at c=1, strictly concave). Production charges the positive
    /// finite difference Q(c_before)−Q(c_after) when a swap drains the configured output leg (unlike
    /// the old uniform mark shift `1+κ·(1−c)`, which was round-trip-extractable, PoolRepegExploit).
    /// Convex `ln c − c + 1` diverges as c→0 (the no-drain WALL for stables — deliberately NOT
    /// capped); linear `−½(c−1)²` is the bounded spring for volatiles.
    fn cov_q(&self, c: f64) -> f64 {
        let c = c.max(1e-9);
        if self.p.kappa_convex {
            c.ln() - c + 1.0
        } else {
            -0.5 * (c - 1.0).powi(2)
        }
    }

    /// Production-ordered, charge-only output-side coverage toll. The Solidity pool configures the
    /// wall per output asset; this two-leg model only has token-leg parameters, so base output is
    /// never tolled. `gross_out` is deliberately the pre-spread amount, matching `_settleQuote`.
    fn coverage_toll(&self, tout: usize, gross_out: f64) -> f64 {
        if tout != 1 || self.p.kappa_cov <= 0.0 || self.tok_liab <= 0.0 || gross_out <= 0.0 {
            return 0.0;
        }
        if gross_out >= self.tok_res {
            return gross_out;
        }
        let c0 = (self.tok_res / self.tok_liab).clamp(1e-9, 1.0);
        let c1 = ((self.tok_res - gross_out) / self.tok_liab).clamp(1e-9, 1.0);
        let dq = (self.cov_q(c0) - self.cov_q(c1)).max(0.0);
        (dq * self.p.kappa_cov * self.tok_liab).min(gross_out)
    }

    /// Gross fill (pre-fee) for selling `amount_in` of `tin` → `tout`.
    fn gross_fill(&self, tin: usize, amount_in: f64) -> (f64, f64) {
        // Mark = the lagging internal EMA. Coverage is NOT applied as a mark shift (that uniform
        // form is non-conservative / round-trip-extractable); `fill` later deducts the production
        // charge-only output toll before spread. See `coverage_toll`.
        let twap = self.quote_mark().max(1e-18);
        let disp = self.dispersion();
        let skew = self.skew(self.tok_res, self.tok_liab);
        let depth = self.depth();
        if tin == 1 {
            // sell token → base
            let exec = self.traverse(twap, disp, skew, amount_in, depth, true);
            (amount_in * exec, exec) // base out, base-per-token
        } else {
            // buy token with base: mid estimate at the skew anchor sizes the token-unit volume
            // for the real traverse (`Pricing._quoteLeg` buy path).
            let mid = match &self.p.curve {
                Some(c) => {
                    offset_to_price(twap, c.eval(5000.0 + skew * 50.0) * disp / c.disp_ref)
                }
                None => skew_to_price(twap, skew, disp),
            };
            let est = amount_in / mid; // estimated token out
            let exec = self.traverse(twap, disp, skew, est, depth, false);
            (amount_in / exec, exec) // token out, base-per-token
        }
    }

    fn fill(&self, tin: usize, tout: usize, amount_in: f64) -> Fill {
        if amount_in <= 0.0 || tin == tout {
            return Fill::default();
        }
        let (gross_out, _exec_price_bpt) = self.gross_fill(tin, amount_in);
        let out_res = if tout == 1 {
            self.tok_res
        } else {
            self.base_res
        };
        let gross_out = gross_out.min(out_res * 0.999); // can't drain the leg
        if gross_out <= 0.0 {
            return Fill::default();
        }
        // Production `_settleQuote` applies the output-side coverage toll BEFORE charging half the
        // full path spread. Keeping this entire preview in `fill` makes quote and swap identical.
        let after_toll = gross_out - self.coverage_toll(tout, gross_out);
        let spread = self.spread(); // U keys on Δ, not coverage direction (see spread())
        let fee = after_toll * spread / (2.0 * PBPS);
        let net_out = after_toll - fee;
        Fill {
            amount_in,
            amount_out: net_out,
            fee,
            exec_price: if net_out > 0.0 {
                amount_in / net_out
            } else {
                0.0
            },
        }
    }

    /// Update the internal oracle from an executed mark (base per token). Activity (per-swap) EMAs.
    fn push_mark(&mut self, exec_bpt: f64) {
        if exec_bpt <= 0.0 {
            return;
        }
        let ret = (exec_bpt / self.mark).ln().abs() * PBPS; // |log return| in PBPS
        self.fast_vol += (self.p.fast_vol_alpha / PBPS) * (ret - self.fast_vol);
        self.slow_vol += (self.p.slow_vol_alpha / PBPS) * (ret - self.slow_vol);
        self.fast_ema += self.p.fast_px_alpha * (exec_bpt - self.fast_ema);
        self.slow_ema += self.p.slow_px_alpha * (exec_bpt - self.slow_ema);
        self.mark = exec_bpt;
    }
}

impl Amm for Aimm {
    fn name(&self) -> &str {
        if self.p.lambda != 0.0
            || !self.p.kappa_convex
            || matches!(
                self.mode,
                OracleMode::Internal
                    | OracleMode::Hybrid { .. }
                    | OracleMode::Smoothing { .. }
                    | OracleMode::TradeOffset { .. }
                    | OracleMode::Adaptive { .. }
            )
        {
            "AIMM-Research"
        } else {
            "AIMM"
        }
    }

    fn on_step(&mut self, ext_px: f64, step: usize) {
        match self.mode {
            OracleMode::Internal => {} // mark evolves from fills in push_mark()
            OracleMode::External { interval } => {
                self.update_vol_from_ext(ext_px); // vol always fresh off the feed
                if interval == 0 || step.is_multiple_of(interval) {
                    // keeper push: snap the quoted mark to truth; slow EMA lags for a trend signal
                    self.slow_ema += 0.2 * (ext_px - self.slow_ema);
                    self.fast_ema = ext_px;
                    self.mark = ext_px;
                    self.target_mark = ext_px;
                    self.confidence_bps = self.pending_confidence_bps;
                    self.last_push_step = step; // reset staleness clock
                    self.pushes += 1;
                }
                // between pushes: mark frozen (this staleness is the residual LVR the sweep measures)
            }
            OracleMode::Hybrid { alpha, band } => {
                self.update_vol_from_ext(ext_px);
                self.fast_ema += alpha * (ext_px - self.fast_ema);
                self.slow_ema += (alpha * 0.2) * (ext_px - self.slow_ema);
                self.mark = self.fast_ema;
                self.target_mark = self.mark;
                self.confidence_bps = self.pending_confidence_bps;
                if (self.mark / ext_px - 1.0).abs() > band {
                    self.mark = ext_px; // deviation breaker: snap the center back
                    self.fast_ema = ext_px;
                    self.target_mark = ext_px;
                    self.confidence_bps = self.pending_confidence_bps;
                }
            }
            OracleMode::Deviation {
                threshold,
                heartbeat,
            } => {
                self.update_vol_from_ext(ext_px); // vol always fresh off the feed
                let drift = if self.mark > 0.0 {
                    (ext_px / self.mark - 1.0).abs()
                } else {
                    1.0
                };
                let stale = heartbeat > 0 && step.saturating_sub(self.last_push_step) >= heartbeat;
                if drift > threshold || stale {
                    self.slow_ema += 0.2 * (ext_px - self.slow_ema);
                    self.fast_ema = ext_px;
                    self.mark = ext_px;
                    self.target_mark = ext_px;
                    self.confidence_bps = self.pending_confidence_bps;
                    self.last_push_step = step; // reset staleness clock (both deviation + heartbeat)
                    self.pushes += 1;
                }
            }
            OracleMode::Smoothing {
                threshold,
                heartbeat,
                alpha,
                breaker,
            } => {
                self.update_vol_from_ext(ext_px);
                let drift = if self.mark > 0.0 {
                    (ext_px / self.mark - 1.0).abs()
                } else {
                    1.0
                };
                let stale = heartbeat > 0 && step.saturating_sub(self.last_push_step) >= heartbeat;
                if drift > threshold || stale {
                    self.slow_ema += 0.2 * (ext_px - self.slow_ema);
                    self.mark = ext_px;
                    self.target_mark = ext_px;
                    self.confidence_bps = self.pending_confidence_bps;
                    self.last_push_step = step;
                    self.pushes += 1;
                }
                self.fast_ema += alpha.clamp(0.0, 1.0) * (self.target_mark - self.fast_ema);
                if breaker > 0.0 && (self.fast_ema / ext_px - 1.0).abs() > breaker {
                    self.fast_ema = ext_px;
                    self.target_mark = ext_px;
                }
            }
            OracleMode::TradeOffset {
                threshold,
                heartbeat,
                decay,
                ..
            } => {
                self.update_vol_from_ext(ext_px);
                self.trade_offset *= decay.clamp(0.0, 1.0);
                let drift = if self.mark > 0.0 {
                    (ext_px / self.mark - 1.0).abs()
                } else {
                    1.0
                };
                let stale = heartbeat > 0 && step.saturating_sub(self.last_push_step) >= heartbeat;
                if drift > threshold || stale {
                    self.slow_ema += 0.2 * (ext_px - self.slow_ema);
                    self.fast_ema = ext_px;
                    self.mark = ext_px;
                    self.target_mark = ext_px;
                    self.confidence_bps = self.pending_confidence_bps;
                    self.trade_offset = 0.0;
                    self.last_push_step = step;
                    self.pushes += 1;
                }
            }
            OracleMode::Adaptive {
                theta_floor,
                theta_cap,
                heartbeat,
                latency_z,
                latency_steps,
                gas_cost_base,
                ..
            } => {
                self.update_vol_from_ext(ext_px);
                let drift = if self.mark > 0.0 {
                    (ext_px / self.mark - 1.0).abs()
                } else {
                    1.0
                };
                let spread = self.effective_spread_fraction();
                let depth_base = (self.depth() * self.mark).max(1e-18);
                let gas_gap = (2.0 * gas_cost_base.max(0.0) / depth_base).sqrt();
                let latency_risk =
                    latency_z.max(0.0) * (self.sigma() / PBPS) * (latency_steps as f64).sqrt();
                let lo = theta_floor.max(0.0);
                let hi = theta_cap.max(lo);
                let economic_threshold = (spread + gas_gap - latency_risk).clamp(lo, hi);
                let stale = heartbeat > 0 && step.saturating_sub(self.last_push_step) >= heartbeat;
                if drift > economic_threshold || stale {
                    self.slow_ema += 0.2 * (ext_px - self.slow_ema);
                    self.fast_ema = ext_px;
                    self.mark = ext_px;
                    self.target_mark = ext_px;
                    self.confidence_bps = self.pending_confidence_bps;
                    self.last_push_step = step;
                    self.pushes += 1;
                }
            }
        }
    }

    fn tick(&mut self, step: usize) {
        self.cur_step = step;
    }

    fn push_count(&self) -> usize {
        self.pushes
    }

    fn quote(&self, tin: usize, tout: usize, amount_in: f64) -> f64 {
        self.fill(tin, tout, amount_in).amount_out
    }

    fn swap(&mut self, tin: usize, tout: usize, amount_in: f64) -> f64 {
        let f = self.fill(tin, tout, amount_in);
        if f.amount_out <= 0.0 {
            return 0.0;
        }
        let twap = self.quote_mark().max(1e-18);
        let out = f.amount_out;
        if tin == 1 {
            self.tok_res += amount_in;
            self.base_res -= out;
        } else {
            self.base_res += amount_in;
            self.tok_res -= out;
        }
        if let OracleMode::TradeOffset {
            gain, max_offset, ..
        } = self.mode
        {
            // Buy token => positive information; sell token => negative. The trader executes against
            // the PRE-update quote, so the residual can only affect subsequent flow. Normalizing by
            // post-trade TVL makes the response depth-aware and comparable across pool sizes.
            let signed_base = if tin == 0 {
                amount_in
            } else {
                -amount_in * twap
            };
            let tvl = (self.base_res + self.tok_res * twap).max(1e-18);
            self.trade_offset = (self.trade_offset + gain * signed_base / tvl)
                .clamp(-max_offset.abs(), max_offset.abs());
        }
        // Only the Internal oracle walks its mark from executed fills. In External/Hybrid the mark
        // is controlled by on_step (keeper push / recenter), so fills don't move it.
        if self.mode == OracleMode::Internal {
            let exec_bpt = if tin == 1 {
                f.exec_price.recip()
            } else {
                f.exec_price
            };
            self.push_mark(exec_bpt);
        }
        out
    }

    fn spot(&self, tin: usize, _tout: usize) -> f64 {
        // marginal price as input-per-output, from a vanishingly small quote
        let probe = (if tin == 1 {
            self.tok_res
        } else {
            self.base_res
        }) * 1e-6;
        let out = self.quote(tin, 1 - tin, probe);
        if out > 0.0 { probe / out } else { 0.0 }
    }

    fn reserve(&self, i: usize) -> f64 {
        if i == 1 { self.tok_res } else { self.base_res }
    }

    fn coverage(&self, i: usize) -> f64 {
        let (r, l) = if i == 1 {
            (self.tok_res, self.tok_liab)
        } else {
            (self.base_res, self.base_liab)
        };
        if l > 0.0 { r / l } else { 1.0 }
    }

    fn tvl(&self, prices: &[f64]) -> f64 {
        self.base_res * prices[0] + self.tok_res * prices[1]
    }
}

/// Clamp + scale a PBPS price offset onto the mark: price = mark·max(0, 1 + offset/PBPS).
/// (`Pricing._offsetToPrice`)
fn offset_to_price(mark: f64, offset_pbps: f64) -> f64 {
    mark * (PBPS + offset_pbps).max(0.0) / PBPS
}

/// skew → absolute price for the no-profile fallback: offset = skew·disp/100.
/// (`Pricing._skewToPrice`)
fn skew_to_price(mark: f64, skew: f64, disp: f64) -> f64 {
    offset_to_price(mark, skew * disp / 100.0)
}
