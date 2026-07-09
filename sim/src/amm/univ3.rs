//! Uniswap V3 single-range concentrated-liquidity baseline (token = x = idx 1, base = y = idx 0).
//!
//! Static fee, passive position concentrated in `[p·(1−w), p·(1+w)]`. This is the LVR competitor:
//! high capital efficiency near the active price, but no inventory management or dynamic fee, so
//! arbitrageurs extract the full price-move LVR. Seeded with the same total capital as the AIMM.

use super::Amm;

#[derive(Debug, Clone)]
pub struct UniV3 {
    pub sqrt_p: f64,
    pub sqrt_pa: f64,
    pub sqrt_pb: f64,
    pub liquidity: f64,
    pub fee: f64, // fraction, e.g. 0.0005
}

impl UniV3 {
    /// `base_value` = total TVL (same basis as AIMM). `range_pct` = half-width `w`. `fee` fraction.
    pub fn new(price: f64, base_value: f64, range_pct: f64, fee: f64) -> Self {
        let (pa, pb) = (price * (1.0 - range_pct), price * (1.0 + range_pct));
        let (sp, spa, spb) = (price.sqrt(), pa.sqrt(), pb.sqrt());
        // value(L) at p0 = x·p + y = L[(1/√p − 1/√pb)·p + (√p − √pa)] = base_value
        let val_per_l = (1.0 / sp - 1.0 / spb) * price + (sp - spa);
        Self { sqrt_p: sp, sqrt_pa: spa, sqrt_pb: spb, liquidity: base_value / val_per_l, fee }
    }

    #[inline]
    fn x(&self) -> f64 {
        (self.liquidity * (1.0 / self.sqrt_p - 1.0 / self.sqrt_pb)).max(0.0)
    }
    #[inline]
    fn y(&self) -> f64 {
        (self.liquidity * (self.sqrt_p - self.sqrt_pa)).max(0.0)
    }
    #[inline]
    fn price(&self) -> f64 {
        self.sqrt_p * self.sqrt_p
    }

    /// (amount_out, new_sqrt_p) for selling `amount_in` of `tin`.
    fn fill(&self, tin: usize, amount_in: f64) -> (f64, f64) {
        let amt = amount_in * (1.0 - self.fee);
        if amt <= 0.0 {
            return (0.0, self.sqrt_p);
        }
        if tin == 1 {
            // token in → price down
            let inv = 1.0 / self.sqrt_p + amt / self.liquidity;
            let sp2 = (1.0 / inv).max(self.sqrt_pa);
            (((self.liquidity) * (self.sqrt_p - sp2)).max(0.0), sp2)
        } else {
            // base in → price up
            let sp2 = (self.sqrt_p + amt / self.liquidity).min(self.sqrt_pb);
            ((self.liquidity * (1.0 / self.sqrt_p - 1.0 / sp2)).max(0.0), sp2)
        }
    }
}

impl Amm for UniV3 {
    fn name(&self) -> &str {
        "UniV3"
    }
    fn quote(&self, tin: usize, tout: usize, amount_in: f64) -> f64 {
        if tin == tout {
            return 0.0;
        }
        self.fill(tin, amount_in).0
    }
    fn swap(&mut self, tin: usize, tout: usize, amount_in: f64) -> f64 {
        if tin == tout {
            return 0.0;
        }
        let (out, sp) = self.fill(tin, amount_in);
        self.sqrt_p = sp;
        out
    }
    fn spot(&self, tin: usize, _tout: usize) -> f64 {
        let p = self.price();
        if tin == 1 {
            1.0 / p
        } else {
            p
        }
    }
    fn reserve(&self, i: usize) -> f64 {
        if i == 1 {
            self.x()
        } else {
            self.y()
        }
    }
    fn tvl(&self, prices: &[f64]) -> f64 {
        self.x() * prices[1] + self.y() * prices[0]
    }
}
