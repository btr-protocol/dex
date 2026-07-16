//! Avellaneda-Stoikov optimal market maker — the SOTA baseline AIMM must match or beat.
//!
//! Classic A-S (Avellaneda & Stoikov 2008, *High-frequency trading in a limit order book*):
//!   reservation price  r = s − q·γ·σ²·(T−t)
//!   optimal spread     δ_a + δ_b = γ·σ²·(T−t) + (2/γ)·ln(1 + γ/k)
//! with order-arrival intensity λ = A·exp(−k·δ). The dealer skews its mid toward off-loading
//! inventory (reservation price) and sets a vol-scaled spread trading inventory risk vs capture.
//!
//! For a *perpetual* venue the finite-horizon (T−t) term collapses the spread to zero at T, so we
//! use the ERGODIC / stationary limit (Guéant, Lehalle & Fernández-Tapia 2013, *Dealing with the
//! inventory risk*): a constant vol-scaled half-spread + a linear inventory skew that mean-reverts
//! inventory without a terminal time. This is the honest modern-SOTA dealer.
//!
//! To make it comparable to the other AMMs in the order-flow sim we give it constant-product LOCAL
//! depth centered on the reservation price (so at equal TVL its slippage curve matches a UniV2 —
//! the A-S edge shows purely as the reservation skew + vol-scaled spread, not a depth artifact),
//! and layer the A-S spread on top like a dynamic fee. Reserves move ONLY through trades (the mark
//! shift is a re-quote, never a free rebalance), so its LVR/inventory risk is the genuine A-S
//! profile — exactly what we benchmark AIMM's coverage mechanism against.

use super::Amm;

#[derive(Debug, Clone)]
pub struct AsMM {
    x: f64,        // token reserve (idx 1) — the dealt asset
    y: f64,        // base reserve (idx 0) — the numeraire
    x_target: f64, // neutral inventory (skew is 0 here); set to initial x
    mark: f64,     // external oracle mark, base per token (updated on_step)
    // A-S parameters, expressed as PRICE FRACTIONS (the classic formulas are in absolute price
    // units; here they are normalized so the dealer quotes realistic bps spreads on any asset).
    base_spread: f64, // δ0: intensity/fee-floor half-spread (fraction), ~ (1/γ)ln(1+γ/k) normalized
    inv_aversion: f64, // η: reservation shift per unit fractional inventory (the γσ²·H skew, normalized)
    // adaptive volatility (per-step |log-return| EMA) widens the spread and stiffens the skew (A-S ∝σ²)
    sigma: f64,
    vol_alpha: f64,
    last_mark: f64,
}

/// σ-sensitivity of the half-spread (A-S: spread widens with σ). `sigma` is a per-step |log-return|
/// EMA (~1e-3 at 50% ann vol), so a small multiplier adds a few bps in spikes while the intensity
/// floor `base_spread` dominates calm regimes — the correct A-S balance for a liquid asset.
const SPREAD_VEGA: f64 = 0.6;
/// σ-sensitivity of the inventory skew (A-S: reservation penalty ∝ σ²·inventory); stiffens the
/// mean-reversion pull in vol spikes. Base `inv_aversion` dominates in calm regimes.
const SKEW_VEGA: f64 = 40.0;

impl AsMM {
    /// Seed 50/50 by value at `price`. `base_spread` = floor half-spread (fraction, e.g. 0.0006 =
    /// 6 bps), `inv_aversion` = reservation shift per unit fractional inventory (e.g. 0.02 = shift
    /// the quote 2% when the dealer is 100% over/under its target). These map the classic A-S
    /// (1/γ)ln(1+γ/k) intensity term and γσ²·H inventory term into price-fraction units.
    /// ⚠ Placeholder calibration — the GLFT closed-form values are being derived by the A-S-SOTA
    /// benchmark workflow; refine `standard()` from its output.
    pub fn new(price: f64, base_value: f64, base_spread: f64, inv_aversion: f64) -> Self {
        let x0 = (base_value / 2.0) / price;
        Self {
            x: x0,
            y: base_value / 2.0,
            x_target: x0,
            mark: price,
            base_spread,
            inv_aversion,
            sigma: 0.0,
            vol_alpha: 0.06,
            last_mark: price,
        }
    }

    /// Standard A-S dealer: 6 bps floor half-spread + 2% inventory-aversion skew (a tight, liquid,
    /// inventory-controlled dealer). Vol-scaling widens both adaptively.
    pub fn standard(price: f64, base_value: f64) -> Self {
        Self::new(price, base_value, 0.0006, 0.02)
    }

    /// Reservation price r = mark·(1 − η·q_norm·(1+SKEW_VEGA·σ)). Long inventory (q>0) ⇒ r<mark ⇒
    /// quote cheaper to shed; short ⇒ r>mark ⇒ dearer to acquire. This is the A-S inventory skew;
    /// it mean-reverts inventory (arb/organic flow toward the cheaper side pulls q back to target).
    fn reservation(&self) -> f64 {
        let q_norm = if self.x_target > 0.0 {
            ((self.x - self.x_target) / self.x_target).clamp(-1.0, 1.0)
        } else {
            0.0
        };
        let skew = (self.inv_aversion * q_norm * (1.0 + SKEW_VEGA * self.sigma)).clamp(-0.5, 0.5);
        (self.mark * (1.0 - skew)).max(1e-12)
    }

    /// Half-spread δ = δ0 + SPREAD_VEGA·σ (intensity floor + vol-scaled inventory-risk term).
    fn half_spread(&self) -> f64 {
        (self.base_spread + SPREAD_VEGA * self.sigma).clamp(0.0, 0.25)
    }

    fn out(&self, tin: usize, amt: f64) -> f64 {
        if amt <= 0.0 {
            return 0.0;
        }
        let r = self.reservation();
        let d = self.half_spread();
        if tin == 0 {
            // buy token with base `amt` at ask = r·(1+d); constant-product local depth on reserve x.
            let pa = r * (1.0 + d);
            // token_out = x·amt / (pa·x + amt)  (Δtok for Δbase against virtual base reserve pa·x)
            (self.x * amt / (pa * self.x + amt)).max(0.0).min(self.x)
        } else {
            // sell `amt` token at bid = r·(1−d); base_out = (pb·x)·amt / (x + amt)
            let pb = r * (1.0 - d);
            ((pb * self.x) * amt / (self.x + amt)).max(0.0).min(self.y)
        }
    }
}

impl Amm for AsMM {
    fn name(&self) -> &str {
        "AvellanedaStoikov"
    }
    fn quote(&self, tin: usize, tout: usize, amount_in: f64) -> f64 {
        if tin == tout {
            return 0.0;
        }
        self.out(tin, amount_in)
    }
    fn swap(&mut self, tin: usize, tout: usize, amount_in: f64) -> f64 {
        if tin == tout {
            return 0.0;
        }
        let o = self.out(tin, amount_in);
        if tin == 0 {
            self.y += amount_in;
            self.x -= o;
        } else {
            self.x += amount_in;
            self.y -= o;
        }
        o
    }
    /// Called each step with the true external price: re-quote off the new mark + update adaptive σ.
    fn on_step(&mut self, external_price: f64, _step: usize) {
        if external_price > 0.0 {
            let ret = (external_price / self.last_mark.max(1e-12)).ln().abs();
            self.sigma += self.vol_alpha * (ret - self.sigma);
            self.last_mark = external_price;
            self.mark = external_price;
        }
    }
    fn spot(&self, tin: usize, _tout: usize) -> f64 {
        // marginal fair price = reservation mid (spread deters arb inside δ, which is the point).
        let r = self.reservation();
        if tin == 0 { r } else { 1.0 / r }
    }
    fn reserve(&self, i: usize) -> f64 {
        if i == 1 { self.x } else { self.y }
    }
    /// Inventory ratio vs the neutral target — the A-S analog of coverage (skews price to
    /// mean-revert it, rather than pegging it via a coverage wall). Populates the re-peg chart
    /// so A-S inventory management is visible alongside AIMM's coverage.
    fn coverage(&self, _i: usize) -> f64 {
        if self.x_target > 0.0 {
            self.x / self.x_target
        } else {
            1.0
        }
    }
    fn tvl(&self, prices: &[f64]) -> f64 {
        self.x * prices[1] + self.y * prices[0]
    }
}
