//! Order-flow simulation engine: drive an [`Amm`] with organic + toxic (arbitrage) flow over a
//! price path and measure realized LP economics — net P&L vs HODL, LVR, and traded volume.
//!
//! Headline metric = **net P&L vs HODL** at the final external price: the LP's reserves valued at
//! the final price, minus the initial reserves valued at the final price (= fees − impermanent
//! loss/LVR). Compared across AMMs on the *same* path + flow, it ranks designs for LP welfare.
//! LVR is tracked independently from the arbitrageurs' realized profit (= LP loss to toxic flow).

use super::Amm;

/// Deterministic xorshift64* RNG — reproducible per seed, no external dep (`Math.random` is banned
/// in this stack anyway; sims must be seed-reproducible).
struct Rng(u64);
impl Rng {
    #[inline]
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    #[inline]
    fn unit(&mut self) -> f64 {
        ((self.next() >> 11) as f64) / ((1u64 << 53) as f64)
    }
    /// Standard normal via Box–Muller.
    fn norm(&mut self) -> f64 {
        let u1 = self.unit().max(1e-12);
        let u2 = self.unit();
        (-2.0 * u1.ln()).sqrt() * (std::f64::consts::TAU * u2).cos()
    }
}

#[derive(Debug, Clone)]
pub struct SimCfg {
    /// Organic volume per day as a multiple of TVL (e.g. 0.5 = 50%/day).
    pub daily_turnover: f64,
    /// Min |pool/ext − 1| before an arb fires.
    pub arb_threshold: f64,
    /// Organic trades per price step.
    pub trades_per_step: usize,
    /// Organic route-around: skip an organic trade if the pool's spot is more than this fraction
    /// off the external price (real flow avoids a grossly-mispriced venue; without this, organic
    /// trades dump value into a stale pool — an artifact that inverts the frequency curve).
    pub organic_maxslip: f64,
    /// Keeper push cadence (steps). An oracle-quote AMM's `on_step` (mark refresh) fires only every
    /// `push_every` steps; between pushes the mark goes STALE while the true price moves, so the arb
    /// pass picks the pool off — this is what makes intra-window LVR measurable. At `push_every=1`
    /// the mark refreshes every step (fresh-push limit): oracle-quote LVR ≈ 0 is then a DISCRETIZATION
    /// artifact, not design merit. Vary this to trace the staleness/τ* curve. CFMMs ignore it.
    pub push_every: usize,
    /// Sub-bar interpolation factor: insert `substeps` log-linear points between consecutive input
    /// prices, so the true price can move WITHIN a keeper push window even when the input bars are
    /// coarser than the push cadence. Required to model realistic fine cadences (5-30s keeper vs
    /// minute bars) honestly; `push_every` then counts in sub-steps. Default 1 = no interpolation.
    /// Organic turnover is conserved (per-trade notional scales with the fine step count).
    pub substeps: usize,
    pub seed: u64,
}

impl Default for SimCfg {
    fn default() -> Self {
        Self {
            daily_turnover: 0.5,
            arb_threshold: 0.0005,
            trades_per_step: 4,
            organic_maxslip: 0.01,
            push_every: 1,
            substeps: 1,
            seed: 0x9E37_79B9,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct Report {
    pub name: String,
    pub net_pnl: f64,
    pub net_apr: f64,
    pub lvr: f64,
    pub lvr_apr: f64,
    pub organic_vol: f64,
    pub toxic_vol: f64,
    pub tvl0: f64,
    // inventory re-peg diagnostics (token leg coverage c = R/L; target 1.0):
    pub cov_final: f64,    // coverage at end
    pub cov_max_dev: f64,  // max |c-1| over the run (excursion)
    pub cov_mean_dev: f64, // time-average |c-1| (how far off-peg it sits on average)
    // downsampled trajectories for the UI (~200 pts): pool value vs HODL, and token coverage
    pub traj_value: Vec<f64>, // pool TVL / TVL0 (LP equity, HODL-relative context via traj_hodl)
    pub traj_hodl: Vec<f64>,  // HODL value / TVL0 at the same steps
    pub traj_cov: Vec<f64>,   // token coverage c=R/L
}

/// Ornstein-Uhlenbeck (mean-reverting) price path around `p0`: `n` prices, reversion `theta`
/// per step, vol `annual_vol`. Models an asset that oscillates around a level — the regime where
/// inventory re-peg SHOULD drive coverage back to 1 (vs a pure trend, where no passive AMM pegs).
pub fn ou_path(
    p0: f64,
    n: usize,
    annual_vol: f64,
    theta: f64,
    steps_per_year: f64,
    seed: u64,
) -> Vec<f64> {
    let mut rng = Rng(seed | 1);
    let dt = 1.0 / steps_per_year;
    let sig = annual_vol * dt.sqrt();
    let ln_p0 = p0.ln();
    let mut x = ln_p0; // log-price
    let mut out = Vec::with_capacity(n);
    out.push(p0);
    for _ in 1..n {
        x += theta * (ln_p0 - x) + sig * rng.norm();
        out.push(x.exp());
    }
    out
}

/// GBM price path: `n` prices starting at `p0`, with per-step σ derived from `annual_vol`.
pub fn gbm_path(p0: f64, n: usize, annual_vol: f64, steps_per_year: f64, seed: u64) -> Vec<f64> {
    let mut rng = Rng(seed | 1);
    let dt = 1.0 / steps_per_year;
    let sig = annual_vol * dt.sqrt();
    let mut p = p0;
    let mut out = Vec::with_capacity(n);
    out.push(p);
    for _ in 1..n {
        p *= (-0.5 * sig * sig + sig * rng.norm()).exp();
        out.push(p);
    }
    out
}

/// Run one AMM over `prices` (external base-per-token path). `days` spans the path.
pub fn run(amm: &mut dyn Amm, prices: &[f64], cfg: &SimCfg, days: f64) -> Report {
    let mut rng = Rng(cfg.seed | 1);
    let p_start = prices[0];
    let tvl0 = amm.tvl(&[1.0, p_start]);
    let r0_base = amm.reserve(0);
    let r0_tok = amm.reserve(1);

    // Optional sub-bar interpolation: log-linear points between consecutive input prices so the
    // true price moves within a push window (honest fine-cadence LVR). substeps=1 → path unchanged.
    let substeps = cfg.substeps.max(1);
    let owned_fine: Vec<f64>;
    let path: &[f64] = if substeps == 1 {
        prices
    } else {
        let mut f = Vec::with_capacity(prices.len() * substeps);
        for w in prices.windows(2) {
            let (la, lb) = (w[0].max(1e-18).ln(), w[1].max(1e-18).ln());
            for s in 0..substeps {
                let t = s as f64 / substeps as f64;
                f.push((la + (lb - la) * t).exp());
            }
        }
        f.push(*prices.last().unwrap());
        owned_fine = f;
        &owned_fine
    };

    let steps = path.len();
    // organic notional (base) per individual trade
    let per_trade = if cfg.trades_per_step > 0 && steps > 0 {
        (cfg.daily_turnover * tvl0 * days) / (steps as f64 * cfg.trades_per_step as f64)
    } else {
        0.0
    };

    let mut organic_vol = 0.0;
    let mut toxic_vol = 0.0;
    let mut lvr = 0.0;
    let mut cov_max_dev = 0.0_f64;
    let mut cov_dev_sum = 0.0_f64;
    let sample_every = (steps / 200).max(1); // ~200 downsampled trajectory points
    let mut traj_value = Vec::new();
    let mut traj_hodl = Vec::new();
    let mut traj_cov = Vec::new();

    // One arbitrage pass toward `p_ext`; accumulates realized arb profit (= LP LVR) + toxic volume.
    let arb_once = |amm: &mut dyn Amm, p_ext: f64, lvr: &mut f64, toxic: &mut f64| -> bool {
        let pool_px = amm.spot(0, 1);
        if pool_px <= 0.0 || (pool_px / p_ext - 1.0).abs() <= cfg.arb_threshold {
            return false;
        }
        if pool_px < p_ext {
            let amt = amm.arb_size(0, 1, p_ext); // token cheap → buy token
            if amt <= 0.0 {
                return false;
            }
            let out = amm.swap(0, 1, amt);
            let profit = out * p_ext - amt;
            if profit > 0.0 {
                *lvr += profit;
            }
            *toxic += amt;
        } else {
            let amt = amm.arb_size(1, 0, 1.0 / p_ext); // token dear → sell token
            if amt <= 0.0 {
                return false;
            }
            let out = amm.swap(1, 0, amt);
            let profit = out - amt * p_ext;
            if profit > 0.0 {
                *lvr += profit;
            }
            *toxic += amt * p_ext;
        }
        true
    };

    let push_every = cfg.push_every.max(1);
    for (step, &p_ext) in path.iter().enumerate() {
        amm.tick(step);
        // 1) keeper push at the configured cadence. Oracle-quote AMMs refresh their mark to the
        //    current true price only every `push_every` steps; BETWEEN pushes the mark goes stale
        //    while the true price moves, so the arb pass below picks the pool off (measurable LVR).
        //    CFMMs no-op on_step and are repriced by arb every step regardless.
        if step % push_every == 0 {
            amm.on_step(p_ext, step);
        }

        // 2) arbitrage to (bounded) convergence BEFORE organic flow, so organic trades at the
        //    pool's repriced level rather than a raw stale mark.
        for _ in 0..8 {
            if !arb_once(amm, p_ext, &mut lvr, &mut toxic_vol) {
                break;
            }
        }

        // 3) organic flow — but route around a grossly-mispriced venue (real flow won't trade
        //    at a pool that is > organic_maxslip off the true price).
        for _ in 0..cfg.trades_per_step {
            let pool_px = amm.spot(0, 1);
            if pool_px <= 0.0 || (pool_px / p_ext - 1.0).abs() > cfg.organic_maxslip {
                continue;
            }
            let size_base = per_trade * rng.unit() * 2.0;
            if size_base <= 0.0 {
                continue;
            }
            if rng.unit() < 0.5 {
                let _ = amm.swap(0, 1, size_base);
                organic_vol += size_base;
            } else {
                let out = amm.swap(1, 0, size_base / p_ext);
                organic_vol += out;
            }
        }

        // 4) cleanup arb: organic pushed the pool slightly off; let arb re-converge.
        for _ in 0..4 {
            if !arb_once(amm, p_ext, &mut lvr, &mut toxic_vol) {
                break;
            }
        }

        // 5) record inventory re-peg diagnostics (token leg coverage vs target 1.0)
        let dev = (amm.coverage(1) - 1.0).abs();
        cov_max_dev = cov_max_dev.max(dev);
        cov_dev_sum += dev;

        // 6) downsampled trajectory for the UI
        if step % sample_every == 0 {
            traj_value.push(amm.tvl(&[1.0, p_ext]) / tvl0.max(1e-9));
            traj_hodl.push((r0_base + r0_tok * p_ext) / tvl0.max(1e-9));
            traj_cov.push(amm.coverage(1));
        }
    }

    let p_final = *path.last().unwrap_or(&p_start);
    let tvl_final = amm.tvl(&[1.0, p_final]);
    let hodl = r0_base + r0_tok * p_final;
    let net_pnl = tvl_final - hodl;
    let yr = if days > 0.0 { 365.0 / days } else { 0.0 };

    Report {
        name: amm.name().to_string(),
        net_pnl,
        net_apr: if tvl0 > 0.0 { net_pnl / tvl0 * yr } else { 0.0 },
        lvr,
        lvr_apr: if tvl0 > 0.0 { lvr / tvl0 * yr } else { 0.0 },
        organic_vol,
        toxic_vol,
        tvl0,
        cov_final: amm.coverage(1),
        cov_max_dev,
        cov_mean_dev: if steps > 0 {
            cov_dev_sum / steps as f64
        } else {
            0.0
        },
        traj_value,
        traj_hodl,
        traj_cov,
    }
}
