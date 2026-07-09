//! Uniswap V2 constant-product baseline (x*y=k). token = idx 1, base = idx 0. Static fee.
//! The "fragmented full-range" reference the pooling capital-efficiency theorem targets.

use super::Amm;

#[derive(Debug, Clone)]
pub struct UniV2 {
    pub x: f64, // token reserve
    pub y: f64, // base reserve
    pub fee: f64,
}

impl UniV2 {
    /// Seed with `base_value` total TVL at `price` (base per token), 50/50 by value.
    pub fn new(price: f64, base_value: f64, fee: f64) -> Self {
        let y = base_value / 2.0;
        Self { x: (base_value / 2.0) / price, y, fee }
    }
    fn out(&self, tin: usize, amt_in: f64) -> f64 {
        let a = amt_in * (1.0 - self.fee);
        if tin == 1 {
            (self.y * a) / (self.x + a) // token in -> base out
        } else {
            (self.x * a) / (self.y + a) // base in -> token out
        }
    }
}

impl Amm for UniV2 {
    fn name(&self) -> &str {
        "UniV2"
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
    fn spot(&self, tin: usize, _tout: usize) -> f64 {
        if tin == 1 {
            self.x / self.y
        } else {
            self.y / self.x
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
