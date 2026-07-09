//! Competitive routing engine + trader-side execution metrics + constant-mix benchmark.
//!
//! `engine::run` gives every AMM the SAME flow in isolation, so a venue with a fat static fee
//! (Uni-V2 0.3%) looks like it "wins" on LP APR — nonsense in a competitive market where a router
//! sends each trade to the venue with the best execution. This module models that competition:
//! every organic trade is quoted across ALL venues and routed to the one giving the trader the most
//! output (lowest all-in cost = fee + slippage + spread). A fat-fee venue then LOSES the flow to a
//! tighter one, so realized volumes — and therefore realized APRs — reflect reality.
//!
//! It also reports what matters to the two sides separately:
//!   - TRADER: size-weighted effective execution cost (bps) on won trades, and volume won.
//!   - LP: net P&L vs buy-&-HODL AND vs a continuously-rebalanced CONSTANT-MIX portfolio. The latter
//!     is the honest LVR benchmark (Milionis et al: LVR = loss versus *rebalancing*), so
//!     net-vs-constant-mix ≈ fees − LVR.
//! Arbitrage is per-venue (each pool is repriced to truth by its own arbers).

use super::Amm;

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
}

#[derive(Debug, Clone)]
pub struct RouterCfg {
    pub daily_turnover: f64, // organic base volume/day as a fraction of one venue's TVL
    pub arb_threshold: f64,
    pub trades_per_step: usize,
    pub substeps: usize,
    pub push_every: usize,
    /// Competitive routing (true) vs naive same-flow-to-every-venue (false).
    pub competitive: bool,
    /// Slices per competitive trade. A real aggregator SPLITS a trade across venues to minimize total
    /// price impact; we approximate that greedily — each slice goes to the currently-best venue, and
    /// as a venue fills its marginal rises so later slices spill to others. 1 = winner-take-all (too
    /// sharp: a 0.5 bp edge wins ~all flow); 4–8 ≈ realistic splitting.
    pub route_slices: usize,
    pub seed: u64,
}

impl Default for RouterCfg {
    fn default() -> Self {
        Self {
            daily_turnover: 0.5,
            arb_threshold: 0.0005,
            trades_per_step: 8,
            substeps: 12,
            push_every: 2,
            competitive: true,
            route_slices: 4,
            seed: 0x9E37_79B9,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct CompReport {
    pub name: String,
    pub tvl0: f64,
    pub net_apr_hodl: f64, // (pool value − HODL) / TVL0, annualized
    pub net_apr_cm: f64,   // (pool value − constant-mix) / TVL0, annualized ≈ fees − LVR
    pub lvr_apr: f64,      // arb profit extracted / TVL0, annualized
    pub volume_won: f64,   // organic base notional routed to this venue
    pub won_share: f64,    // fraction of total organic volume won
    pub n_won: u64,
    pub trader_cost_bps: f64, // size-weighted all-in execution cost paid by traders on won trades
}

/// Build the sub-bar-interpolated fine path (log-linear), matching engine::run semantics.
fn fine_path(prices: &[f64], substeps: usize) -> Vec<f64> {
    if substeps <= 1 {
        return prices.to_vec();
    }
    let mut f = Vec::with_capacity(prices.len() * substeps);
    for w in prices.windows(2) {
        let (la, lb) = (w[0].max(1e-18).ln(), w[1].max(1e-18).ln());
        for s in 0..substeps {
            let t = s as f64 / substeps as f64;
            f.push((la + (lb - la) * t).exp());
        }
    }
    f.push(*prices.last().unwrap());
    f
}

/// One arbitrage pass on a single venue toward `p_ext`; accumulates realized arb profit (= LP LVR).
fn arb_pool(amm: &mut dyn Amm, p_ext: f64, thresh: f64, lvr: &mut f64) -> bool {
    let pool_px = amm.spot(0, 1);
    if pool_px <= 0.0 || (pool_px / p_ext - 1.0).abs() <= thresh {
        return false;
    }
    if pool_px < p_ext {
        let amt = amm.arb_size(0, 1, p_ext);
        if amt <= 0.0 {
            return false;
        }
        let out = amm.swap(0, 1, amt);
        let profit = out * p_ext - amt;
        if profit > 0.0 {
            *lvr += profit;
        }
    } else {
        let amt = amm.arb_size(1, 0, 1.0 / p_ext);
        if amt <= 0.0 {
            return false;
        }
        let out = amm.swap(1, 0, amt);
        let profit = out - amt * p_ext;
        if profit > 0.0 {
            *lvr += profit;
        }
    }
    true
}

/// Run a field of AMMs (same pair, ideally same TVL) under organic + arb flow, either competitively
/// routed (best execution wins each trade) or naively (every venue gets every trade).
pub fn run_competitive(amms: &mut [Box<dyn Amm>], prices: &[f64], cfg: &RouterCfg, days: f64) -> Vec<CompReport> {
    run_competitive_vol(amms, prices, None, cfg, days)
}

/// As [`run_competitive`], but if `bar_vol` is `Some` (per-INPUT-bar organic base notional, e.g. the
/// real vbid+vask from NX-Rates), organic flow is driven by REAL volume instead of `daily_turnover`.
/// Each coarse bar's volume is spread evenly across its sub-steps and its `trades_per_step` trades.
pub fn run_competitive_vol(amms: &mut [Box<dyn Amm>], prices: &[f64], bar_vol: Option<&[f64]>, cfg: &RouterCfg, days: f64) -> Vec<CompReport> {
    let n = amms.len();
    let sub = cfg.substeps.max(1);
    let path = fine_path(prices, sub);
    let steps = path.len();
    let p0 = path[0];

    let tvl0: Vec<f64> = amms.iter().map(|a| a.tvl(&[1.0, p0])).collect();
    let r0b: Vec<f64> = amms.iter().map(|a| a.reserve(0)).collect();
    let r0t: Vec<f64> = amms.iter().map(|a| a.reserve(1)).collect();

    // constant-mix (continuously rebalanced 50/50) per venue, seeded at that venue's TVL0.
    let mut cm_cash: Vec<f64> = tvl0.iter().map(|v| v / 2.0).collect();
    let mut cm_tok: Vec<f64> = tvl0.iter().map(|v| (v / 2.0) / p0).collect();

    let mut lvr = vec![0.0f64; n];
    let mut vol_won = vec![0.0f64; n];
    let mut n_won = vec![0u64; n];
    let mut cost_wsum = vec![0.0f64; n]; // Σ (cost_bps · size)
    let mut cost_w = vec![0.0f64; n]; // Σ size

    // organic base notional per individual trade, sized off the mean venue TVL so turnover is
    // comparable across a heterogeneous field.
    let mean_tvl = tvl0.iter().sum::<f64>() / n as f64;
    // synthetic per-trade notional (used when no real volume series is supplied)
    let syn_per_trade = if cfg.trades_per_step > 0 {
        (cfg.daily_turnover * mean_tvl * days) / (steps as f64 * cfg.trades_per_step as f64)
    } else {
        0.0
    };
    let tps = cfg.trades_per_step.max(1) as f64;

    let mut rng = Rng(cfg.seed | 1);
    let push_every = cfg.push_every.max(1);

    // record an executed fill's trader cost (all-in, vs the true price p_ext).
    let mut record = |i: usize, size_base: f64, out: f64, buy_token: bool, p_ext: f64,
                      vol_won: &mut [f64], n_won: &mut [u64], cost_wsum: &mut [f64], cost_w: &mut [f64]| {
        // cost = fraction of fair value the trader loses to fee+slippage+spread.
        let cost = if buy_token {
            let fair_tok = size_base / p_ext;
            if fair_tok > 0.0 { (fair_tok - out) / fair_tok } else { 0.0 }
        } else {
            // sell: size_base here is the token notional's base value; out is base received.
            let fair_base = size_base;
            if fair_base > 0.0 { (fair_base - out) / fair_base } else { 0.0 }
        };
        vol_won[i] += size_base;
        n_won[i] += 1;
        cost_wsum[i] += cost * 1e4 * size_base; // bps, size-weighted
        cost_w[i] += size_base;
    };

    for (step, &p_ext) in path.iter().enumerate() {
        // 0) advance every venue's step clock (oracle-quote AMMs measure staleness; baselines no-op)
        for a in amms.iter_mut() {
            a.tick(step);
        }
        // 1) keeper push at cadence
        if step % push_every == 0 {
            for a in amms.iter_mut() {
                a.on_step(p_ext, step);
            }
        }
        // 2) per-venue arbitrage to truth
        for (i, a) in amms.iter_mut().enumerate() {
            for _ in 0..8 {
                if !arb_pool(a.as_mut(), p_ext, cfg.arb_threshold, &mut lvr[i]) {
                    break;
                }
            }
        }
        // 3) organic flow — sized by real per-bar volume when supplied, else synthetic turnover.
        let per_trade = match bar_vol {
            Some(v) if !v.is_empty() => {
                let coarse = (step / sub).min(v.len() - 1);
                v[coarse] / (sub as f64 * tps)
            }
            _ => syn_per_trade,
        };
        for _ in 0..cfg.trades_per_step {
            let size_base = per_trade * rng.unit() * 2.0;
            if size_base <= 0.0 {
                continue;
            }
            let buy_token = rng.unit() < 0.5;
            if cfg.competitive {
                // split the trade into slices; each slice goes to the currently-best venue and is
                // executed, so as a venue fills its marginal rises and later slices spill to others
                // (greedy approximation of optimal multi-venue routing).
                let slices = cfg.route_slices.max(1);
                let slice_base = size_base / slices as f64;
                for _ in 0..slices {
                    let mut best_i = usize::MAX;
                    let mut best_out = 0.0f64;
                    for (i, a) in amms.iter().enumerate() {
                        let out = if buy_token {
                            a.quote(0, 1, slice_base)
                        } else {
                            a.quote(1, 0, slice_base / p_ext)
                        };
                        let cmp = if buy_token { out * p_ext } else { out };
                        if cmp > best_out {
                            best_out = cmp;
                            best_i = i;
                        }
                    }
                    if best_i == usize::MAX || best_out <= 0.0 {
                        continue;
                    }
                    let out = if buy_token {
                        amms[best_i].swap(0, 1, slice_base)
                    } else {
                        amms[best_i].swap(1, 0, slice_base / p_ext)
                    };
                    record(best_i, slice_base, out, buy_token, p_ext, &mut vol_won, &mut n_won, &mut cost_wsum, &mut cost_w);
                }
            } else {
                // naive: every venue independently gets the same trade.
                for i in 0..n {
                    let out = if buy_token {
                        amms[i].swap(0, 1, size_base)
                    } else {
                        amms[i].swap(1, 0, size_base / p_ext)
                    };
                    if out > 0.0 {
                        record(i, size_base, out, buy_token, p_ext, &mut vol_won, &mut n_won, &mut cost_wsum, &mut cost_w);
                    }
                }
            }
        }
        // 4) cleanup arb
        for (i, a) in amms.iter_mut().enumerate() {
            for _ in 0..4 {
                if !arb_pool(a.as_mut(), p_ext, cfg.arb_threshold, &mut lvr[i]) {
                    break;
                }
            }
        }
        // 5) constant-mix rebalance each venue at the current true price
        for i in 0..n {
            let tot = cm_cash[i] + cm_tok[i] * p_ext;
            cm_cash[i] = tot / 2.0;
            cm_tok[i] = (tot / 2.0) / p_ext;
        }
    }

    let p_final = *path.last().unwrap_or(&p0);
    let yr = if days > 0.0 { 365.0 / days } else { 0.0 };
    let total_vol: f64 = vol_won.iter().sum::<f64>().max(1e-9);

    (0..n)
        .map(|i| {
            let tvl_final = amms[i].tvl(&[1.0, p_final]);
            let hodl = r0b[i] + r0t[i] * p_final;
            let cm_final = cm_cash[i] + cm_tok[i] * p_final;
            CompReport {
                name: amms[i].name().to_string(),
                tvl0: tvl0[i],
                net_apr_hodl: if tvl0[i] > 0.0 { (tvl_final - hodl) / tvl0[i] * yr } else { 0.0 },
                net_apr_cm: if tvl0[i] > 0.0 { (tvl_final - cm_final) / tvl0[i] * yr } else { 0.0 },
                lvr_apr: if tvl0[i] > 0.0 { lvr[i] / tvl0[i] * yr } else { 0.0 },
                volume_won: vol_won[i],
                won_share: vol_won[i] / total_vol,
                n_won: n_won[i],
                trader_cost_bps: if cost_w[i] > 0.0 { cost_wsum[i] / cost_w[i] } else { 0.0 },
            }
        })
        .collect()
}
