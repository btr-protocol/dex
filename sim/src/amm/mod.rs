//! AMM comparison simulator (order-flow level).
//!
//! Replays a real price series through competing AMM designs — BTR **AIMM**, Uniswap **V3**
//! (concentrated single-range), and **Curve** StableSwap — under an identical flow model
//! (organic + toxic/arbitrage), and measures realized LP economics: fees captured, LVR
//! (loss-versus-rebalancing / arbitrage extraction), and net APR, decomposed by regime.
//!
//! Why order-flow and not a position-level CL model (a static concentrated-liquidity position): AIMM's edge is a
//! *dynamic* fee + inventory skew that only acts on actual flow hitting its quote function, so
//! the σ²/8 closed form cannot represent it. Every trade must be quoted against live state.
//!
//! Fidelity: production-mode pricing is `f64` mirroring the settlement formulas and ordering in
//! `dex/evm/src/libraries/Pricing.sol`. Experimental oracle modes and the optional trend surcharge
//! identify themselves as `AIMM-Research`; bit-exact integer/rounding fidelity remains in Foundry.

pub mod aimm;
pub mod aimm_ci;
pub mod as_mm;
pub mod consts;
pub mod curve;
pub mod engine;
pub mod nuquartic;
pub mod router;
pub mod univ2;
pub mod univ3;
pub mod wombat;

/// A swap quote / fill in human (f64) units. `amount_out` is net of fees.
#[derive(Debug, Clone, Copy, Default)]
pub struct Fill {
    pub amount_in: f64,
    pub amount_out: f64,
    /// Fee charged, denominated in the input token.
    pub fee: f64,
    /// Effective price paid = amount_in / amount_out (input per output).
    pub exec_price: f64,
}

/// Common interface every simulated AMM implements. Token indices are pool-local
/// (`0` = base/numeraire by convention). Prices are external/“true” quotes of token `i`
/// in base units (base per token), with `prices[0] == 1.0`.
pub trait Amm {
    /// Human-readable design name (e.g. "AIMM", "UniV3", "CurveStable").
    fn name(&self) -> &str;

    /// Quote `amount_in` of `tin` sold for `tout`, without mutating state. Returns the net
    /// `amount_out` (>= 0; 0 if not fillable).
    fn quote(&self, tin: usize, tout: usize, amount_in: f64) -> f64;

    /// Execute a swap, mutating reserves (and any internal oracle). Returns the net `amount_out`.
    fn swap(&mut self, tin: usize, tout: usize, amount_in: f64) -> f64;

    /// Called once per price step *before* trading, with the current external true price.
    /// Oracle-quote AMMs (AIMM) use it to apply keeper pushes / recenter the mark; pure CFMMs
    /// (Uni-V3, Curve) ignore it and reprice purely via arbitrage. Default: no-op.
    fn on_step(&mut self, _external_price: f64, _step: usize) {}

    /// Called every step (unlike `on_step`, which fires only at the keeper cadence), so an
    /// oracle-quote AMM can measure elapsed-since-push staleness. Baselines ignore it. Default: no-op.
    fn tick(&mut self, _step: usize) {}

    /// # keeper mark pushes performed so far (keeper-tx / gas-cost accounting). 0 for non-keeper AMMs.
    fn push_count(&self) -> usize {
        0
    }

    /// Marginal spot price of `tout` in units of `tin` (input per output, fee-free).
    fn spot(&self, tin: usize, tout: usize) -> f64;

    /// Reserve of token `i` (for sizing trades / arb caps).
    fn reserve(&self, i: usize) -> f64;

    /// Coverage ratio c = reserves/liabilities of token `i` (inventory-based AMMs). Default 1.0
    /// (CFMMs have no liability concept). The re-peg question = does this converge to 1.
    fn coverage(&self, _i: usize) -> f64 {
        1.0
    }

    /// Total value locked, valuing each token at `prices[i]` (base per token).
    fn tvl(&self, prices: &[f64]) -> f64;

    /// Optimal arbitrage size: amount of `tin` to sell so the post-trade MARGINAL price
    /// reaches `external_price` (input per output). Returns 0 if no profitable arb exists.
    /// Generic bisection over [`Self::quote`]; designs may override with a closed form.
    ///
    /// LVR-correct target (Milionis-Moallemi-Roughgarden): the arbitrageur trades until the
    /// *marginal* execution price equals the true price, capturing the whole gap. Its gross profit
    /// ∫(true − marginal) over [0, s] IS the LP's loss-versus-rebalancing. Sizing to the *average*
    /// price instead drives arb profit to zero by construction (the marginal arber breaks even),
    /// which makes measured LVR ≈ 0 for every design — the LVR signal vanishes. Marginal is found by
    /// finite difference on `quote`; it is increasing in size (convex cost), so bisection is valid.
    fn arb_size(&self, tin: usize, tout: usize, external_price: f64) -> f64 {
        if self.spot(tin, tout) >= external_price {
            return 0.0;
        }
        let (mut lo, mut hi) = (0.0, self.reserve(tin) * 0.5);
        let eps = (self.reserve(tin) * 1e-6).max(1e-9);
        for _ in 0..48 {
            let mid = 0.5 * (lo + hi);
            let o1 = self.quote(tin, tout, mid);
            let o2 = self.quote(tin, tout, mid + eps);
            // marginal input-per-output at cumulative size `mid`
            let marg = if o2 > o1 {
                eps / (o2 - o1)
            } else {
                f64::INFINITY
            };
            if marg < external_price {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        lo
    }
}

/// Per-AMM realized metrics accumulated over a simulation run.
#[derive(Debug, Clone, Default)]
pub struct Metrics {
    pub organic_volume: f64,
    pub toxic_volume: f64,
    pub fees: f64,
    /// LVR = Σ over arb trades of (value_out − value_in) at the external price = LP loss to arbs.
    pub lvr: f64,
    pub n_organic: u64,
    pub n_toxic: u64,
    pub tvl0: f64,
    pub tvl_final: f64,
}

impl Metrics {
    /// Annualized net LP return = (fees − LVR) / TVL₀ scaled to a year.
    /// `fees` is the WHOLE spread. The pool splits it `protoShare` to treasury / rest to LPs
    /// (`Pricing.splitFee`), and this sim carries no `protoShare`, so both APRs below are an
    /// upper bound on LP return, over-stated by that share.
    /// ponytail: thread `protoShare` through `Fill` if the sim is ever used to size LP APR.
    pub fn net_apr(&self, days: f64) -> f64 {
        if self.tvl0 <= 0.0 || days <= 0.0 {
            return 0.0;
        }
        ((self.fees - self.lvr) / self.tvl0) * (365.0 / days)
    }

    pub fn gross_fee_apr(&self, days: f64) -> f64 {
        if self.tvl0 <= 0.0 || days <= 0.0 {
            return 0.0;
        }
        (self.fees / self.tvl0) * (365.0 / days)
    }
}
