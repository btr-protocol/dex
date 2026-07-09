//! AIMM-CI — the coverage-INVARIANT AIMM core the real-data benchmarks point to.
//!
//! Every clean winner in the competitive benchmarks (Curve, Wombat) is a coverage/CFMM-*invariant*:
//! it reprices via arbitrage, is path-conservative, and its curvature SELF-LIMITS arb size so LVR is
//! bounded — unlike a bounded offset off a lagging oracle mark (AIMM's old core), whose deep flat
//! quote lets arbs extract gap × huge size when the mark is stale.
//!
//! AIMM-CI takes that coverage invariant as its CORE (Wombat-style `D = Σ Lᵢ·(cᵢ − k/cᵢ)`, value-space,
//! token scaled by an oracle for volatile pairs) and layers on what a pure invariant LACKS: an
//! **Avellaneda-Stoikov / Glosten-Milgrom dynamic fee** — vol-scaled spread + an adverse-selection
//! surcharge on coverage-WORSENING (toxic) flow, discounted (not waived) on balancing flow. So it
//! quotes tight on benign flow (competes with Curve/Wombat) yet charges informed/toxic flow (lower net
//! LVR, more LP revenue = the A-S edge). In the hub-spoke it also keeps the capital-efficiency win.
//! ⇒ tight (trader) + LVR-resistant (curvature + fee) + capital-efficient (hub) + A-S-optimal fee.

use super::curve;
use super::Amm;

#[derive(Debug, Clone)]
pub struct AimmCi {
    pub a_x: f64, // token asset (idx 1), native units
    pub l_x: f64, // token liability
    pub a_y: f64, // base asset (idx 0)
    pub l_y: f64, // base liability
    pub k: f64,   // curvature ∈(0,1) in D=ΣL(c−k/c). term''(c)=−2k/c³ ⇒ LOW k = FLAT/constant-sum
                  // (tight center, but arb-size unbounded → needs the convex wall); HIGH k = MORE
                  // curved (bounds arb size). Stables: LOW k + wall. Volatiles: HIGHER k. (Comment
                  // was previously INVERTED — verified k→0 returns out=amt exactly = zero slippage.)
    pub price: f64, // oracle scale (base per token); reprices token into value space (volatile pools)
    // Vol-INDEPENDENT convex coverage wall (the stable/anti-drain defense): the A-S surcharge is ∝σ
    // and vanishes for pegged assets, so a flat stable book has NO adverse-selection protection. This
    // wall charges κ·(1/c−1) (→∞ as c→0) on coverage-worsening flow — a hard no-drain wall the tight
    // center gives up. Capped by prem_cap.
    pub kappa_cov: f64,
    pub prem_cap: f64,
    /// External-oracle repeg speed ∈(0,1]: 1 = snap the scale to the oracle every step (follows the
    /// trend, holds adverse inventory); <1 lags the repeg (holds less adverse inventory on trends,
    /// the essence of CryptoSwap's profit-gated repeg) at the cost of a little staleness.
    pub repeg_alpha: f64,
    /// StableSwap core: a single `k` gives uniform curvature and can't be flat-at-center AND
    /// steep-at-edge like Curve StableSwap (why we trailed Curve on stables). When `amp` is Some, the
    /// core uses Curve's StableSwap invariant (amplification A) — the flat-center/steep-edge SHAPE —
    /// with our A-S fee + convex wall layered on. For stables (price pinned at 1) it runs in native units.
    pub amp: Option<f64>,
    /// CryptoSwap core (volatiles): Curve v2's γ-concentrated band + xcp-profit-gated repeg = the
    /// inventory management that holds less adverse inventory on trends (closes the net/CMix gap our
    /// coverage-invariant leaves). Its reserves/D are self-consistent; we DON'T touch them — instead we
    /// layer our A-S vol×toxicity surcharge as a SEPARATE deduction banked to `lp_surplus` (so no
    /// invariant desync), adding the toxic-flow revenue a pure CryptoSwap lacks.
    pub crypto: Option<curve::CurveCrypto>,
    lp_surplus: f64,
    // Avellaneda-Stoikov dynamic fee (fractions):
    pub base_fee: f64,  // intensity/floor half-spread (e.g. 0.0001 = 1 bp)
    pub vega: f64,      // vol sensitivity of the spread
    pub lambda: f64,    // adverse-selection surcharge weight on coverage-worsening flow
    pub cov_rebate: f64, // fraction of the surcharge still charged on coverage-IMPROVING flow (floor)
    /// Internal-oracle mode: for STABLES the peg is known (~1), so the invariant IS the oracle — the
    /// price scale is pinned and the curve discovers the small depegs via arbitrage (Curve-style, no
    /// external keeper feed, no staleness pick-off). For volatiles keep external (price tracks the feed).
    pub internal_oracle: bool,
    // adaptive volatility (per-step |log-return| EMA off the oracle feed)
    sigma: f64,
    vol_alpha: f64,
    last_ext: f64,
}

impl AimmCi {
    pub fn new(price: f64, base_value: f64, k: f64) -> Self {
        let a_y = base_value / 2.0;
        let a_x = (base_value / 2.0) / price;
        Self {
            a_x, l_x: a_x, a_y, l_y: a_y, k, price,
            amp: None,
            crypto: None, lp_surplus: 0.0,
            kappa_cov: 0.0, prem_cap: 0.01, repeg_alpha: 1.0,
            base_fee: 0.0001, vega: 0.5, lambda: 3.0, cov_rebate: 0.5,
            internal_oracle: false,
            sigma: 0.0, vol_alpha: 0.06, last_ext: price,
        }
    }
    /// Volatile-asset config: HIGHER curvature (k=0.5) bounds arb size → lower LVR (the LP metric),
    /// + external oracle + a stronger A-S fee (vega/lambda) to tax trend pick-off. The extra
    /// curvature costs a little trader tightness but cuts the LVR that a flat coverage curve leaks.
    pub fn standard(price: f64, base_value: f64) -> Self {
        let mut s = Self::new(price, base_value, 0.85); // strong curvature bounds arb size (low LVR)
        s.vega = 1.0;
        s.lambda = 6.0;
        s
    }
    /// Volatile-asset config with the CryptoSwap CORE (γ + xcp-profit repeg) + our A-S fee. The core's
    /// own fee is zeroed so our A-S dynamic fee is the only spread; the fee is banked to lp_surplus so
    /// the core invariant is never desynced. = CryptoSwap's inventory management + the toxic-flow
    /// revenue it lacks.
    pub fn volatile_v2(price: f64, base_value: f64) -> Self {
        let mut s = Self::new(price, base_value, 0.85);
        let mut c = curve::CurveCrypto::new(price, base_value, 0.0);
        c.mid_fee = 0.0;
        c.out_fee = 0.0; // pure invariant; AIMM-CI applies its own A-S fee on top
        s.crypto = Some(c);
        s.base_fee = 0.00006; // 0.6 bp floor — tight on benign flow (wins execution) …
        s.vega = 0.6;
        s.lambda = 10.0; // … while a strong toxic surcharge (banked to LP) keeps net/CMix ahead
        s
    }

    /// A-S fee for the CryptoSwap-core path: same shape as `fee`, with the coverage signal taken from
    /// the core's value-space imbalance (out-asset balance vs D/2). `gross` is in out-asset units.
    fn crypto_fee(&self, tin: usize, gross: f64) -> f64 {
        let c = self.crypto.as_ref().unwrap();
        let (out_bal, out_px) = if tin == 1 { (c.bal0, 1.0) } else { (c.bal1, c.price_scale) };
        let half = (c.d / 2.0).max(1e-9);
        let r0 = out_bal * out_px / half;
        let r1 = (out_bal - gross).max(0.0) * out_px / half;
        self.fee(r0, r1)
    }
    /// Stable-asset config: INTERNAL oracle (no external feed — the curve discovers depegs via arb)
    /// + ultra-tight fee. NOTE: the Wombat-style coverage-invariant here is sane but does NOT match
    /// Curve StableSwap's tightness (~4-5 bps vs Curve ~1.3 bps); a StableSwap/Curve-v2 core for the
    /// stable preset is the pending upgrade (see the beat-Curve workflow). Low k = the tight regime
    /// for this invariant (high k breaks on the near-parity stable data).
    pub fn stable(base_value: f64) -> Self {
        let mut s = Self::new(1.0, base_value, 0.002);
        s.amp = Some(2000.0); // Curve-class StableSwap core = flat-center/steep-edge SHAPE
        s.internal_oracle = true;
        s.base_fee = 0.00005; // 0.5 bp
        s.vega = 0.02; // stables: the depeg path IS the 'vol' — don't let it widen the spread (quote tight)
        // stables: NO vol×toxicity surcharge — the depeg path registers as "vol" and would tax normal
        // flow (~1.9bp); adverse-selection defense here is the vol-INDEPENDENT convex wall only.
        s.lambda = 0.0;
        s.kappa_cov = 0.02; // convex no-drain wall, threshold-gated (c<0.9) → ~0 on normal flow
        s.prem_cap = 0.02;
        s.cov_rebate = 1.0;
        s
    }

    #[inline]
    fn term(r: f64, k: f64) -> f64 { r - k / r }
    #[inline]
    fn inv_term(m: f64, k: f64) -> f64 { (m + (m * m + 4.0 * k).sqrt()) / 2.0 }

    /// GROSS out (pre-fee) for selling `amt` of `tin`. StableSwap core (Curve flat-center shape) when
    /// `amp` is set — for stables (price ≡ 1, native units); else the coverage invariant (value space).
    fn gross_out(&self, tin: usize, amt: f64) -> (f64, f64, f64) {
        if let Some(amp) = self.amp {
            let d = curve::solve_d(self.a_x, self.a_y, amp);
            let (in_bal, out_a, out_l) = if tin == 1 {
                (self.a_x, self.a_y, self.l_y)
            } else {
                (self.a_y, self.a_x, self.l_x)
            };
            let out_new = curve::solve_y(in_bal + amt, d, amp);
            let gross = (out_a - out_new).max(0.0);
            return (gross, out_a / out_l, out_new / out_l);
        }
        let (vxa, vxl, vya, vyl) = (self.a_x * self.price, self.l_x * self.price, self.a_y, self.l_y);
        let (in_a, in_l, out_a, out_l, amt_v) = if tin == 1 {
            (vxa, vxl, vya, vyl, amt * self.price)
        } else {
            (vya, vyl, vxa, vxl, amt)
        };
        let r_in0 = in_a / in_l;
        let r_in1 = (in_a + amt_v) / in_l;
        let d_in = in_l * (Self::term(r_in1, self.k) - Self::term(r_in0, self.k));
        let r_out0 = out_a / out_l;
        let m1 = Self::term(r_out0, self.k) - d_in / out_l;
        let r_out1 = Self::inv_term(m1, self.k);
        let out_v = out_a - r_out1 * out_l;
        let gross = if tin == 1 { out_v } else { out_v / self.price };
        // coverage of the OUT asset before/after (for the adverse-selection gate): a swap that pushes
        // the out-asset further BELOW peg (draining it) is coverage-worsening = potentially toxic.
        (gross.max(0.0), r_out0, r_out1)
    }

    /// A-S dynamic fee (fraction): floor + vol widening + adverse-selection surcharge on the toxic
    /// (coverage-worsening) side, discounted (not waived) on balancing flow.
    fn fee(&self, r_out0: f64, r_out1: f64) -> f64 {
        let s_vol = self.base_fee + self.vega * self.sigma;
        // draining the out-asset below its pre-trade coverage AND below peg = adverse selection.
        let worsens = r_out1 < r_out0 && r_out1 < 1.0;
        let u = self.lambda * self.sigma * (r_out0 - r_out1).max(0.0); // toxicity ∝ vol × coverage drain
        let asfee = if worsens { u } else { u * self.cov_rebate };
        // vol-INDEPENDENT convex no-drain wall on coverage-worsening flow (defends the flat stable
        // book where the σ-term vanishes). Charged as a directional FEE (round-trip-safe, not an
        // extractable mark-shift). THRESHOLD-gated: ~0 for normal coverage (c > wall_c) so it doesn't
        // tax ordinary flow; diverges only as a real DRAIN pushes the out-asset toward depletion.
        let wall_c = 0.7; // only defend SEVERE drains; normal ±imbalance (c~0.9-1.1) pays ~0
        let wall = if self.kappa_cov > 0.0 && worsens && r_out1 < wall_c {
            (self.kappa_cov * (wall_c / r_out1.max(1e-6) - 1.0)).clamp(0.0, self.prem_cap)
        } else {
            0.0
        };
        (s_vol + asfee + wall).clamp(0.0, 0.5)
    }

    fn out(&self, tin: usize, amt: f64) -> f64 {
        if amt <= 0.0 {
            return 0.0;
        }
        let (gross, r0, r1) = self.gross_out(tin, amt);
        (gross * (1.0 - self.fee(r0, r1))).max(0.0)
    }
}

impl Amm for AimmCi {
    fn name(&self) -> &str {
        "AIMM-CI"
    }
    fn on_step(&mut self, ext_px: f64, _step: usize) {
        if ext_px > 0.0 {
            let ret = (ext_px / self.last_ext.max(1e-18)).ln().abs();
            self.sigma += self.vol_alpha * (ret - self.sigma);
            self.last_ext = ext_px;
            // CryptoSwap core reprices INTERNALLY (via arb + its xcp-profit repeg) — no external feed.
            // internal-oracle (stables): price pinned. external coverage-invariant: scale to the feed.
            if self.crypto.is_none() && !self.internal_oracle {
                self.price += self.repeg_alpha * (ext_px - self.price);
            }
        }
    }
    fn quote(&self, tin: usize, tout: usize, amount_in: f64) -> f64 {
        if tin == tout {
            return 0.0;
        }
        if let Some(ref c) = self.crypto {
            let gross = c.quote(tin, tout, amount_in);
            return gross * (1.0 - self.crypto_fee(tin, gross));
        }
        self.out(tin, amount_in)
    }
    fn swap(&mut self, tin: usize, tout: usize, amount_in: f64) -> f64 {
        if tin == tout {
            return 0.0;
        }
        if self.crypto.is_some() {
            // fee from pre-swap balances; execute on the core (fee=0 → moves reserves by gross + does
            // the xcp-profit-gated repeg); bank OUR A-S fee to lp_surplus (core invariant untouched).
            let gross = self.crypto.as_ref().unwrap().quote(tin, tout, amount_in);
            let fee = self.crypto_fee(tin, gross);
            let out_core = self.crypto.as_mut().unwrap().swap(tin, tout, amount_in);
            let out = out_core * (1.0 - fee);
            let out_px = if tout == 0 { 1.0 } else { self.crypto.as_ref().unwrap().price_scale };
            self.lp_surplus += (out_core - out) * out_px;
            return out;
        }
        let o = self.out(tin, amount_in);
        if tin == 1 {
            self.a_x += amount_in;
            self.a_y -= o;
        } else {
            self.a_y += amount_in;
            self.a_x -= o;
        }
        o
    }
    fn spot(&self, tin: usize, tout: usize) -> f64 {
        if let Some(ref c) = self.crypto {
            return c.spot(tin, tout);
        }
        let probe = self.reserve(tin) * 1e-7;
        let o = self.quote(tin, tout, probe);
        if o > 0.0 { probe / o } else { 0.0 }
    }
    fn reserve(&self, i: usize) -> f64 {
        if let Some(ref c) = self.crypto {
            return c.reserve(i);
        }
        if i == 1 { self.a_x } else { self.a_y }
    }
    fn coverage(&self, i: usize) -> f64 {
        if let Some(ref c) = self.crypto {
            return c.coverage(i);
        }
        if i == 1 { self.a_x / self.l_x } else { self.a_y / self.l_y }
    }
    fn tvl(&self, prices: &[f64]) -> f64 {
        if let Some(ref c) = self.crypto {
            return c.tvl(prices) + self.lp_surplus; // core value + banked A-S fee
        }
        self.a_x * prices[1] + self.a_y * prices[0]
    }
}
