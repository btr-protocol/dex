//! Float 1:1 port of `dex/evm/src/libraries/NUQuartic.sol` — clamped quartic B-spline I-spline on
//! non-uniform knots. Same pipeline: validate Δw≥0 → de Boor jets at the span edges → per-segment
//! power basis c0..c4 on local u∈[0,1] → prefix integrals → O(1) `area` over [x1,x2]. Drops the
//! on-chain fixed-point scales (Q=1e9 for y, D=1e6 derivative scale, P=1e18 Horner scale) for f64,
//! so it deviates from the packed on-chain evaluation ONLY by integer truncation in those pyramids:
//! parity vs the fitted objects holds to ~1e-9 relative (tests/quartic_parity.rs vs
//! `evm/test/proto/quartic_vectors.json`, the same vectors NUQuartic.t.sol asserts against).
//!
//! Curve = monotone integral of a C2 density: Δw≥0 on the control weights ⇒ nondecreasing at any
//! degree; simple interior knots at degree 4 ⇒ the density (y') is C2 at every knot. Domain
//! x ∈ [0, 10000] cumulative depth bps; y in pbps (the on-chain wQ are pbps·Q — divide by 1e9).

use super::consts::{BPS, FLAG_REQUIRES_WALL, MAX_SEGS, PREFIX_LIMIT_PBPS, SEG_COEFF_LIMIT_PBPS};

/// x domain span = cumulative depth bps (`NUQuartic.sol` uses SC.BPS).
pub const XSPAN: f64 = BPS;

/// Packed-equivalent curve: per-segment power basis + prefix integrals (NUQuartic.Curve).
#[derive(Debug, Clone)]
pub struct QuarticCurve {
    /// Segment right boundaries b_1..b_m (b_m = XSPAN); segment i covers [b_i, b_{i+1}), b_0 = 0.
    bounds: Vec<f64>,
    /// c0..c4 per segment: y(u) = c0 + c1·u + c2·u² + c3·u³ + c4·u⁴ on local u ∈ [0,1], y in pbps.
    segs: Vec<[f64; 5]>,
    /// Prefix ∫y dx from 0 to each segment's left edge (pbps·x units) — the on-chain S.
    prefix: Vec<f64>,
    /// Reference dispersion (pbps) the fit was built at; quotes y-scale by disp/disp_ref.
    pub disp_ref: f64,
    /// Packed header flag bits (`NUQuartic.Curve.header >> 248`). Only FLAG_REQUIRES_WALL today.
    flags: u8,
}

impl QuarticCurve {
    /// Validate + convert a clamped quartic B-spline to power basis (NUQuartic.set + _validate +
    /// _buildSeg). `w` = control weights in pbps (nondecreasing), `interior` = strictly-increasing
    /// interior knots in (0, XSPAN), len == w.len() - 5. Panics ≙ the on-chain InvalidInput revert.
    pub fn new(interior: &[f64], w: &[f64], disp_ref: f64, flags: u8) -> Self {
        let n = w.len();
        assert!(
            n >= 5 && n - 4 <= MAX_SEGS && interior.len() == n - 5,
            "invalid input"
        );
        assert!(w[n - 1] != w[0], "flat curve = no price discovery");
        assert!(
            w.windows(2).all(|p| p[1] >= p[0]),
            "dw<0 => non-monotone curve"
        );
        assert!(disp_ref > 0.0, "disp_ref");
        // clamped degree-4 knot vector: 5× 0, interior, 5× XSPAN
        let mut t = vec![0.0; n + 5];
        let mut prev = 0.0;
        for (j, &kx) in interior.iter().enumerate() {
            assert!(
                kx > prev && kx < XSPAN,
                "interior knots strictly increasing in (0, XSPAN)"
            );
            t[5 + j] = kx;
            prev = kx;
        }
        for ti in t.iter_mut().skip(n) {
            *ti = XSPAN;
        }
        let m = n - 4; // span count (clamped quartic)
        let mut bounds = Vec::with_capacity(m);
        let mut segs = Vec::with_capacity(m);
        let mut prefix = Vec::with_capacity(m);
        let mut s_acc: f64 = 0.0;
        for j in 0..m {
            bounds.push(t[j + 5]);
            let k = seg_coeffs(&t, w, j + 4);
            // `NUQuartic._buildSeg` packs c0..c4 into int64 lanes and S into int128; a fit that
            // overflows those lanes reverts on-chain rather than storing a silently wrapped curve.
            // Bounds are the on-chain ones with the Q=1e9 fixed point divided out.
            assert!(
                k.iter().all(|ki| ki.abs() <= SEG_COEFF_LIMIT_PBPS),
                "segment coefficient overflow"
            );
            assert!(s_acc.abs() <= PREFIX_LIMIT_PBPS, "prefix integral overflow");
            prefix.push(s_acc);
            // exact full-segment integral: h·(c0 + c1/2 + c2/3 + c3/4 + c4/5)
            s_acc +=
                (t[j + 5] - t[j + 4]) * (k[0] + k[1] / 2.0 + k[2] / 3.0 + k[3] / 4.0 + k[4] / 5.0);
            segs.push(k);
        }
        Self {
            bounds,
            segs,
            prefix,
            disp_ref,
            flags,
        }
    }

    /// Preset is only valid on a coverage-walled asset (`NUQuartic.FLAG_REQUIRES_WALL`, checked by
    /// `PoolAdmin.setProfile`). Hyper tiers concentrate depth at the peg and rely on the wall to
    /// stop a drain past it.
    pub fn requires_wall(&self) -> bool {
        self.flags & FLAG_REQUIRES_WALL != 0
    }

    /// Segment index + local frame: seg i covers [b_i, b_{i+1}), linear scan (NUQuartic._frame).
    fn frame(&self, x: f64) -> (usize, f64, f64) {
        let m = self.bounds.len();
        let mut i = 0;
        let mut b = 0.0;
        let mut next = self.bounds[0];
        while i < m - 1 && x >= next {
            i += 1;
            b = next;
            next = self.bounds[i];
        }
        (i, b, next - b)
    }

    /// y(x) in pbps; callers scale by disp/disp_ref (linear y-scale preserves monotone + C2).
    /// (NUQuartic.evalQ)
    pub fn eval(&self, x: f64) -> f64 {
        let (i, x0, h) = self.frame(x);
        let u = ((x - x0).max(0.0).min(h)) / h;
        let c = &self.segs[i];
        c[0] + u * (c[1] + u * (c[2] + u * (c[3] + u * c[4])))
    }

    /// O(1) integral over [x1,x2] via prefix sums; returns pbps·x units, 0 when x1 ≥ x2.
    /// (NUQuartic.areaQ)
    pub fn area(&self, x1: f64, x2: f64) -> f64 {
        if x1 >= x2 {
            return 0.0;
        }
        self.at(x2) - self.at(x1)
    }

    /// Cumulative integral from 0 to x: prefix + local quintic primitive (NUQuartic._at).
    fn at(&self, x: f64) -> f64 {
        let (i, x0, h) = self.frame(x);
        let u = ((x - x0).max(0.0).min(h)) / h;
        let c = &self.segs[i];
        self.prefix[i]
            + h * u
                * (c[0] + u * (c[1] / 2.0 + u * (c[2] / 3.0 + u * (c[3] / 4.0 + u * c[4] / 5.0))))
    }
}

/// Power basis on local u∈[0,1]: c0..c2 from the left de Boor jet, c3/c4 solved from the
/// right-end value/slope (NUQuartic._segCoeffs). Span s covers [t[s], t[s+1]].
fn seg_coeffs(t: &[f64], w: &[f64], s: usize) -> [f64; 5] {
    let h = t[s + 1] - t[s];
    let c0 = de_boor4(t, w, s, t[s]);
    let c1 = de_boor_d1(t, w, s, t[s]) * h;
    let c2 = de_boor_d2(t, w, s, t[s]) * h * h / 2.0;
    let a = de_boor4(t, w, s, t[s + 1]) - c0 - c1 - c2;
    let b = de_boor_d1(t, w, s, t[s + 1]) * h - c1 - 2.0 * c2;
    [c0, c1, c2, 4.0 * a - b, b - 3.0 * a]
}

/// de Boor degree 4 at x in span s (NUQuartic._deBoor4).
fn de_boor4(t: &[f64], w: &[f64], s: usize, x: f64) -> f64 {
    let mut d = [0.0; 5];
    d.copy_from_slice(&w[s - 4..s + 1]);
    for r in 1..=4usize {
        for j in (r..=4usize).rev() {
            let den = t[j + 1 + s - r] - t[j + s - 4];
            let num = x - t[j + s - 4];
            d[j] = (d[j - 1] * (den - num) + d[j] * num) / den;
        }
    }
    d[4]
}

/// q_i = 4·(w[i+1]−w[i])/(t[i+5]−t[i+1]) — first-derivative control net, degree 3 (NUQuartic._q).
fn q(t: &[f64], w: &[f64], i: usize) -> f64 {
    4.0 * (w[i + 1] - w[i]) / (t[i + 5] - t[i + 1])
}

/// First derivative: degree-3 de Boor over q (NUQuartic._deBoorD1).
fn de_boor_d1(t: &[f64], w: &[f64], s: usize, x: f64) -> f64 {
    let mut d = [0.0; 4];
    for (k, dk) in d.iter_mut().enumerate() {
        *dk = q(t, w, s - 4 + k);
    }
    for r in 1..=3usize {
        for j in (r..=3usize).rev() {
            let den = t[j + s - r + 1] - t[j + s - 3];
            let num = x - t[j + s - 3];
            d[j] = (d[j - 1] * (den - num) + d[j] * num) / den;
        }
    }
    d[3]
}

/// Second derivative: r_i = 3·(q[i+1]−q[i])/(t[i+5]−t[i+2]), degree-2 de Boor (NUQuartic._deBoorD2).
fn de_boor_d2(t: &[f64], w: &[f64], s: usize, x: f64) -> f64 {
    let mut d = [0.0; 3];
    for (k, dk) in d.iter_mut().enumerate() {
        let i = s - 4 + k;
        *dk = 3.0 * (q(t, w, i + 1) - q(t, w, i)) / (t[i + 5] - t[i + 2]);
    }
    for r in 1..=2usize {
        for j in (r..=2usize).rev() {
            let den = t[j + s - r + 1] - t[j + s - 2];
            let num = x - t[j + s - 2];
            d[j] = (d[j - 1] * (den - num) + d[j] * num) / den;
        }
    }
    d[2]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ramp() -> (Vec<f64>, Vec<f64>) {
        // linear ±50 pbps ramp over 9 weights (production tight-stable preset shape)
        let interior: Vec<f64> = (1..5).map(|i| i as f64 * 2000.0).collect();
        let w: Vec<f64> = (0..9).map(|i| (i as f64 - 4.0) * 12.5).collect();
        (interior, w)
    }

    #[test]
    fn endpoints_interpolate_and_monotone() {
        let (interior, w) = ramp();
        let c = QuarticCurve::new(&interior, &w, 100.0, 0);
        assert!((c.eval(0.0) - w[0]).abs() < 1e-9);
        assert!((c.eval(XSPAN) - w[8]).abs() < 1e-9);
        let mut prev = c.eval(0.0);
        for i in 1..=1000 {
            let y = c.eval(i as f64 * 10.0);
            assert!(y >= prev - 1e-9, "nondecreasing");
            prev = y;
        }
        // area consistency: full-domain area == sum of at() increments, x1>=x2 -> 0
        assert_eq!(c.area(5000.0, 5000.0), 0.0);
        assert_eq!(c.area(6000.0, 4000.0), 0.0);
        let full = c.area(0.0, XSPAN);
        assert!((full - (c.area(0.0, 3333.0) + c.area(3333.0, XSPAN))).abs() < 1e-6);
    }

    #[test]
    #[should_panic(expected = "non-monotone")]
    fn rejects_non_monotone() {
        let (interior, mut w) = ramp();
        w[8] = w[0] - 1.0;
        QuarticCurve::new(&interior, &w, 100.0, 0);
    }

    #[test]
    #[should_panic(expected = "flat")]
    fn rejects_flat() {
        let (interior, _) = ramp();
        QuarticCurve::new(&interior, &[1.0; 9], 100.0, 0);
    }

    #[test]
    #[should_panic(expected = "invalid input")]
    fn rejects_too_many_segs() {
        let n = MAX_SEGS + 5;
        let interior: Vec<f64> = (1..=n - 5).map(|i| i as f64 * 100.0).collect();
        let w: Vec<f64> = (0..n).map(|i| i as f64).collect();
        QuarticCurve::new(&interior, &w, 100.0, 0);
    }

    #[test]
    #[should_panic(expected = "interior knots")]
    fn rejects_out_of_range_knot() {
        let (mut interior, w) = ramp();
        interior[3] = XSPAN;
        QuarticCurve::new(&interior, &w, 100.0, 0);
    }
}
