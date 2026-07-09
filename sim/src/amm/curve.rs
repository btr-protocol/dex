//! Curve baselines: StableSwap (2-asset) and a faithful 2-asset CryptoSwap (Curve v2).
//!
//! StableSwap invariant (n=2): A·n^n·Σx + D = A·n^n·D + D^(n+1)/(n^n·Πx). Solved via Newton for D
//! (given reserves) and for the output balance y (given the input). Near-flat depth around the peg,
//! steep at the edges — the canonical stablecoin competitor.
//!
//! CryptoSwap (Curve v2): a faithful port of the twocrypto-ng math + rebalancing logic (Egorov,
//! "Automatic market-making with dynamic peg"), NOT a StableSwap approximation. Balances are held in
//! price-scaled coordinates `xp = [bal0, bal1·price_scale]`; the gamma-modified invariant
//!
//!   K0 = N^N·Π(xp) / D^N ,   K = A·γ²·K0 / (γ + 1 − K0)²
//!   K·D^(N−1)·Σxp + Π(xp) = K·D^N + (D/N)^N
//!
//! makes the pool near-constant-price (StableSwap-flat) within ~γ of the internal `price_scale` and
//! transitions to constant-product far away. `D` (given balances) and `y` (given the input balance)
//! are found by the exact Curve `newton_D` / `newton_y` iterations, ported to f64. The internal EMA
//! (`price_oracle`) tracks the pool's realized spot and `tweak_price` repegs `price_scale` toward it
//! ONLY when self-funded by banked fees (`new_virtual_price² > xcp_profit`, Curve's no-loss gate) —
//! this profit-gated repeg is exactly why Curve survives an internal oracle where a bounded-quote AMM
//! bleeds. A dynamic fee (`mid_fee` near balance → `out_fee` when imbalanced) completes the design.
//! Pure CFMM: reprices via arb; `on_step` is a no-op.
//!
//! Parameters are the Curve v2 twocrypto-ng factory defaults for a volatile pair (source: curvefi/
//! twocrypto-ng `TwocryptoMath.vy` / `Twocrypto.vy`, `A_MULTIPLIER=10000`, `N_COINS=2`), chosen to
//! reproduce CryptoSwap behavior — NOT tuned against the AIMM baseline. See [`CurveCrypto::new`].

use super::Amm;

/// Curve's `A_MULTIPLIER` (fixed-point scale on the stored `A`). `ANN = A·N^N·A_MULTIPLIER`, so the
/// invariant coefficient in `K = A_c·γ²·K0/(γ+1−K0)²` is `A_c = ANN/(N^N·A_MULTIPLIER)`.
const A_MULTIPLIER: f64 = 10_000.0;
/// Stored `A` (= ANN, already ×N^N×A_MULTIPLIER). Twocrypto-ng factory default for a volatile pool.
/// Range check: MIN_A = N^N·A_MULTIPLIER/10 = 4000, MAX_A = 4·10^7 ⇒ 400000 is valid. A_c = 10.
const CRYPTO_ANN: f64 = 400_000.0;
/// Curve v2 `gamma` (twocrypto-ng volatile default). Controls the width of the flat region.
const CRYPTO_GAMMA: f64 = 0.000_145;

/// Solve the StableSwap invariant for D by Newton's method (2 assets).
pub(crate) fn solve_d(x: f64, y: f64, amp: f64) -> f64 {
    let s = x + y;
    if s == 0.0 {
        return 0.0;
    }
    let n = 2.0;
    let ann = amp * n * n; // A·n^n
    let mut d = s;
    for _ in 0..64 {
        // D_p = D^(n+1) / (n^n·Πx)
        let dp = d * d * d / (n * n * x * y);
        let d_prev = d;
        d = ((ann * s + dp * n) * d) / ((ann - 1.0) * d + (n + 1.0) * dp);
        if (d - d_prev).abs() <= 1e-6 {
            break;
        }
    }
    d
}

/// Given new input balance x1 (post-trade reserve of the input token), solve for the output token
/// balance y that preserves D.
pub(crate) fn solve_y(x1: f64, d: f64, amp: f64) -> f64 {
    let n = 2.0;
    let ann = amp * n * n;
    // c = D^(n+1) / (n^n · ann · x1) ; b = x1 + D/ann ; y^2 + (b - D) y - c = 0 (Newton)
    let c = d * d * d / (n * n * ann * x1);
    let b = x1 + d / ann;
    let mut y = d;
    for _ in 0..64 {
        let y_prev = y;
        y = (y * y + c) / (2.0 * y + b - d);
        if (y - y_prev).abs() <= 1e-6 {
            break;
        }
    }
    y
}

#[derive(Debug, Clone)]
pub struct CurveStable {
    pub x: f64, // token reserve (idx 1)
    pub y: f64, // base reserve (idx 0)
    pub amp: f64,
    pub fee: f64,
}

impl CurveStable {
    /// `amp` = amplification A. Seed 50/50 by value at `price`.
    pub fn new(price: f64, base_value: f64, amp: f64, fee: f64) -> Self {
        Self { x: (base_value / 2.0) / price, y: base_value / 2.0, amp, fee }
    }
    /// out (net of fee) for selling `amt` of `tin`. NB: StableSwap treats balances 1:1, so a
    /// non-unity price pair must be pre-scaled by the caller; here used for near-peg stable/stable.
    fn out(&self, tin: usize, amt: f64) -> f64 {
        let d = solve_d(self.x, self.y, self.amp);
        let (out, _) = if tin == 1 {
            let y2 = solve_y(self.x + amt, d, self.amp);
            (self.y - y2, y2)
        } else {
            let x2 = solve_y(self.y + amt, d, self.amp);
            (self.x - x2, x2)
        };
        (out * (1.0 - self.fee)).max(0.0)
    }
}

impl Amm for CurveStable {
    fn name(&self) -> &str {
        "CurveStable"
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
        if tin == 1 {
            self.x += amount_in;
            self.y -= o;
        } else {
            self.y += amount_in;
            self.x -= o;
        }
        o
    }
    fn spot(&self, tin: usize, tout: usize) -> f64 {
        // marginal price via a small probe
        let probe = self.reserve(tin) * 1e-7;
        let o = self.quote(tin, tout, probe);
        if o > 0.0 {
            probe / o
        } else {
            0.0
        }
    }
    fn reserve(&self, i: usize) -> f64 {
        if i == 1 {
            self.x
        } else {
            self.y
        }
    }
    fn tvl(&self, prices: &[f64]) -> f64 {
        self.x * prices[1] + self.y * prices[0]
    }
}

/// Solve the CryptoSwap invariant for `D` given price-scaled balances (Curve v2 `newton_D`, N=2),
/// ported to f64. `ann = A·N^N·A_MULTIPLIER`. Returns `None` on non-convergence / degenerate input
/// (caller treats as not-fillable), never panics or yields a non-positive/NaN `D`.
fn cx_newton_d(ann: f64, gamma: f64, x0: f64, x1: f64) -> Option<f64> {
    // sort descending (Curve does; keeps the initial guess + updates well-conditioned)
    let (a, b) = if x0 >= x1 { (x0, x1) } else { (x1, x0) };
    if !(a > 0.0) || !(b > 0.0) || !gamma.is_finite() {
        return None;
    }
    let s = a + b;
    let mut d = 2.0 * (a * b).sqrt(); // constant-product initial guess: N·geomean(x)
    let g1 = 1.0 + gamma; // γ + 1
    for _ in 0..255 {
        let d_prev = d;
        if !(d > 0.0) {
            return None;
        }
        // K0 = N^N·Πx/D^N = 4·a·b/D²   (dimensionless, = 1 at balance)
        let k0 = 4.0 * a * b / (d * d);
        let g1k0 = (g1 - k0).abs().max(1e-18); // |γ + 1 − K0|, guarded against 0
        // mul1 = D·(γ+1−K0)²·A_MULTIPLIER / (γ²·ANN)
        let mul1 = d / gamma * g1k0 / gamma * g1k0 * A_MULTIPLIER / ann;
        // mul2 = 2·N·K0 / (γ+1−K0)   (N=2)
        let mul2 = 4.0 * k0 / g1k0;
        // −F'(D) (up to the positive Newton scaling Curve uses)
        let neg_fprime = (s + s * mul2) + mul1 * 2.0 / k0 - mul2 * d;
        if !(neg_fprime > 0.0) {
            return None;
        }
        let d_plus = d * (neg_fprime + s) / neg_fprime;
        let mut d_minus = d * d / neg_fprime;
        if 1.0 > k0 {
            d_minus += d * (mul1 / neg_fprime) * (1.0 - k0) / k0;
        } else {
            d_minus -= d * (mul1 / neg_fprime) * (k0 - 1.0) / k0;
        }
        d = if d_plus > d_minus { d_plus - d_minus } else { (d_minus - d_plus) * 0.5 };
        if !d.is_finite() {
            return None;
        }
        if (d - d_prev).abs() <= (d * 1e-12).max(1e-9) {
            return Some(d);
        }
    }
    None
}

/// Solve for the price-scaled balance `x[i]` given `x[1-i]` and invariant `D` (Curve v2 `newton_y`
/// fallback, N=2), ported to f64. `None` on non-convergence / degenerate input.
fn cx_newton_y(ann: f64, gamma: f64, x: [f64; 2], d: f64, i: usize) -> Option<f64> {
    let x_j = x[1 - i];
    if !(x_j > 0.0) || !(d > 0.0) || !gamma.is_finite() {
        return None;
    }
    let mut y = d * d / (4.0 * x_j); // = D²/(x_j·N²), N=2
    let k0_i = 2.0 * x_j / d; //   N·x_j/D, N=2
    let g1 = 1.0 + gamma;
    for _ in 0..255 {
        let y_prev = y;
        let k0 = k0_i * y * 2.0 / d; // K0_i·y·N/D = 4·x_j·y/D²
        let ssum = x_j + y;
        let g1k0 = (g1 - k0).abs().max(1e-18);
        let mul1 = d / gamma * g1k0 / gamma * g1k0 * A_MULTIPLIER / ann;
        let mul2 = 1.0 + 2.0 * k0 / g1k0;
        let mut yfprime = y + ssum * mul2 + mul1;
        let dyfprime = d * mul2;
        if yfprime < dyfprime {
            y = y_prev * 0.5; // step diverged; halve and retry (Curve does this)
            continue;
        }
        yfprime -= dyfprime;
        let fprime = yfprime / y;
        if !(fprime > 0.0) {
            return None;
        }
        let mut y_minus = mul1 / fprime;
        let y_plus = (yfprime + d) / fprime + y_minus / k0;
        y_minus += ssum / fprime;
        y = if y_plus < y_minus { y_prev * 0.5 } else { y_plus - y_minus };
        if !y.is_finite() {
            return None;
        }
        if (y - y_prev).abs() <= (y.abs() * 1e-12).max(1e-9) {
            return Some(y);
        }
    }
    None
}

/// 2-asset Curve v2 CryptoSwap. Reserves in real token units (`bal0` = base/numeraire idx 0,
/// `bal1` = volatile token idx 1); the gamma-modified invariant acts on price-scaled balances
/// `xp = [bal0, bal1·price_scale]`. Internal EMA + profit-gated repeg (`tweak_price`) recenter the
/// concentration; a dynamic fee scales from `mid_fee` (balanced) to `out_fee` (imbalanced). Pure
/// CFMM: reprices via arbitrage, `on_step` is a no-op.
#[derive(Debug, Clone)]
pub struct CurveCrypto {
    pub bal0: f64,        // base reserve (idx 0, numeraire, price 1.0)
    pub bal1: f64,        // volatile token reserve (idx 1)
    pub price_scale: f64, // internal repeg price (base per token)
    pub d: f64,           // cached invariant D (consistent with current balances + price_scale)
    pub price_oracle: f64, // internal EMA of the pool's realized spot
    pub last_prices: f64,  // pool spot after the last trade (feeds the EMA)
    pub xcp_profit: f64,   // cumulative pool growth measure (Curve's no-loss ledger; never decreases)
    pub virtual_price: f64, // xcp / total_supply (LP share value; may dip only at a funded repeg)
    pub total_supply: f64, // fixed at the initial xcp so virtual_price starts at 1.0
    pub ann: f64,          // A·N^N·A_MULTIPLIER
    pub gamma: f64,
    pub mid_fee: f64,             // fee near balance (fraction)
    pub out_fee: f64,             // fee when imbalanced (fraction)
    pub fee_gamma: f64,           // controls how fast fee ramps mid→out with imbalance
    pub allowed_extra_profit: f64, // repeg margin (prevents dust rebalances)
    pub adjustment_step: f64,     // min price_scale move per repeg
    pub ema_alpha: f64,           // EMA weight on the OLD oracle per trade (∈(0,1), larger = slower)
}

impl CurveCrypto {
    /// Seed 50/50 by value at `price` (so the price-scaled legs start balanced, `xp0 == xp1`).
    /// `base_value` = total TVL (same basis as the other AMMs). The third argument is the legacy
    /// StableSwap amplification from the previous approximation; it is intentionally IGNORED — a
    /// faithful CryptoSwap uses fixed pool params `A`/`gamma` (not a StableSwap `A`), set below to
    /// the Curve v2 twocrypto-ng factory defaults for a volatile pair. Kept in the signature only
    /// for call-site compatibility.
    pub fn new(price: f64, base_value: f64, _legacy_amp: f64) -> Self {
        let bal0 = base_value / 2.0;
        let bal1 = (base_value / 2.0) / price;
        let ann = CRYPTO_ANN;
        let gamma = CRYPTO_GAMMA;
        // balanced seed ⇒ newton_D converges to ≈ base_value; fall back to that if it somehow fails.
        let d = cx_newton_d(ann, gamma, bal0, bal1 * price).unwrap_or(base_value);
        let total_supply = d / (2.0 * price.sqrt()); // initial xcp ⇒ virtual_price = 1.0
        Self {
            bal0,
            bal1,
            price_scale: price,
            d,
            price_oracle: price,
            last_prices: price,
            xcp_profit: 1.0,
            virtual_price: 1.0,
            total_supply,
            ann,
            gamma,
            // Curve v2 twocrypto-ng volatile-pair fee tier: mid 4 bps, out 40 bps.
            mid_fee: 0.0004,
            out_fee: 0.004,
            fee_gamma: 0.000_23,
            allowed_extra_profit: 2e-6,
            adjustment_step: 0.000_146,
            // No wall clock in the sim; the real pool uses alpha = exp(-dt/ma_time) per block. We
            // apply a fixed per-trade smoothing (weight on the old oracle) ⇒ a slow EMA (~34-trade
            // half-life). On a near-flat path oracle ≈ price_scale, so repegs are rare + tiny.
            ema_alpha: 0.98,
        }
    }

    /// Dynamic fee fraction from the price-scaled balances `xp` (Curve v2 `_fee`): `mid_fee` when
    /// perfectly balanced, ramping monotonically to `out_fee` as the pool skews.
    fn fee_frac(&self, xp: [f64; 2]) -> f64 {
        let sum = xp[0] + xp[1];
        if !(sum > 0.0) {
            return self.out_fee;
        }
        // balance indicator: N^N·Πxp/(Σxp)² = 1 at balance → 0 as one leg dominates
        let b = 4.0 * xp[0] * xp[1] / (sum * sum);
        // reduce the slope with fee_gamma: g = fg·b / (fg·b + 1 − b)
        let denom = self.fee_gamma * b + 1.0 - b;
        let g = if denom > 0.0 { self.fee_gamma * b / denom } else { 0.0 };
        self.mid_fee * g + self.out_fee * (1.0 - g)
    }

    /// Marginal spot price of the token in base (Curve v2 `get_p`, scaled result ×`price_scale`).
    /// ≈ `price_scale` at balance; moves correctly with inventory.
    fn get_p_scaled(&self, xp: [f64; 2], d: f64) -> f64 {
        if !(d > 0.0) || !(xp[0] > 0.0) || !(xp[1] > 0.0) {
            return 1.0;
        }
        let k0 = 4.0 * xp[0] * xp[1] / (d * d);
        let g = self.gamma;
        let g1 = 1.0 + g;
        let gk0 = 2.0 * k0 * k0 * k0 + g1 * g1 - k0 * k0 * (3.0 + 2.0 * g);
        let nnag2 = self.ann * g * g / A_MULTIPLIER; // N^N·A·γ²
        let denom = gk0 + nnag2 * xp[0] / d * k0;
        if !(denom > 0.0) {
            return 1.0;
        }
        let num = xp[0] * (gk0 + nnag2 * xp[1] / d * k0) / xp[1];
        num / denom // dimensionless; caller multiplies by price_scale for base-per-token
    }

    /// Pool spot: base per token (idx0 per idx1), fee-free.
    fn spot_01(&self) -> f64 {
        let xp = [self.bal0, self.bal1 * self.price_scale];
        (self.get_p_scaled(xp, self.d) * self.price_scale).max(0.0)
    }

    /// Compute the net output for selling `amt` of `tin`, and the resulting REAL balances (input
    /// added, net output removed, fee retained in the pool). Non-mutating. `None` if not fillable.
    fn dy_and_balances(&self, tin: usize, amt: f64) -> Option<(f64, f64, f64)> {
        if !(amt > 0.0) || (tin != 0 && tin != 1) {
            return None;
        }
        let ps = self.price_scale;
        let (mut b0, mut b1) = (self.bal0, self.bal1);
        if tin == 0 {
            b0 += amt;
        } else {
            b1 += amt;
        }
        let xp = [b0, b1 * ps];
        let j = 1 - tin; // output coin
        let y = cx_newton_y(self.ann, self.gamma, xp, self.d, j)?;
        if !y.is_finite() || y <= 0.0 || y >= xp[j] {
            return None;
        }
        let dy_scaled = xp[j] - y;
        // gross output in real units (divide out price_scale on the token leg)
        let dy_real = if j == 1 { dy_scaled / ps } else { dy_scaled };
        // dynamic fee on the post-trade (pre-fee) scaled balances
        let mut xp_after = xp;
        xp_after[j] = y;
        let fee_frac = self.fee_frac(xp_after);
        let dy_net = dy_real * (1.0 - fee_frac);
        if !dy_net.is_finite() || dy_net <= 0.0 {
            return None;
        }
        // fee stays in the pool: reduce the output reserve by the NET amount only
        if j == 0 {
            b0 -= dy_net;
        } else {
            b1 -= dy_net;
        }
        Some((dy_net, b0, b1))
    }

    /// Execute the swap: commit balances, recompute `D` on the post-fee balances, then `tweak_price`.
    fn exchange(&mut self, tin: usize, amt: f64) -> f64 {
        let Some((dy, b0, b1)) = self.dy_and_balances(tin, amt) else {
            return 0.0;
        };
        self.bal0 = b0;
        self.bal1 = b1;
        let xp = [b0, b1 * self.price_scale];
        let new_d = cx_newton_d(self.ann, self.gamma, xp[0], xp[1]).unwrap_or(self.d);
        self.tweak_price(xp, new_d);
        dy
    }

    /// Curve v2 `tweak_price`: update the internal EMA oracle, bank profit into `xcp_profit`, and
    /// repeg `price_scale` toward the oracle ONLY when the move is self-funded by banked fees
    /// (`new_virtual_price² > xcp_profit`, the no-loss guarantee — equivalent to the whitepaper
    /// `2·vp − 1 > xcp_profit` to first order). `xp` = post-fee price-scaled balances, `new_d` its D.
    fn tweak_price(&mut self, xp: [f64; 2], new_d: f64) {
        // EMA of the pool spot, using the PREVIOUS trade's spot (capped at 2×price_scale like Curve).
        let capped = self.last_prices.min(2.0 * self.price_scale);
        self.price_oracle = capped * (1.0 - self.ema_alpha) + self.price_oracle * self.ema_alpha;
        // record the current post-trade spot for the next EMA step
        let sp = self.get_p_scaled(xp, new_d) * self.price_scale;
        if sp.is_finite() && sp > 0.0 {
            self.last_prices = sp;
        }

        // profit numbers at the CURRENT price_scale (fees left in the pool grow D ⇒ xcp ⇒ vp)
        let old_vp = self.virtual_price;
        let xcp = new_d / (2.0 * self.price_scale.sqrt());
        let vp = xcp / self.total_supply;
        let xcp_profit = if old_vp > 0.0 { self.xcp_profit * vp / old_vp } else { self.xcp_profit };
        self.xcp_profit = xcp_profit;

        // Rebalance only if there's enough banked profit: (vp − allowed_extra_profit)² > xcp_profit.
        let margin = vp - self.allowed_extra_profit;
        if margin * margin > xcp_profit {
            // vector distance between oracle and current scale
            let mut norm = self.price_oracle / self.price_scale;
            norm = (norm - 1.0).abs();
            let adj = self.adjustment_step.max(norm / 5.0);
            if norm > adj {
                // propose a new scale a fraction (adj/norm) of the way toward the oracle
                let p_new = (self.price_scale * (norm - adj) + adj * self.price_oracle) / norm;
                // rescale the token leg to the candidate scale and recompute D + xcp + vp there
                let xp_new = [xp[0], xp[1] * p_new / self.price_scale];
                if let Some(d2) = cx_newton_d(self.ann, self.gamma, xp_new[0], xp_new[1]) {
                    let xcp2 = d2 / (2.0 * p_new.sqrt());
                    let new_vp = xcp2 / self.total_supply;
                    // commit ONLY if the repeg does not lose LP value (self-funded from fees)
                    if new_vp > 1.0 && new_vp * new_vp > xcp_profit {
                        self.d = d2;
                        self.virtual_price = new_vp;
                        self.price_scale = p_new;
                        return;
                    }
                }
            }
        }
        // no repeg: commit the plain post-trade state
        self.d = new_d;
        self.virtual_price = vp;
    }
}

impl Amm for CurveCrypto {
    fn name(&self) -> &str {
        "CurveCrypto"
    }
    fn quote(&self, tin: usize, tout: usize, amount_in: f64) -> f64 {
        if tin == tout {
            return 0.0;
        }
        self.dy_and_balances(tin, amount_in).map(|(dy, _, _)| dy).unwrap_or(0.0)
    }
    fn swap(&mut self, tin: usize, tout: usize, amount_in: f64) -> f64 {
        if tin == tout {
            return 0.0;
        }
        self.exchange(tin, amount_in)
    }
    fn spot(&self, tin: usize, tout: usize) -> f64 {
        if tin == tout {
            return 0.0;
        }
        let s01 = self.spot_01();
        if tin == 0 {
            s01
        } else if s01 > 0.0 {
            1.0 / s01
        } else {
            0.0
        }
    }
    fn reserve(&self, i: usize) -> f64 {
        if i == 1 {
            self.bal1
        } else {
            self.bal0
        }
    }
    fn tvl(&self, prices: &[f64]) -> f64 {
        self.bal1 * prices[1] + self.bal0 * prices[0]
    }
}
