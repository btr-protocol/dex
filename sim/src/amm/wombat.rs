//! Wombat CSMM baseline (2-asset), the coverage/inventory competitor and our design lineage.
//!
//! Coverage r_i = A_i/L_i (asset/liability). Invariant D = Σ l_i·(r_i − k/r_i) with amplification
//! k ∈ (0,1) (k→1 ≈ constant-sum/flat for stables; smaller = more curved). A swap preserves D, which
//! makes trading TOWARD balance cheap and AWAY expensive — the provable coverage-convergence property
//! we want. Volatile pairs are price-scaled by an external oracle (Wombat's volatile-pool design), so
//! comparisons run on BTC/ETH just like our AIMM. Amounts held in native units; math in value space.

use super::Amm;

#[derive(Debug, Clone)]
pub struct Wombat {
    pub a_x: f64,   // token asset (idx 1), native units
    pub l_x: f64,   // token liability
    pub a_y: f64,   // base asset (idx 0)
    pub l_y: f64,   // base liability
    pub k: f64,     // amplification (0,1)
    pub fee: f64,   // haircut
    pub price: f64, // external oracle price (base per token); scales token into value space
}

impl Wombat {
    pub fn new(price: f64, base_value: f64, k: f64, fee: f64) -> Self {
        let a_y = base_value / 2.0;
        let a_x = (base_value / 2.0) / price;
        Self {
            a_x,
            l_x: a_x,
            a_y,
            l_y: a_y,
            k,
            fee,
            price,
        }
    }

    /// r − k/r for coverage r.
    #[inline]
    fn term(r: f64, k: f64) -> f64 {
        r - k / r
    }
    /// invert m = r − k/r  →  r = (m + sqrt(m² + 4k))/2  (positive root).
    #[inline]
    fn inv_term(m: f64, k: f64) -> f64 {
        (m + (m * m + 4.0 * k).sqrt()) / 2.0
    }

    /// Value-space balances (token scaled by price): (vx_asset, vx_liab, vy_asset, vy_liab).
    fn vspace(&self) -> (f64, f64, f64, f64) {
        (
            self.a_x * self.price,
            self.l_x * self.price,
            self.a_y,
            self.l_y,
        )
    }

    /// out (net of haircut) for selling `amt` of `tin`. Works in value space, converts back.
    fn out(&self, tin: usize, amt: f64) -> f64 {
        let (vxa, vxl, vya, vyl) = self.vspace();
        let (in_a, in_l, out_a, out_l, amt_v) = if tin == 1 {
            (vxa, vxl, vya, vyl, amt * self.price) // token in (value), base out
        } else {
            (vya, vyl, vxa, vxl, amt) // base in, token out (value)
        };
        // in-asset rises: new coverage + its invariant term
        let r_in0 = in_a / in_l;
        let r_in1 = (in_a + amt_v) / in_l;
        let d_in = in_l * (Self::term(r_in1, self.k) - Self::term(r_in0, self.k));
        // out-asset term must fall by d_in
        let r_out0 = out_a / out_l;
        let m1 = Self::term(r_out0, self.k) - d_in / out_l;
        let r_out1 = Self::inv_term(m1, self.k);
        let out_v = out_a - r_out1 * out_l; // value out
        let out_native = if tin == 1 { out_v } else { out_v / self.price };
        (out_native * (1.0 - self.fee)).max(0.0)
    }
}

impl Amm for Wombat {
    fn name(&self) -> &str {
        "Wombat"
    }
    fn on_step(&mut self, ext_px: f64, _step: usize) {
        self.price = ext_px; // Wombat volatile pools track an external oracle for scaling
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
            self.a_x += amount_in;
            self.a_y -= o;
        } else {
            self.a_y += amount_in;
            self.a_x -= o;
        }
        o
    }
    fn spot(&self, tin: usize, tout: usize) -> f64 {
        let probe = self.reserve(tin) * 1e-7;
        let o = self.quote(tin, tout, probe);
        if o > 0.0 { probe / o } else { 0.0 }
    }
    fn reserve(&self, i: usize) -> f64 {
        if i == 1 { self.a_x } else { self.a_y }
    }
    fn coverage(&self, i: usize) -> f64 {
        if i == 1 {
            self.a_x / self.l_x
        } else {
            self.a_y / self.l_y
        }
    }
    fn tvl(&self, prices: &[f64]) -> f64 {
        self.a_x * prices[1] + self.a_y * prices[0]
    }
}
