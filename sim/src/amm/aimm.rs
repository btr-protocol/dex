//! BTR AIMM pricer (f64) — research superset of `dex/evm/src/libraries/Pricing.sol`, NOT a 1:1 mirror
//! since the feed rework. Production quotes off a FRESH external keeper mark (external-mark primary);
//! this sim retains the OracleMode axis (incl. the legacy internal dual-EMA lagging mark) to MEASURE
//! the LVR that external-mark quoting removes. Two terms here are sim-only and dropped on-chain:
//!   · the Δ/U deviation (toxic-flow) surcharge — dropped from Pricing.sol (directional=RW + no-deferred);
//!     kept here to study the fees-paper Z-Hawkes trend-widening question (keep/port is an open design call).
//!   · the dual fast/slow vol EMA — on-chain feed collapsed to a single pushed σ.
//! Shared with production (same unit constants): coverage c=R/L → linear inventory skew ψ; volatility →
//! dispersion κ; spline VWAP over the traversed depth band; asymmetric vol-band fee; coverage-aware depth amp.

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
}

const BPS: f64 = 1e4; // 0.01%
const PBPS: f64 = 1e6; // 0.0001%  (fees, offsets, dispersion)
const ORACLE_PBPS: f64 = 1e7; // 0.00001% (oracle offsets)
const WEIGHT_SUM: f64 = 200.0;

/// Per-asset AIMM parameters (token leg). Defaults match the Foundry test fixture.
#[derive(Debug, Clone)]
pub struct AimmParams {
    pub gamma: f64,    // inventory sensitivity, BPS (10000 = 1x)
    pub vega: f64,     // volatility sensitivity, BPS
    pub lambda: f64,   // deviation sensitivity, BPS
    pub min_fee: f64,  // PBPS
    pub max_fee: f64,  // PBPS
    pub min_disp: f64, // PBPS
    pub max_disp: f64, // PBPS
    pub cov_min: f64,  // 0.01% units (5000 = 50%)
    pub cov_max: f64,  // 0.01% units (20000 = 200%)
    pub depth_amp: f64,
    pub weights: Vec<f64>,
    pub knots: Vec<f64>, // len == weights.len() + 1, each in [-100, 100]
    /// Fast/slow vol-EMA smoothing (per-swap activity EMA). PBPS-denominated α like PoolOracle.
    pub fast_vol_alpha: f64,
    pub slow_vol_alpha: f64,
    /// Fast/slow price-EMA smoothing for the internal mark offsets (per-swap activity EMA).
    pub fast_px_alpha: f64,
    pub slow_px_alpha: f64,
    /// Coverage-convergence gain (vol-INDEPENDENT). Shifts the quoted mark for an under-covered
    /// asset so corrective flow re-pegs it. 0 = disabled (legacy skew-only). Per-asset: strong for
    /// stables, ~0 for volatiles (a volatile's coverage floats with inventory; forcing it = LVR).
    pub kappa_cov: f64,
    /// Shape of the coverage premium. false = linear `kappa·(1−c)` (bounded, for volatiles).
    /// true = convex `kappa·(1/c−1)` which DIVERGES as c→0 — the Wombat-grade hard no-drain wall
    /// (for stables / the peg anchor). Linear is a spring; convex is a wall.
    pub kappa_convex: bool,
    /// Upper clamp on the coverage premium (fractional, e.g. 0.05 = +5% max). Required: without it a
    /// high-kappa/low-c convex quote is unbounded. Also the stabilizing actuator saturation.
    pub prem_cap: f64,
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
            lambda: 10_000.0,
            min_fee: 1_000.0,
            max_fee: 10_000.0,
            min_disp: 1_000.0,
            max_disp: 100_000.0,
            cov_min: 5_000.0,
            cov_max: 20_000.0,
            depth_amp: 10_000.0,
            weights: vec![50.0, 50.0, 50.0, 50.0],
            knots: vec![-50.0, -25.0, 0.0, 25.0, 50.0],
            fast_vol_alpha: 1_800.0,
            slow_vol_alpha: 200.0,
            fast_px_alpha: 0.125,
            slow_px_alpha: 0.025,
            kappa_cov: 0.0,
            kappa_convex: false,
            prem_cap: 0.05,
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
    pub fast_vol: f64, // PBPS-ish vol EMA (1e6 = 100%)
    pub slow_vol: f64,
    last_ext: f64, // previous external sample (for realized-vol on the feed)
    cur_step: usize,       // current sim step (set by tick(); on-chain ≙ block.timestamp)
    last_push_step: usize, // step of the last keeper mark push (on-chain ≙ lastPushTimestamp)
    pushes: usize,         // # keeper mark pushes performed (keeper-tx / gas-cost accounting)
    /// Coverage-toll surplus (base units), banked OUTSIDE reserves so coverage c=R/L evolves only by
    /// gross trade amounts (⇒ the Q-difference toll telescopes exactly). Rebates are capped at this
    /// balance, so an improve-then-worsen round trip cannot extract more than was previously tolled.
    lp_surplus: f64,
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
            fast_vol: 1e4, // seed 1%
            slow_vol: 1e4,
            last_ext: price,
            cur_step: 0,
            last_push_step: 0,
            pushes: 0,
            lp_surplus: 0.0,
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
        let d_fc = (self.fast_ema - self.mark).abs();
        (d_fs.max(d_fc) / self.mark) * ORACLE_PBPS
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
        let denom = if under { 1.0 - crit_min } else { crit_max - 1.0 };
        let progress = numer / denom;
        let s = (self.p.gamma / BPS) * 100.0 * progress;
        let s = s.min(100.0);
        if under {
            s
        } else {
            -s
        }
    }

    /// Dispersion κ in PBPS. (`Pricing._calculateDispersion`)
    fn dispersion(&self) -> f64 {
        let scaled = (self.sigma() * self.p.vega) / (1000.0 * BPS);
        (1000.0 + scaled).clamp(self.p.min_disp, self.p.max_disp)
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
        (r + (self.p.depth_amp * (l - r) * cp) / PBPS).min(l).max(1.0)
    }

    /// Spline control points (x = cumulative depth 0..10000, y = offset in PBPS).
    fn spline_points(&self, disp: f64) -> Vec<(f64, f64)> {
        let n = self.p.weights.len();
        let mut pts = Vec::with_capacity(n + 1);
        pts.push((0.0, self.p.knots[0] * disp / 100.0));
        let mut cum = 0.0;
        for i in 0..n {
            cum += self.p.weights[i];
            pts.push((cum * BPS / WEIGHT_SUM, self.p.knots[i + 1] * disp / 100.0));
        }
        pts
    }

    /// Average price (base per token) over a traded volume, by traversing the spline depth band.
    /// `selling` = the trader sells the token into the pool. (`Pricing._traverseSplineByVolume`,
    /// BUG-2 fix: integrate over the ordered band so the mean offset keeps its true sign.)
    fn traverse(&self, twap: f64, disp: f64, skew: f64, amount_in_tok: f64, depth: f64, selling: bool) -> f64 {
        let pts = self.spline_points(disp);
        let start = 5000.0 + skew * 50.0;
        let vf = ((amount_in_tok * BPS) / depth).min(BPS);
        let end = if selling { (start - vf).max(0.0) } else { (start + vf).min(BPS) };
        let (lo, hi) = if start <= end { (start, end) } else { (end, start) };
        let width = hi - lo;
        let avg_off = if width == 0.0 {
            eval_spline(&pts, start)
        } else {
            area_spline(&pts, lo, hi) / width
        };
        let max_neg = -PBPS * 0.9;
        let avg_off = avg_off.max(max_neg);
        let price = twap * (PBPS + avg_off) / PBPS;
        price.max(twap * 0.05)
    }

    /// Asymmetric fee (spread) in PBPS for a trade with coverage `impact`. (`Pricing` path spread
    /// + CS-4 fix: Δ is ORACLE_PBPS, rescale to PBPS before forming the surcharge.)
    fn spread(&self) -> f64 {
        let s_vol = 100.0 + (self.sigma() * self.p.vega) / (100.0 * BPS);
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
            self.p.stale_z * self.sigma() * excess.sqrt()
        } else {
            0.0
        };
        (s_vol + u + u_stale).clamp(self.p.min_fee, self.p.max_fee)
    }

    /// Grace period (steps) before the staleness premium engages = the keeper's promised max quiet
    /// interval. Deviation: the heartbeat (a live keeper always pushes by then ⇒ premium stays 0 in a
    /// flat market). External: 0 (fixed-cadence legacy mode keys on raw age). Internal/Hybrid: no keeper.
    fn push_grace(&self) -> usize {
        match self.mode {
            OracleMode::Deviation { heartbeat, .. } => heartbeat,
            _ => 0,
        }
    }

    /// Coverage potential Q(c) (≤0, max 0 at c=1, strictly concave). The coverage re-peg is charged
    /// as the finite difference Q(c_before)−Q(c_after) of this potential (see `swap`), which
    /// telescopes to zero over any closed reserve loop → round-trip-neutral by construction (unlike
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

    /// Gross fill (pre-fee) for selling `amount_in` of `tin` → `tout`.
    fn gross_fill(&self, tin: usize, amount_in: f64) -> (f64, f64) {
        // Mark = the lagging internal EMA. The coverage re-peg is NOT applied here as a mark shift
        // (that uniform form is non-conservative / round-trip-extractable); it is charged in `swap`
        // as a path-integrated potential toll skimmed to LP surplus. See `cov_q`.
        let twap = self.fast_ema.max(1e-18);
        let disp = self.dispersion();
        let skew = self.skew(self.tok_res, self.tok_liab);
        let depth = self.depth();
        if tin == 1 {
            // sell token → base
            let exec = self.traverse(twap, disp, skew, amount_in, depth, true);
            (amount_in * exec, exec) // base out, base-per-token
        } else {
            // buy token with base
            let mid = {
                let pts = self.spline_points(disp);
                let off = eval_spline(&pts, 5000.0 + skew * 50.0);
                (twap * (PBPS + off) / PBPS).max(twap * 0.05)
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
        let out_res = if tout == 1 { self.tok_res } else { self.base_res };
        let gross_out = gross_out.min(out_res * 0.999); // can't drain the leg
        if gross_out <= 0.0 {
            return Fill::default();
        }
        let spread = self.spread(); // U keys on Δ, not coverage direction (see spread())
        let net_out = gross_out * (1.0 - spread / PBPS);
        let fee = gross_out - net_out;
        Fill {
            amount_in,
            amount_out: net_out,
            fee,
            exec_price: if net_out > 0.0 { amount_in / net_out } else { 0.0 },
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
        "AIMM"
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
                if (self.mark / ext_px - 1.0).abs() > band {
                    self.mark = ext_px; // deviation breaker: snap the center back
                    self.fast_ema = ext_px;
                }
            }
            OracleMode::Deviation { threshold, heartbeat } => {
                self.update_vol_from_ext(ext_px); // vol always fresh off the feed
                let drift = if self.mark > 0.0 { (ext_px / self.mark - 1.0).abs() } else { 1.0 };
                let stale = heartbeat > 0 && step.saturating_sub(self.last_push_step) >= heartbeat;
                if drift > threshold || stale {
                    self.slow_ema += 0.2 * (ext_px - self.slow_ema);
                    self.fast_ema = ext_px;
                    self.mark = ext_px;
                    self.last_push_step = step; // reset staleness clock (both deviation + heartbeat)
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
        let gross = f.amount_out;
        // Path-integrated coverage toll = Q(c_before) − Q(c_after) of the potential (see cov_q).
        // >0 ⇒ the trade WORSENS token coverage → charge (retained in reserves = the no-drain wall);
        // <0 ⇒ improves → rebate, but CAPPED at the banked surplus ledger so an improve-then-worsen
        // round trip cannot extract more than was previously tolled (round-trip-neutral, not a spring).
        let l = self.tok_liab;
        let twap = self.fast_ema.max(1e-18);
        let mut out = gross;
        if self.p.kappa_cov > 0.0 && l > 0.0 {
            // Clamp coverage to the peg (min(c,1)) before differencing the potential: Q peaks at c=1
            // and falls on both sides, so an unclamped diff lets a drain that STARTS over-covered cross
            // the peg toll-free (dQ≤0) — the wall would be bypassable from c>1. Mirrors Pricing.sol.
            let c_before = (self.tok_res / l).clamp(1e-9, 1.0);
            let tok_after = if tin == 1 { self.tok_res + amount_in } else { self.tok_res - gross };
            let c_after = (tok_after.max(0.0) / l).clamp(1e-9, 1.0);
            let toll_base = twap * l * self.p.kappa_cov * (self.cov_q(c_before) - self.cov_q(c_after));
            let toll_out = if tout == 0 { toll_base } else { toll_base / twap };
            if toll_out >= 0.0 {
                out = (gross - toll_out).max(0.0); // charge: retained in the output reserve
                self.lp_surplus += (gross - out) * if tout == 0 { 1.0 } else { twap };
            } else {
                let want_base = -toll_base;
                let give_base = want_base.min(self.lp_surplus.max(0.0)); // rebate ≤ banked
                out = gross + if tout == 0 { give_base } else { give_base / twap };
                self.lp_surplus -= give_base;
            }
        }
        if tin == 1 {
            self.tok_res += amount_in;
            self.base_res -= out;
        } else {
            self.base_res += amount_in;
            self.tok_res -= out;
        }
        // Only the Internal oracle walks its mark from executed fills. In External/Hybrid the mark
        // is controlled by on_step (keeper push / recenter), so fills don't move it.
        if self.mode == OracleMode::Internal {
            let exec_bpt = if tin == 1 { f.exec_price.recip() } else { f.exec_price };
            self.push_mark(exec_bpt);
        }
        out
    }

    fn spot(&self, tin: usize, _tout: usize) -> f64 {
        // marginal price as input-per-output, from a vanishingly small quote
        let probe = (if tin == 1 { self.tok_res } else { self.base_res }) * 1e-6;
        let out = self.quote(tin, 1 - tin, probe);
        if out > 0.0 {
            probe / out
        } else {
            0.0
        }
    }

    fn reserve(&self, i: usize) -> f64 {
        if i == 1 {
            self.tok_res
        } else {
            self.base_res
        }
    }

    fn coverage(&self, i: usize) -> f64 {
        let (r, l) = if i == 1 { (self.tok_res, self.tok_liab) } else { (self.base_res, self.base_liab) };
        if l > 0.0 {
            r / l
        } else {
            1.0
        }
    }

    fn tvl(&self, prices: &[f64]) -> f64 {
        self.base_res * prices[0] + self.tok_res * prices[1]
    }
}

/// Piecewise-linear interpolation of the spline at `x`. (Default profile is collinear, so this is
/// exact; concentrated profiles use monotone-cubic on-chain — a bounded approximation here.)
fn eval_spline(pts: &[(f64, f64)], x: f64) -> f64 {
    if pts.is_empty() {
        return 0.0;
    }
    if x <= pts[0].0 {
        return pts[0].1;
    }
    let last = pts.len() - 1;
    if x >= pts[last].0 {
        return pts[last].1;
    }
    for w in pts.windows(2) {
        let (x0, y0) = w[0];
        let (x1, y1) = w[1];
        if x <= x1 {
            let t = (x - x0) / (x1 - x0);
            return y0 + t * (y1 - y0);
        }
    }
    pts[last].1
}

/// Integral of the piecewise-linear spline over `[lo, hi]` (lo <= hi).
fn area_spline(pts: &[(f64, f64)], lo: f64, hi: f64) -> f64 {
    if hi <= lo || pts.is_empty() {
        return 0.0;
    }
    let mut acc = 0.0;
    let mut x = lo;
    while x < hi {
        // advance through whichever segment contains x
        let next_knot = pts.iter().map(|p| p.0).find(|&xk| xk > x).unwrap_or(hi).min(hi);
        let xa = x;
        let xb = next_knot;
        acc += 0.5 * (eval_spline(pts, xa) + eval_spline(pts, xb)) * (xb - xa);
        x = xb;
        if xb == lo {
            break;
        }
    }
    acc
}
