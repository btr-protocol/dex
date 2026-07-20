// spline_bspline.ts — CLAMPED QUARTIC B-SPLINE (penalized I-spline) core for the AIMM cumulative
// bonding curve.
//
// WHY quartic (v2, 2026-07-09 four-expert panel): the v1 cubic cumulative was C2, so the liquidity
// DENSITY the owner reads (∝1/y′) was only C1 — piecewise-quadratic with a curvature JUMP at every
// knot. Measured on the emitted series: log-slope breaks of 0.46–0.59 decades/bp exactly at the knot
// anchors = the polygon-vertex look no λ/knot tuning can remove (curvature class is structural).
// Quartic cumulative ⇒ C3 ⇒ density C2 = G2 (curvature-continuous, the CAD "Class-A smooth" bar).
// Equivalently: density modeled directly as a penalized NON-NEGATIVE CUBIC B-spline — Ramsay-1988
// I-splines + Eilers–Marx P-spline penalty. Panel survey: unique survivor of the on-chain constraints
// (rational ⇒ ln in area; tension ⇒ exp per eval; all Hermite kin ⇒ density ≤C1; Akima ⇒ no guarantee).
//
// Fit recipe (replaces v1 hand-tuned anchors + per-target λ lists — "knots stop mattering"):
//   knots   uniform-in-OFFSET, h from a coarse→fine sweep, + fixed wall pair ±(cut−0.5), ±(cut−1.25);
//   penalty λ·Δ²(d_i/d̂_i) — 2nd differences of density carriers NORMALIZED by the target's own slope
//           (exact-target ∈ null space ⇒ deviation-from-target-smoothness; walls not flattened);
//   λ       single scale-free ladder {1..1024}, smallest λ passing ALL gates;
//   gate    seamJ ≤ 0.18 (SEAM_J_MAX, uniform — no per-regime exceptions): exact closed-form worst
//           log10-density deviation (decades) a knot seam can produce at chart scale — the honest
//           "no visible kink" metric (v1 contBreakPct measured Δy″ which is identically 0 at p=4;
//           seamJ measures Δy⁗, the new lowest discontinuity).
//
// ON-CHAIN path unchanged in kind: keeper pushes (knots,w), contract validates Δw≥0 (O(n) int
// compares ⇒ monotone for ANY degree — derivative ctrl pts q_i ∝ Δw_i), converts each span to a
// power-basis QUARTIC once at push (segPowerBasis), then eval()=lookup+Horner (+1 term vs cubic),
// area()=quintic antiderivative. Bench (QuarticProto, non-uniform knots, ncp=14/10 segs): eval
// ≈17.3k gas, area O(1) ≈20.3k via prefix integrals — within the FC Hermite ≈18k + 2k budget.
//
// Units/conventions reused 1:1 from spline_shape.ts: x ∈ [0,BPS=1e4] depth coord, volUsd=(x-5000)*1000
// ∈ [-5M,+5M], offset y in PBPS (offsetBps = pbps/100), L=$10M/side, density in $/bp.
import {
  BPS, curveOffsetBps, CURVE_BENCHMARKS, maxBumpPct, densityAtUniformOffsets,
  trapezoidIntegral, splinePoints, hermiteEval, hermiteDeriv, PROFILES,
} from './spline_shape.ts';

const P = 4; // quartic cumulative ⇒ C2 density (G2)
const DENS_N = 1200; // uniform-offset density samples (15/bp @ ±40) — resolves knot-span bends
const SEAM_J_MAX = 0.18; // decades of log-density roughness = the METRIC THE EYE JUDGES (chart is log-y
// vs offset). Owner-accepted-smooth fits measured ≤0.13; kinky ≥1.18. The dense offset-space penalty
// (see fit()) now does the smoothing IN the viewed metric, so this gate can stay moderate (0.18) without
// forcing knot bloat — glassiness comes from the fit, not from over-gating.
const LAMBDAS = [1, 4, 16, 64, 256, 1024, 4096, 16384]; // u-penalty is scale-free; top = hug-the-target
const H_SWEEP = [8, 6.5, 5, 4, 3, 2.5, 2]; // knot pitch (bp), coarse→fine; coarsest passing wins
const H_SWEEP_NARROW = [2.5, 2, 1.5, 1.25, 1, 0.75]; // for |wall|≤6bp (±5 stable pack)
const STABLE_NCP_MAX = 9; // port gate: control points for ±5bp pack
const STABLE_PACK = new Set(['uni_flat', 'stable_normal', 'stable_skew', 'curve_A1500']);
const WALL_SWEEP_BP = [3, 5, 10]; // report-only wall widths for uni_flat

// ─────────────────────────────────────────────────────────────────────────────
// Generic B-spline primitives (Cox–de Boor / Piegl-Tiller). Degree-agnostic so derivatives reuse
// the same code path as the value.
// ─────────────────────────────────────────────────────────────────────────────
function findSpan(deg: number, T: number[], ncp: number, x: number): number {
  const n = ncp - 1;
  if (x >= T[n + 1]) return n;
  if (x <= T[deg]) return deg;
  let lo = deg, hi = n + 1, mid = (lo + hi) >> 1;
  while (x < T[mid] || x >= T[mid + 1]) { if (x < T[mid]) hi = mid; else lo = mid; mid = (lo + hi) >> 1; }
  return mid;
}
// Nonzero basis functions N[0..deg] at span s (index i = s-deg+j). Piegl-Tiller A2.2.
function basisFuns(deg: number, T: number[], s: number, x: number): number[] {
  const N = Array.from({ length: deg + 1 }, () => 0); N[0] = 1;
  const left = Array.from({ length: deg + 1 }, () => 0), right = Array.from({ length: deg + 1 }, () => 0);
  for (let j = 1; j <= deg; j++) {
    left[j] = x - T[s + 1 - j]; right[j] = T[s + j] - x;
    let saved = 0;
    for (let r = 0; r < j; r++) { const tmp = N[r] / (right[r + 1] + left[j - r]); N[r] = saved + right[r + 1] * tmp; saved = left[j - r] * tmp; }
    N[j] = saved;
  }
  return N;
}
function bsplineEval(deg: number, T: number[], ctrl: number[], x: number): number {
  const s = findSpan(deg, T, ctrl.length, x), N = basisFuns(deg, T, s, x);
  let v = 0; for (let j = 0; j <= deg; j++) v += N[j] * ctrl[s - deg + j];
  return v;
}
// Derivative control points: q_i = deg·(c_{i+1}-c_i)/(T_{i+deg+1}-T_{i+1}); the derivative is a
// degree-(deg-1) B-spline on the trimmed knot vector T[1..-1]. (This is exactly why Δw≥0 ⇒ monotone y,
// at ANY degree: q_i ∝ (w_{i+1}-w_i), all ≥0 iff w nondecreasing.)
function derivCtrl(deg: number, T: number[], ctrl: number[]): number[] {
  const q: number[] = [];
  for (let i = 0; i < ctrl.length - 1; i++) { const den = T[i + deg + 1] - T[i + 1]; q.push(den > 0 ? (deg * (ctrl[i + 1] - ctrl[i])) / den : 0); }
  return q;
}
function bsplineDeriv(deg: number, T: number[], ctrl: number[], x: number): number {
  return bsplineEval(deg - 1, T.slice(1, T.length - 1), derivCtrl(deg, T, ctrl), x);
}
function bsplineDeriv2(deg: number, T: number[], ctrl: number[], x: number): number {
  const T1 = T.slice(1, T.length - 1), q = derivCtrl(deg, T, ctrl);
  return bsplineEval(deg - 2, T1.slice(1, T1.length - 1), derivCtrl(deg - 1, T1, q), x);
}

// Clamped knot vector: (P+1) repeats of xmin, interior knots, (P+1) repeats of xmax.
// length = ncp+P+1. interior count = ncp-P-1.
export function clampedKnots(ncp: number, xmin: number, xmax: number, interior?: number[]): number[] {
  const nInt = ncp - P - 1;
  const T = Array.from({ length: P + 1 }, () => xmin);
  const ks = interior ?? Array.from({ length: nInt }, (_, k) => xmin + ((xmax - xmin) * (k + 1)) / (nInt + 1));
  if (ks.length !== nInt) throw new Error(`interior knots ${ks.length} != ${nInt}`);
  for (const k of ks) T.push(k);
  for (let i = 0; i < P + 1; i++) T.push(xmax);
  return T;
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-segment power basis — the ON-CHAIN eval path. A quartic B-spline restricted to one knot span is
// a quartic polynomial with 5 dof: (value,slope) at both span ends + y″ at the left end (all straight
// from de Boor — nothing approximated). Local coord t=(x-x0)/Δ ∈ [0,1]; p(t)=y0+k0·t+c2·t²+c3·t³+c4·t⁴.
// ─────────────────────────────────────────────────────────────────────────────
export interface Seg { x0: number; x1: number; d: number; y0: number; k0: number; c2: number; c3: number; c4: number; }
export function segPowerBasis(T: number[], w: number[]): Seg[] {
  const ncp = w.length, segs: Seg[] = [];
  for (let s = P; s <= ncp - 1; s++) {
    const x0 = T[s], x1 = T[s + 1]; if (x1 <= x0) continue; // skip zero-length spans (clamped ends)
    const d = x1 - x0;
    const y0 = bsplineEval(P, T, w, x0), y1 = bsplineEval(P, T, w, x1);
    const k0 = bsplineDeriv(P, T, w, x0) * d, k1 = bsplineDeriv(P, T, w, x1) * d;
    const c2 = (bsplineDeriv2(P, T, w, x0) * d * d) / 2;
    // remaining 2 dof from the right-end conditions: c3+c4 = A, 3c3+4c4 = B
    const A = y1 - y0 - k0 - c2, B = k1 - k0 - 2 * c2;
    segs.push({ x0, x1, d, y0, k0, c2, c3: 4 * A - B, c4: B - 3 * A });
  }
  return segs;
}
function segAt(segs: Seg[], x: number): Seg { // binary search — mirrors on-chain lookup
  if (x <= segs[0].x0) return segs[0];
  if (x >= segs[segs.length - 1].x1) return segs[segs.length - 1];
  let lo = 0, hi = segs.length - 1;
  while (lo < hi) { const m = (lo + hi) >> 1; if (x < segs[m].x1) hi = m; else lo = m + 1; }
  return segs[lo];
}
export function powEval(segs: Seg[], x: number): number {
  const s = segAt(segs, x); const t = Math.min(1, Math.max(0, (x - s.x0) / s.d));
  return s.y0 + t * (s.k0 + t * (s.c2 + t * (s.c3 + t * s.c4))); // Horner
}
export function powDeriv(segs: Seg[], x: number): number { // d(offset)/dx
  const s = segAt(segs, x); const t = Math.min(1, Math.max(0, (x - s.x0) / s.d));
  return (s.k0 + t * (2 * s.c2 + t * (3 * s.c3 + t * 4 * s.c4))) / s.d;
}
// Closed-form area under offset(x) from xa..xb — quintic antiderivative per segment. The on-chain
// area() uses this exact form. ∫p dx = Δ·(y0 t + k0 t²/2 + c2 t³/3 + c3 t⁴/4 + c4 t⁵/5).
export function powArea(segs: Seg[], xa: number, xb: number): number {
  const F = (s: Seg, t: number) => s.d * (t * (s.y0 + t * (s.k0 / 2 + t * (s.c2 / 3 + t * (s.c3 / 4 + t * (s.c4 / 5))))));
  let tot = 0;
  for (const s of segs) {
    const a = Math.max(xa, s.x0), b = Math.min(xb, s.x1); if (b <= a) continue;
    tot += F(s, (b - s.x0) / s.d) - F(s, (a - s.x0) / s.d);
  }
  return tot;
}

// ─────────────────────────────────────────────────────────────────────────────
// seamJ — the visual-smoothness gate. Quartic ⇒ y,y′,y″,y‴ all continuous; the lowest discontinuity
// is Δy⁗ at knots (=24Δc4/d⁴). Its worst-case footprint on the LOG-density chart (what the owner
// reads): deviation of y′ from smooth continuation over half a knot-image span δ (bp, capped at 2bp)
// is Δy⁗·(100δ)³/3!, relative /y′, in decades /ln10. Calibrated threshold SEAM_J_MAX=0.18: shipped-
// accepted fits measured ≤0.13, owner-flagged kinky fits ≥1.18. Knots in the economically-dead tail
// (density < 1e-4·peak ⇔ y′ > 1e4·y′min) are skipped — the chart floor hides them.
// Exported: the parity exporter re-checks seamJ on the QUANTIZED (integer-knot, integer-w) object.
// ─────────────────────────────────────────────────────────────────────────────
export function seamJ(segs: Seg[]): number {
  const yp: number[] = [], hbp: number[] = [];
  for (const s of segs) { yp.push((s.k0 / s.d)); hbp.push(Math.abs(powEval(segs, s.x1) - powEval(segs, s.x0)) / 100); }
  const ypAt = (i: number) => powDeriv(segs, segs[i].x0); // left-limit ≡ right-limit (C3)
  let ypmin = Infinity; for (let i = 1; i < segs.length; i++) ypmin = Math.min(ypmin, Math.abs(ypAt(i)));
  let worst = 0;
  for (let i = 1; i < segs.length; i++) {
    const v = Math.abs(ypAt(i));
    if (v > 1e4 * ypmin) continue; // dead-tail knot, below chart floor
    const L = segs[i - 1], R = segs[i];
    const dJump = Math.abs((24 * R.c4) / R.d ** 4 - (24 * L.c4) / L.d ** 4);
    const del = Math.min(Math.min(hbp[i - 1], hbp[i]), 2) / 2;
    worst = Math.max(worst, ((100 * del) ** 3 * dJump) / (6 * Math.LN10 * v ** 4));
  }
  return worst;
}

// ─────────────────────────────────────────────────────────────────────────────
// NNLS on the DERIVATIVE representation. y(x)=Σ w_i N_{i,P+1}. Fix w_0=target(xmin) (clamped spline
// interpolates its first control point). Let e_i=w_i-w_{i-1}≥0 ⇒ Δw≥0 ⇒ monotone. Using partition of
// unity: y(x)=w_0+Σ_{i≥1} e_i·T_i(x), T_i(x)=Σ_{m≥i} N_m(x) — pure nonneg LS; w=cumsum(e) is monotone
// BY CONSTRUCTION, the solver never has to be trusted for that.
// ─────────────────────────────────────────────────────────────────────────────
function designT(T: number[], ncp: number, xs: number[]): number[][] {
  const A: number[][] = [];
  for (const x of xs) {
    const s = findSpan(P, T, ncp, x), N = basisFuns(P, T, s, x);
    const Nm = Array.from({ length: ncp }, () => 0); for (let j = 0; j <= P; j++) Nm[s - P + j] = N[j];
    const row = Array.from({ length: ncp - 1 }, () => 0);
    let suff = 0;
    for (let i = ncp - 1; i >= 1; i--) { suff += Nm[i]; row[i - 1] = suff; }
    A.push(row);
  }
  return A;
}
// Dense Gaussian elimination w/ partial pivoting — exact passive-set solve inside NNLS.
function solveDense(M: number[][], rhs: number[]): number[] {
  const n = rhs.length, a = M.map((r, i) => [...r, rhs[i]]);
  for (let c = 0; c < n; c++) {
    let piv = c; for (let r = c + 1; r < n; r++) if (Math.abs(a[r][c]) > Math.abs(a[piv][c])) piv = r;
    [a[c], a[piv]] = [a[piv], a[c]];
    if (Math.abs(a[c][c]) < 1e-300) continue;
    for (let r = 0; r < n; r++) { if (r === c) continue; const f = a[r][c] / a[c][c]; for (let k = c; k <= n; k++) a[r][k] -= f * a[c][k]; }
  }
  return a.map((r, i) => (Math.abs(r[i]) < 1e-300 ? 0 : r[n] / r[i]));
}
// Lawson-Hanson active-set NNLS: min‖Ae-b‖² s.t. e≥0. Passive-set LS solved by DIRECT elimination on
// the normal equations, so the near-collinear nested-cumulative design (T_i columns) costs precision
// (~1e-10 rel) NOT convergence.
function nnls(A: number[][], b: number[]): number[] {
  const m = A.length, n = A[0].length;
  const ata = Array.from({ length: n }, () => Array.from({ length: n }, () => 0)), atb = Array.from({ length: n }, () => 0);
  for (let i = 0; i < n; i++) { for (let k = 0; k < m; k++) { atb[i] += A[k][i] * b[k]; for (let j = 0; j < n; j++) ata[i][j] += A[k][i] * A[k][j]; } }
  const x = Array.from({ length: n }, () => 0), act: boolean[] = Array.from({ length: n }, () => false);
  const grad = () => atb.map((v, i) => { let g = v; for (let j = 0; j < n; j++) g -= ata[i][j] * x[j]; return g; });
  for (let outer = 0; outer < 3 * n + 10; outer++) {
    const w = grad();
    let j = -1, best = 1e-10; for (let i = 0; i < n; i++) if (!act[i] && w[i] > best) { best = w[i]; j = i; }
    if (j < 0) break;
    act[j] = true;
    for (let inner = 0; inner < 3 * n + 10; inner++) {
      const idx = act.map((p, i) => (p ? i : -1)).filter((i) => i >= 0);
      const sub = idx.map((r) => idx.map((c) => ata[r][c])), rhs = idx.map((i) => atb[i]);
      const sol = solveDense(sub, rhs), s = Array.from({ length: n }, () => 0); idx.forEach((i, k) => (s[i] = sol[k]));
      if (idx.every((i) => s[i] > 1e-12)) { for (let i = 0; i < n; i++) x[i] = s[i]; break; }
      let alpha = 1; for (const i of idx) if (s[i] <= 1e-12) alpha = Math.min(alpha, x[i] / (x[i] - s[i]));
      for (let i = 0; i < n; i++) x[i] += alpha * (s[i] - x[i]);
      for (const i of idx) if (x[i] <= 1e-12) { act[i] = false; x[i] = 0; }
    }
  }
  return x.map((v) => Math.max(0, v));
}
// Isotonic (nondecreasing) regression, pool-adjacent-violators. Building block for unimodal projection.
function pavaInc(y: number[]): number[] {
  const blocks: { v: number; w: number }[] = [];
  for (const yi of y) {
    blocks.push({ v: yi, w: 1 });
    while (blocks.length > 1 && blocks[blocks.length - 2].v > blocks[blocks.length - 1].v) {
      const b = blocks.pop()!, a = blocks.pop()!, nw = a.w + b.w;
      blocks.push({ v: (a.v * a.w + b.v * b.w) / nw, w: nw });
    }
  }
  const out: number[] = []; for (const b of blocks) for (let k = 0; k < b.w; k++) out.push(b.v); return out;
}
// L2 projection onto the single-PEAK cone: best split point, isotonic left / antitonic right.
function unimodalPeak(y: number[]): number[] {
  let best = y, bestErr = Infinity;
  for (let p = 0; p < y.length; p++) {
    const inc = pavaInc(y.slice(0, p + 1)), dec = pavaInc(y.slice(p).reverse()).reverse();
    const peak = Math.max(inc[p], dec[0]);
    const c = [...inc.slice(0, p), peak, ...dec.slice(1)];
    let err = 0; for (let i = 0; i < y.length; i++) err += (c[i] - y[i]) ** 2;
    if (err < bestErr) { bestErr = err; best = c; }
  }
  return best;
}
// The liquidity density is 1/y' and y' = Σ d_i M_i, so a SINGLE liquidity peak ⇔ a SINGLE-VALLEY d
// sequence (d decreasing then increasing). Enforce by projecting −d onto the single-peak cone.
function valleyProject(d: number[]): number[] { return unimodalPeak(d.map((x) => -x)).map((x) => Math.max(0, -x)); }
function isValley(d: number[]): boolean {
  const tol = 0.02 * Math.max(...d, 1e-30);
  let i = 1; while (i < d.length && d[i] <= d[i - 1] + tol) i++;
  while (i < d.length && d[i] >= d[i - 1] - tol) i++;
  return i === d.length;
}

// ─────────────────────────────────────────────────────────────────────────────
// Targets. All return offset in PBPS at depth coord x∈[0,BPS]. Capital integral ≡ $10M is a change-of-
// variables identity so long as the spline endpoints hit the target's offset range — which the clamped
// spline does by interpolating w_0 and w_last. Density-spec cuts are set at the target's own MASS
// SUPPORT (density ≲1–3% of peak at the wall): a wider window would push offset-uniform knots into
// dead x-slivers (< the $10k clampGap floor) where no fit can render the tail — a depth-quantile
// structural floor, not a fit defect (panel (b)).
// ─────────────────────────────────────────────────────────────────────────────
// edgeLo/edgeHi (bp, signed): the target's offset SUPPORT — asymmetric for skewed shapes so no knot
// budget or penalty mass is wasted on dead tails (a dead half-window made the skews unfittable: the
// carriers there carry enormous d̂ slopes that poison the high-λ target-hugging limit).
export interface Target { name: string; offAtX: (x: number) => number; edgeLo: number; edgeHi: number; unimodal: boolean; expectedModes?: number; plateau?: boolean; valley?: boolean; featureAnchors?: number[]; }
export { BPS } from './spline_shape.ts';
export const SEAM_J_MAX_EXPORT = SEAM_J_MAX;
export const LAMBDAS_EXPORT = LAMBDAS;
export const DEGREE = P;
export const volAtX = (x: number) => (x - 5000) * 1000;
// Enforce strictly-increasing knots with a tiny min-gap (0.1% of domain), two-sided so wall-clustered
// knots stay distinct AND never overshoot [gap, BPS-gap] (a knot > BPS injects a negative span into
// Cox-de Boor ⇒ garbage/negative density carriers).
export function clampGap(ks: number[]): number[] {
  const n = ks.length, gap = BPS * 1e-3;
  for (let j = 0; j < n; j++) ks[j] = Math.max(ks[j], j === 0 ? gap : ks[j - 1] + gap);
  for (let j = n - 1; j >= 0; j--) ks[j] = Math.min(ks[j], j === n - 1 ? BPS - gap : ks[j + 1] - gap);
  return ks;
}
// Invert offAtX (monotone) to place a knot at a target offset (bp). Bisection on x∈[0,BPS].
function xAtOffset(tg: Target, offBp: number): number {
  const target = offBp * 100; let lo = 0, hi = BPS;
  for (let it = 0; it < 60; it++) { const mid = (lo + hi) / 2; if (tg.offAtX(mid) < target) lo = mid; else hi = mid; }
  return (lo + hi) / 2;
}
// Interior knots UNIFORM IN OFFSET (knot images uniform on the chart axis — the Eilers-Marx "many
// equal knots" doctrine applied in the space the owner reads) + a fixed 2/side wall pair for the
// compact-support edge riser (principled endpoint grading; ~free where the tail is already dead).
function shapeKnots(tg: Target, hBp: number): number[] {
  // featureAnchors: knots pinned to the shape (peaks/valley/flanks) — minimal knots for multimodal/
  // valley shapes. Used as-is (h ignored); the prune trims further. + a near-wall pair for the riser.
  if (tg.featureAnchors) {
    const offs = [...tg.featureAnchors, tg.edgeLo + 0.5, tg.edgeHi - 0.5].sort((a, b) => a - b);
    return clampGap(offs.map((o) => xAtOffset(tg, o)));
  }
  const c0 = (tg.edgeLo + tg.edgeHi) / 2, W = (tg.edgeHi - tg.edgeLo) / 2;
  const m = Math.floor((W - hBp / 2) / hBp), offs: number[] = [];
  for (let k = -m; k <= m; k++) offs.push(c0 + k * hBp); // window-symmetric grid (mirror ⇒ mirror)
  offs.push(tg.edgeLo + 0.5, tg.edgeLo + 1.25, tg.edgeHi - 1.25, tg.edgeHi - 0.5);
  offs.sort((a, b) => a - b);
  return clampGap(offs.map((o) => xAtOffset(tg, o)));
}
function curveKnots(tg: Target, nInt: number): number[] {
  const c = Math.abs(tg.offAtX(BPS)) / 100, offs = Array.from({ length: nInt }, (_, j) => -c + (2 * c * (j + 1)) / (nInt + 1));
  return clampGap(offs.map((o) => xAtOffset(tg, o)));
}

function curveTarget(name: string, A: number): Target {
  const off = (x: number) => (curveOffsetBps(volAtX(x), A) ?? 0) * 100; // bps→pbps
  const e = Math.abs(off(BPS)) / 100;
  return { name, offAtX: off, edgeLo: -e, edgeHi: e, unimodal: true };
}
// Build offset(x) from a density(offsetBp) spec by integrating to cumulative volume then inverting.
// densityFn need not be normalized; we rescale so ∫ over [lo,hi] = $10M (=full ±5M range).
export function densityTarget(name: string, lo: number, hi: number, densityFn: (o: number) => number, unimodal: boolean, expectedModes = 1): Target {
  const M = 40000, W = hi - lo, os: number[] = [], cum: number[] = []; let acc = 0, prevD = densityFn(lo);
  os.push(lo); cum.push(0);
  for (let i = 1; i <= M; i++) { const o = lo + (W * i) / M; const dD = densityFn(o); acc += ((prevD + dD) / 2) * (W / M); prevD = dD; os.push(o); cum.push(acc); }
  const scale = 10_000_000 / acc; // ∫ scaled density = $10M
  const xTab = cum.map((c) => 5000 + (scale * c - 5_000_000) / 1000);
  const off = (x: number): number => {
    if (x <= xTab[0]) return os[0] * 100; if (x >= xTab[M]) return os[M] * 100;
    let l = 0, h = M; while (h - l > 1) { const mid = (l + h) >> 1; if (xTab[mid] <= x) l = mid; else h = mid; }
    const f = (x - xTab[l]) / (xTab[h] - xTab[l]); return (os[l] + f * (os[h] - os[l])) * 100;
  };
  return { name, offAtX: off, edgeLo: lo, edgeHi: hi, unimodal, expectedModes };
}
// erf (Abramowitz-Stegun 7.1.26, |err|<1.5e-7) → normal CDF Φ → skew-normal density.
export function erf(x: number): number {
  const s = x < 0 ? -1 : 1, ax = Math.abs(x), t = 1 / (1 + 0.3275911 * ax);
  return s * (1 - ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * Math.exp(-ax * ax));
}
export const Phi = (z: number) => 0.5 * (1 + erf(z / Math.SQRT2));
export const phi = (z: number) => Math.exp(-0.5 * z * z);

// (d) Gyroscope E-CLP-like: flat plateau |o|<25, quarter-ellipse rolloff to a hard cutoff at ±40bp.
const eclpTarget = densityTarget('eclp', -40, 40, (o) => { const a = 25, c = 40, ao = Math.abs(o); return ao <= a ? 1 : ao >= c ? 0 : Math.sqrt(Math.max(0, 1 - ((ao - a) / (c - a)) ** 2)); }, true);
eclpTarget.plateau = true; // the ONLY plateau target — its flat |o|<20 top makes the ≤2% ripple gate meaningful
// Uniswap-flat (±5bp stable pack): near-constant density on |o|≤3.5, C2 ellipse rolloff to hard walls ±5.
// Mimics a single Uni v3 full-range concentration without tick ladders. featureAnchors keep ncp small.
const uniFlatTarget = densityTarget('uni_flat', -5, 5, (o) => {
  const a = 3.5, c = 5, ao = Math.abs(o);
  return ao <= a ? 1 : ao >= c ? 0 : Math.sqrt(Math.max(0, 1 - ((ao - a) / (c - a)) ** 2));
}, true);
uniFlatTarget.plateau = true;
// 2 shape anchors + 2 wall pairs from shapeKnots ⇒ 4 interiors ⇒ ncp=9 (port budget).
uniFlatTarget.featureAnchors = [-3.2, 3.2];
// ±5bp stable pack: mesokurtic + mild skew with soft mass near the wall (σ large enough that
 // density is near-dead at ±5 ⇒ quartic can meet the wall without seamJ blowups).
const stableNormalTarget = densityTarget('stable_normal', -5, 5, (o) => Math.exp(-(o * o) / (2 * 2.0 * 2.0)), true);
const stableSkewTarget = densityTarget('stable_skew', -5, 5, (o) => { const z = o / 2.2; return phi(z) * Phi(0.9 * z); }, true);
// (e) bimodal: two Gaussians at ±15bp, σ=5bp — the multimodality proof. ±30 = mass support (±3σ).
// featureAnchors: knots pinned to the SHAPE (peaks ±15, valley 0, inner flanks ±8, near-wall) instead
// of a uniform grid — 7 interior knots express two clean peaks (owner: "5-9, not 23"). The dense
// offset-space penalty keeps the flanks glassy; the prune trims any anchor the gates don't need.
const bimodalTarget = densityTarget('bimodal', -30, 30, (o) => Math.exp(-((o + 15) ** 2) / (2 * 25)) + Math.exp(-((o - 15) ** 2) / (2 * 25)), false, 2);
bimodalTarget.featureAnchors = [-27, -15, 0, 15, 27]; // peaks ±15, valley 0, edges — 5+2wall = 7 knots
// Asymmetric + kurtosis + log-normal shapes — parity set vs the old Hermite. Windows = ACTUAL mass
// support (asymmetric for the skews): right_skew lives on [-18,+34] (density 0.2% of peak at -18),
// left mirror; log-normal on [-34,+40]. fat = Student-t ν=1.5 (the ONE capital-bounded window — its
// o^-2.5 tails never die) vs thin super-Gaussian ^4 (dead by ±26). meso = pure normal σ=10bp.
const rightSkewTarget = densityTarget('right_skew', -18, 34, (o) => { const z = o / 12; return phi(z) * Phi(1.5 * z); }, true);
const leftSkewTarget = densityTarget('left_skew', -34, 18, (o) => { const z = o / 12; return phi(z) * Phi(-1.5 * z); }, true);
const lognormalTarget = densityTarget('lognormal', -34, 40, (o) => { const u = o + 52; if (u <= 0) return 0; const m = Math.log(46), s = 0.26; return (1 / u) * Math.exp(-((Math.log(u) - m) ** 2) / (2 * s * s)); }, true);
const normalTarget = densityTarget('normal', -32, 32, (o) => Math.exp(-(o * o) / 200), true);
const fatTailTarget = densityTarget('fat_tail', -40, 40, (o) => { const s = 9, nu = 1.5; return (1 + (o / s) ** 2 / nu) ** (-(nu + 1) / 2); }, true);
const thinTailTarget = densityTarget('thin_tail', -28, 28, (o) => Math.exp(-((Math.abs(o) / 18) ** 4)), true);
// ── INVERTED / V-shape + combined skew×kurtosis (owner 2026-07-10 "multiple distribution types inverted
// like a V ... more play with kurtosis and skewness") ─────────────────────────────────────────────────
// valley (V / barbell): density MIN at the peg, rising to both band edges — liquidity pulled OFF mid
// toward the wings (a range-avoiding profile). Monotone cumulative holds (density ≥ 0.12 floor > 0);
// gated on single-valley emitted density, not interior maxima.
const valleyTarget = densityTarget('valley', -28, 28, (o) => 0.06 + (Math.abs(o) / 28) ** 2.0, false, 2);
valleyTarget.valley = true; // two wings ⇒ expectedModes 2 so the spur gate treats BOTH as intended
valleyTarget.featureAnchors = [-26, -13, 0, 13, 26]; // edges + mid-flank + valley — 5+2wall = 7 knots
// skew-t: asymmetric AND leptokurtic (skew × kurtosis together) — mode just right of peg, a long HEAVY
// right tail (Student-t ν=2), steep left. window [-20,+42].
const skewFatTarget = densityTarget('skew_fat', -20, 42, (o) => { const s = 8, nu = 2, z = o / s; return (1 + (z * z) / nu) ** (-(nu + 1) / 2) * Phi(1.2 * z); }, true);
// skew-platykurtic: asymmetric FLAT-TOP, light tails, right-leaning. SMOOTH construction (super-Gaussian
// ^4 base × skew-CDF factor) — no slope-kink for the fit to chase (the earlier piecewise-scale target
// forced 33 knots). window [-28,+34].
const skewThinTarget = densityTarget('skew_thin', -28, 34, (o) => { const s = 16; return Math.exp(-((o / s) ** 4)) * Phi((0.9 * o) / s); }, true);

const TARGETS: Target[] = [
  curveTarget('curve_A4000', CURVE_BENCHMARKS.A4000),
  curveTarget('curve_A1500', CURVE_BENCHMARKS.A1500),
  curveTarget('curve_A256', CURVE_BENCHMARKS.A256),
  uniFlatTarget, stableNormalTarget, stableSkewTarget,
  eclpTarget, bimodalTarget, valleyTarget,
  rightSkewTarget, leftSkewTarget, lognormalTarget, normalTarget, fatTailTarget, thinTailTarget,
  skewFatTarget, skewThinTarget,
];

// ─────────────────────────────────────────────────────────────────────────────
// Fit + metrics for one (target, knot layout, λ).
// ─────────────────────────────────────────────────────────────────────────────
// Count INTERIOR liquidity-density modes. Restricted to the central 85% of the offset range so
// near-wall rounding ripples don't count; prominence gate 8% of peak.
function densityPeaks(dens: [number, number][]): number {
  const trim = Math.floor(dens.length * 0.075);
  const y = dens.slice(trim, dens.length - trim).map((d) => (isFinite(d[1]) ? d[1] : 0)), pk = Math.max(...y); let n = 0;
  for (let i = 1; i < y.length - 1; i++) if (y[i] >= y[i - 1] && y[i] > y[i + 1] && y[i] > 0.08 * pk) {
    let lo = y[i]; for (let j = i; j >= 0 && y[j] <= y[i]; j--) lo = Math.min(lo, y[j]);
    if (y[i] - lo > 0.08 * pk || n === 0) n++;
  }
  return Math.max(1, n);
}
// Owner-visible shape gates measured on the EMITTED density series (powEval/powDeriv, the exact
// on-chain path) in LOG10 space (the chart the owner reads). Mode/spurious-lobe detection restricted
// to the LIVE region (density > 4% of peak); tailMonotone stays FULL-range.
function prominence(y: number[], i: number): number {
  let l = y[i]; for (let j = i - 1; j >= 0; j--) { if (y[j] > y[i]) break; l = Math.min(l, y[j]); }
  let r = y[i]; for (let j = i + 1; j < y.length; j++) { if (y[j] > y[i]) break; r = Math.min(r, y[j]); }
  return y[i] - Math.max(l, r);
}
// Target-free mode census on the emitted density — shared by wallShape and the parity exporter's
// post-quantization re-gate (quantized objects have no Target; only mode COUNT must be preserved).
function modeCensus(segs: Seg[]) {
  const lo = powEval(segs, 0) / 100, hi = powEval(segs, BPS) / 100;
  const dens = densityAtUniformOffsets((x) => powEval(segs, x), (x) => powDeriv(segs, x), DENS_N, lo, hi);
  const o = dens.map((d) => d[0]), y = dens.map((d) => (isFinite(d[1]) && d[1] > 0 ? d[1] : 1e-30));
  const pk = Math.max(...y), live = (i: number) => y[i] > 0.04 * pk;
  const maxima: number[] = [];
  for (let i = 1; i < y.length - 1; i++) if (live(i) && y[i] >= y[i - 1] && y[i] > y[i + 1]) maxima.push(i);
  const modes = maxima.filter((i) => Math.log10(y[i]) - Math.log10(Math.max(y[i] - prominence(y, i), 1e-30)) > 0.02);
  return { dens, o, y, pk, live, maxima, modes };
}
export function densityModes(segs: Seg[]): number { return modeCensus(segs).modes.length; }
export interface WallShape { modes: number; spuriousLobeMaxPct: number; tailMonotone: boolean; peakAbsOff: number[]; plateauRipplePct: number; extraInfl: number; valleyOk: boolean; }
export function wallShape(tg: Target, segs: Seg[]): WallShape {
  const { dens, o, y, pk, live, maxima, modes } = modeCensus(segs);
  const extraInfl = Math.max(0, logInflections(dens) - targetInflections(tg));
  const nExp = tg.expectedModes ?? 1;
  const intended = [...modes].sort((a, b) => y[b] - y[a]).slice(0, nExp), kept = new Set(intended);
  let spur = 0; for (const i of maxima) if (!kept.has(i)) spur = Math.max(spur, (prominence(y, i) / y[i]) * 100);
  // tail-monotone on the CHART-VISIBLE region only (y ≥ 0.1%·peak ≈ the log-chart floor): sub-floor
  // wiggle in the dead tail is invisible to the owner and forcing λ up to kill it doubles core error.
  // BOTH outer tails are guarded: rightmost intended peak → right wall, leftmost → left wall (a single
  // peak guards both — the old o[i]-sign dispatch skipped one whole tail when the peak sat at ~0±ε,
  // letting a wall hook through on near-symmetric shapes).
  let tailMono = true; const vis = (k: number) => y[k] > 1e-3 * pk;
  if (intended.length) {
    const iR = Math.max(...intended), iL = Math.min(...intended);
    for (let k = iR; k < y.length - 1; k++) { if (vis(k + 1) && y[k + 1] > y[k] * 1.01) tailMono = false; }
    for (let k = iL; k > 0; k--) { if (vis(k - 1) && y[k - 1] > y[k] * 1.01) tailMono = false; }
  }
  const platW = Math.min(20, Math.min(Math.abs(tg.edgeLo), Math.abs(tg.edgeHi)) * 0.65);
  const plat = dens.filter((d) => Math.abs(d[0]) < platW).map((d) => d[1]);
  const platRipple = plat.length ? ((Math.max(...plat) - Math.min(...plat)) / ((Math.max(...plat) + Math.min(...plat)) / 2)) * 100 : 0;
  // valleyOk: emitted density is a single VALLEY — rises (1% tol) from the central min out to BOTH
  // live-region edges. The V/barbell analogue of the mode gate (density MIN at peg, not a peak).
  let valleyOk = true;
  if (tg.valley) {
    let ci = 0; for (let i = 1; i < o.length; i++) if (Math.abs(o[i]) < Math.abs(o[ci])) ci = i;
    for (let k = ci; k < y.length - 1; k++) { if (live(k) && live(k + 1) && y[k + 1] < y[k] * 0.99) valleyOk = false; }
    for (let k = ci; k > 0; k--) { if (live(k) && live(k - 1) && y[k - 1] < y[k] * 0.99) valleyOk = false; }
  }
  return { modes: modes.length, spuriousLobeMaxPct: spur, tailMonotone: tailMono, peakAbsOff: intended.map((i) => Math.abs(o[i])), plateauRipplePct: platRipple, extraInfl, valleyOk };
}
// Density-FIDELITY metric: worst relative error of the emitted density vs the TARGET density (both
// $10M-normalized) over the live region (target ≥ 2% of its peak). The cumulative coreErr gate alone
// let aggressive knot-pruning smear the density (148% rel on normal's tail at 2 knots) while cumulative
// drift stayed ≤3bp — density is the derivative, it distorts an order of magnitude faster.
const rhoTgCache = new Map<string, [number, number][]>();
function targetRho(tg: Target): [number, number][] {
  if (!rhoTgCache.has(tg.name)) {
    const G = 2000, tab: [number, number][] = [], dx = BPS / 20000;
    for (let k = 0; k <= G; k++) {
      const o = tg.edgeLo + ((tg.edgeHi - tg.edgeLo) * k) / G, x = xAtOffset(tg, o);
      const a = Math.max(x - dx, 0), b = Math.min(x + dx, BPS);
      const yp = (tg.offAtX(b) - tg.offAtX(a)) / (b - a);
      tab.push([o, yp > 1e-12 ? 1e5 / yp : 0]);
    }
    rhoTgCache.set(tg.name, tab);
  }
  return rhoTgCache.get(tg.name)!;
}
// Convexity-pattern metric (owner 2026-07-10: "convex segments between knots inside a concave dome"):
// count SIGN FLIPS of the log10-density discrete curvature over the chart-visible region (≥2% peak),
// with a 2%-of-max hysteresis so near-flat plateaus and FP dust don't count. Disjoint live runs (e.g.
// a bimodal valley dipping under the cutoff) are counted per-run — no fake flips at the junction.
// The fit may have NO MORE flips than the target itself (smoothing away a target inflection is fine;
// inventing one is exactly the visible wave being banned).
function logInflections(pts: [number, number][]): number {
  const pk = Math.max(...pts.map((p) => p[1]), 1e-30);
  const runs: number[][] = []; let cur: number[] | null = null;
  for (const [, v] of pts) {
    if (v >= 0.02 * pk) { if (!cur) { cur = []; runs.push(cur); } cur.push(Math.log10(v)); }
    else cur = null;
  }
  let flips = 0;
  for (const seq of runs) {
    if (seq.length < 7) continue;
    const curv: number[] = [];
    for (let i = 1; i < seq.length - 1; i++) curv.push(seq[i - 1] - 2 * seq[i] + seq[i + 1]);
    // Segment into curvature sign-LOBES; a lobe's visual bump height ≈ |ΔL′|·w/4 = Σ|c|·n/4 decades
    // (sample spacing cancels ⇒ same metric for fit series and target table). Only lobes ≥0.03 dec
    // (~7% density step = clearly visible) count — multi-peak shapes have many faint NATURAL inflections
    // that seamJ already certifies as smooth (bimodal-7 seamJ 0.06 had 6 sub-0.03 lobes); this threshold
    // keeps the gate catching the owner's VISIBLE convex-in-concave waves without over-firing on them.
    const strong: number[] = [];
    let s0 = 0, sum = 0, n = 0;
    const flush = () => { if (s0 !== 0 && (sum * n) / 4 >= 0.03) strong.push(s0); s0 = 0; sum = 0; n = 0; };
    for (const c of curv) { const s = Math.sign(c); if (s !== s0) flush(); s0 = s; sum += Math.abs(c); n++; }
    flush();
    for (let i = 1; i < strong.length; i++) if (strong[i] !== strong[i - 1]) flips++;
  }
  return flips;
}
const tgInflCache = new Map<string, number>();
function targetInflections(tg: Target): number {
  if (!tgInflCache.has(tg.name)) tgInflCache.set(tg.name, logInflections(targetRho(tg)));
  return tgInflCache.get(tg.name)!;
}
export function densErrPct(tg: Target, segs: Seg[]): number {
  const tab = targetRho(tg), pk = Math.max(...tab.map((p) => p[1]));
  const W = tg.edgeHi - tg.edgeLo, a = tg.edgeLo + 0.005 * W, b = tg.edgeHi - 0.005 * W;
  const dens = densityAtUniformOffsets((x) => powEval(segs, x), (x) => powDeriv(segs, x), 400, a, b);
  let worst = 0;
  for (const [o, ev] of dens) {
    const k = Math.round(((o - tg.edgeLo) / W) * (tab.length - 1));
    const tv = tab[Math.max(0, Math.min(tab.length - 1, k))][1];
    if (tv >= 0.02 * pk) worst = Math.max(worst, (Math.abs(ev - tv) / tv) * 100);
  }
  return worst;
}
// Derivative control coeffs d_i = P·Δw_i/(t_{i+P+1}-t_{i+1}) — the density-mode carriers (raw Δw is
// NOT ∝ density under non-uniform knots; the knot span divides out here). Modes of d = density modes.
function derivCoeffs(T: number[], e: number[]): number[] { return e.map((ei, i) => (P * ei) / (T[i + P + 1] - T[i + 1])); }
export interface Fit { ncp: number; T: number[]; w: number[]; e: number[]; d: number[]; segs: Seg[]; maxErrPbps: number; coreErrPbps: number; bumpPct: number; seamJ: number; capitalM: number; unimodalD: boolean; deBoorRelErr: number; areaRelErr: number; peaks: number; }
export function fit(tg: Target, interior: number[], lambda: number, enforceUni = false): Fit {
  const NCP = interior.length + P + 1;
  const T = clampedKnots(NCP, 0, BPS, interior);
  const nS = 700, xs: number[] = []; for (let k = 0; k <= nS; k++) xs.push((k / nS) * BPS);
  const w0 = tg.offAtX(0);
  // Weighted LS on a uniform-x grid (panel (d): chart-measure grids chase the vertical wall ⇒ Gibbs).
  // Far endpoint anchored so the spline spans the full target offset range (w_0 is pinned exactly by
  // the clamped end; only the last sample needs the anchor).
  const wt = xs.map((_, k) => (k === nS ? 100 : 1));
  const A = designT(T, NCP, xs).map((row, k) => row.map((v) => v * wt[k]));
  const b = xs.map((x, k) => (tg.offAtX(x) - w0) * wt[k]);
  // P-spline penalty, TARGET-NORMALIZED (panel (f)): λ·Δ²(u), u_i = d_i/d̂_i with d̂_i the target's own
  // slope at the carrier support center. Exact-target-shape ∈ penalty null space ⇒ the penalty measures
  // deviation-from-target-smoothness: kills NNLS ringing WITHOUT flattening the wall (the raw-Δ²d form
  // was dominated by the wall's geometric run and biased it flat). Scale-free ⇒ one λ ladder for all.
  const nE = NCP - 1, sp = Array.from({ length: nE }, (_, i) => T[i + P + 1] - T[i + 1]);
  // ROUGHNESS PENALTY in the VIEWED metric (2026-07-10, owner "smooth even more · fewest knots"):
  // the chart is log-density vs OFFSET, so penalize the 2nd difference of the fitted SLOPE y′ (=1/density
  // up to a constant) on a DENSE uniform-OFFSET grid, weighted by 1/target-slope so the penalty acts in
  // RELATIVE (≈log-density) terms — exactly what the eye reads on the log-y axis. Because y′(x)=Σ_i
  // Dmat[j][i]·e_i is LINEAR in the free vars (q_i=P·e_i/span_i, so y′=Σ q_i B_{i,P-1}), this is still a
  // single convex NNLS. Dense-grid (not knot-indexed) control kills between-knot wiggle where the eye
  // sees it; target-slope weight leaves the walls alone (huge slope ⇒ ~0 weight). Result: glassy at few
  // knots, replacing the sparse carrier penalty that needed extra knots to smooth.
  const T1 = T.slice(1, T.length - 1); // derivative knot vector (degree P-1)
  const NG = 200, gx: number[] = [], ypTg: number[] = [];
  for (let j = 0; j <= NG; j++) { const o = tg.edgeLo + ((tg.edgeHi - tg.edgeLo) * j) / NG, x = xAtOffset(tg, o); gx.push(x); const dx = BPS / 20000, a = Math.max(x - dx, 0), bb = Math.min(x + dx, BPS); ypTg.push(Math.max((tg.offAtX(bb) - tg.offAtX(a)) / (bb - a), 1e-9)); }
  const ypMed = [...ypTg].sort((a, c) => a - c)[NG >> 1];
  const Dmat = gx.map((x) => { const row = Array.from({ length: nE }, () => 0); const s = findSpan(P - 1, T1, nE, x), N = basisFuns(P - 1, T1, s, x); for (let a = 0; a < P; a++) { const i = s - (P - 1) + a; if (i >= 0 && i < nE) row[i] = (P * N[a]) / sp[i]; } return row; });
  if (lambda > 0) for (let j = 1; j < NG; j++) {
    const wgt = (lambda * ypMed) / ypTg[j], row = Array.from({ length: nE }, () => 0);
    for (let i = 0; i < nE; i++) row[i] = wgt * (Dmat[j - 1][i] - 2 * Dmat[j][i] + Dmat[j + 1][i]);
    A.push(row); b.push(0);
  }
  let e = nnls(A, b);
  if (enforceUni) { // force single-peak liquidity ⇔ single-valley d, then map d→Δw→w (stays monotone)
    e = valleyProject(derivCoeffs(T, e)).map((di, i) => (di * sp[i]) / P);
  }
  const d = derivCoeffs(T, e);
  const w = [w0]; for (const ei of e) w.push(w[w.length - 1] + ei);
  const segs = segPowerBasis(T, w);
  // verify power-basis == de Boor (the on-chain eval path is provably the same object)
  let deBoorRelErr = 0;
  for (let k = 0; k <= 500; k++) { const x = (k / 500) * BPS; const a = bsplineEval(P, T, w, x), c = powEval(segs, x); deBoorRelErr = Math.max(deBoorRelErr, Math.abs(a - c) / Math.max(Math.abs(a), 1)); }
  // verify the closed-form quintic antiderivative (on-chain area() path) vs a fine midpoint sum
  let num = 0; const NA = 20000; for (let k = 0; k < NA; k++) { const x = ((k + 0.5) / NA) * BPS; num += powEval(segs, x); } num *= BPS / NA;
  const areaRelErr = Math.abs(powArea(segs, 0, BPS) - num) / Math.max(Math.abs(num), 1);
  // maxErr full-range AND core (middle 90% of the offset window): compact-support targets have a
  // near-vertical cumulative wall no smooth curve can match in the outermost sliver — ≈0 liquidity there.
  const Wo = (tg.edgeHi - tg.edgeLo) * 100, cLo = tg.edgeLo * 100 + 0.05 * Wo, cHi = tg.edgeHi * 100 - 0.05 * Wo;
  let maxErr = 0, coreErr = 0;
  for (let k = 0; k <= 3000; k++) { const x = (k / 3000) * BPS; const tv = tg.offAtX(x); const err = Math.abs(powEval(segs, x) - tv); maxErr = Math.max(maxErr, err); if (tv >= cLo && tv <= cHi) coreErr = Math.max(coreErr, err); }
  const loE = powEval(segs, 0) / 100, hiE = powEval(segs, BPS) / 100;
  const bump = maxBumpPct((x) => powEval(segs, x), (x) => powDeriv(segs, x), 0.9 * Math.min(-loE, hiE));
  const dens = densityAtUniformOffsets((x) => powEval(segs, x), (x) => powDeriv(segs, x), DENS_N, loE, hiE);
  const capitalM = trapezoidIntegral(dens) / 1e6;
  const peaks = densityPeaks(dens);
  const unimodalD = tg.unimodal ? peaks === 1 && isValley(d) : false;
  return { ncp: NCP, T, w, e, d, segs, maxErrPbps: maxErr, coreErrPbps: coreErr, bumpPct: bump, seamJ: seamJ(segs), capitalM, unimodalD, deBoorRelErr, areaRelErr, peaks };
}

// Quantize Δw to a uint16 grid; monotonicity survives by construction (nonneg ints ⇒ nondecreasing
// cumsum). Post-quant re-gate: rounding perturbs density through C^{P-2}-smooth basis mixtures — it can
// NEVER create a seam (verified: seamJ identical pre/post) — but amplitude ripple must stay in budget.
function quantize(tg: Target, f: Fit): { maxErrPbps: number; bumpPct: number; seamJ: number; peaks: number; worstDrift: number } {
  const emax = Math.max(...f.e, 1e-30);
  const eq = f.e.map((v) => Math.round((v / emax) * 65535) / 65535 * emax);
  const w = [f.w[0]]; for (const ei of eq) w.push(w[w.length - 1] + ei);
  const segs = segPowerBasis(f.T, w);
  const Wo = (tg.edgeHi - tg.edgeLo) * 100, cLo = tg.edgeLo * 100 + 0.05 * Wo, cHi = tg.edgeHi * 100 - 0.05 * Wo;
  let maxErr = 0; for (let k = 0; k <= 3000; k++) { const x = (k / 3000) * BPS; const tv = tg.offAtX(x); if (tv >= cLo && tv <= cHi) maxErr = Math.max(maxErr, Math.abs(powEval(segs, x) - tv)); }
  const loE = powEval(segs, 0) / 100, hiE = powEval(segs, BPS) / 100;
  const bump = maxBumpPct((x) => powEval(segs, x), (x) => powDeriv(segs, x), 0.9 * Math.min(-loE, hiE));
  const dens = densityAtUniformOffsets((x) => powEval(segs, x), (x) => powDeriv(segs, x), DENS_N, loE, hiE);
  return { maxErrPbps: maxErr, bumpPct: bump, seamJ: seamJ(segs), peaks: densityPeaks(dens), worstDrift: Math.max(Math.abs(maxErr - f.coreErrPbps), Math.abs(bump - f.bumpPct)) };
}

// ─────────────────────────────────────────────────────────────────────────────
// Selection: coarsest knot pitch h (fewest on-chain segments), then smallest λ, passing ALL gates.
// Shape targets sweep h × λ; Curve targets sweep ncp (5..16, offset-uniform interiors) × λ.
// ─────────────────────────────────────────────────────────────────────────────
const TOL = 0.5; // pbps, Curve fit gate
if (import.meta.main) {
const results: any = { tol_pbps: TOL, seamJMax: SEAM_J_MAX, degree: P, targets: {} };
for (const tg of TARGETS) {
  const isCurve = tg.name.startsWith('curve');
  const nExp = tg.expectedModes ?? 1;
  const peakErr = (s: WallShape) => (nExp === 2 && s.peakAbsOff.length ? Math.max(...s.peakAbsOff.map((o) => Math.abs(o - 15))) : 0);
  // Fidelity floors for the demo targets — structure gates alone let a very coarse knot grid pass
  // with the target visibly distorted: coreErr ≤ 500 pbps (5bp cumulative) AND densErr ≤ 55% (density
  // rel error over the live region — the derivative distorts ~10x faster than the cumulative).
  // Owner-tuned trade (2026-07-10): smoothness + knot economy WIN over exact target replication (55%
  // lets the prune reach bimodal 5-9 knots) — fits keep the shape's ESSENCE (mode/valley count, tail
  // order, skew direction), not its every wiggle. valley targets gate on valleyOk not modes.
  const gates = (f: Fit, s: WallShape | null): boolean => {
    if (isCurve) return f.maxErrPbps <= TOL && f.seamJ <= SEAM_J_MAX && f.peaks === 1;
    // Multi-feature shapes (bimodal peaks+valley, V/barbell) carry NATURAL log-density inflections that
    // seamJ already certifies smooth (bimodal-7 seamJ 0.06 visually clean) — the extraInfl gate over-fires
    // on them, so it applies ONLY to the single-hump shapes where a spurious inflection = a real wave.
    // feature-anchored shapes = ESSENCE demos (bimodal/valley at fewest knots): a σ=5 tall-narrow target
    // can't be reproduced by 7 knots, so drop the fidelity (densErr) + exact-peak-position gates for them;
    // shape identity is guarded by mode/valley count + spur + seamJ. Smooth unimodal shapes keep full gates.
    const anchored = !!tg.featureAnchors;
    const inflOk = anchored ? true : s!.extraInfl === 0;
    const fidOk = anchored ? true : densErrPct(tg, f.segs) <= 55;
    const platMax = (tg.edgeHi - tg.edgeLo) <= 12 ? 3.5 : 2; // narrow ±5 walls: slightly looser ripple
    const base = f.seamJ <= SEAM_J_MAX && inflOk && fidOk && f.coreErrPbps <= 500;
    return tg.valley
      ? base && s!.valleyOk && s!.spuriousLobeMaxPct < 3
      : base && s!.modes === nExp && s!.spuriousLobeMaxPct < 2 && s!.tailMonotone && (anchored || peakErr(s!) <= 1.5) && (!tg.plateau || s!.plateauRipplePct <= platMax);
  };
  let hit: Fit | null = null, hitShape: WallShape | null = null, chosenLambda = 0, chosenHbp = 0, passedGates = false;
  const sweepOut: any[] = [];
  let fall: { f: Fit; s: WallShape | null; lam: number; h: number } | null = null;
  const narrow = !isCurve && (tg.edgeHi - tg.edgeLo) <= 12;
  const hList = isCurve
    ? Array.from({ length: 12 }, (_, k) => 5 + k)
    : (tg.featureAnchors ? [0] : (narrow ? H_SWEEP_NARROW : H_SWEEP));
  outer: for (const h of hList) {
    const interior = isCurve ? curveKnots(tg, (h as number) - P - 1) : shapeKnots(tg, h as number);
    if (isCurve && interior.length !== (h as number) - P - 1) continue; // ncp too small for P+1
    for (const lam of LAMBDAS) {
      const f = fit(tg, interior, lam);
      const s = isCurve ? null : wallShape(tg, f.segs);
      sweepOut.push(isCurve
        ? { ncp: f.ncp, lambda: lam, maxErrPbps: +f.maxErrPbps.toFixed(4), seamJ: +f.seamJ.toFixed(4), peaks: f.peaks }
        : { hBp: h, ncp: f.ncp, lambda: lam, coreErrPbps: +f.coreErrPbps.toFixed(4), seamJ: +f.seamJ.toFixed(4), modes: s!.modes, spuriousLobeMaxPct: +s!.spuriousLobeMaxPct.toFixed(3), tailMonotone: s!.tailMonotone, peakPosErrBp: +peakErr(s!).toFixed(3), plateauRipplePct: +s!.plateauRipplePct.toFixed(3) });
      if (!fall || f.seamJ < fall.f.seamJ) fall = { f, s, lam, h: h as number };
      if (gates(f, s)) { hit = f; hitShape = s; chosenLambda = lam; chosenHbp = isCurve ? 0 : (h as number); passedGates = true; break outer; }
    }
  }
  if (!hit) { hit = fall!.f; hitShape = fall!.s; chosenLambda = fall!.lam; chosenHbp = isCurve ? 0 : fall!.h; }
  // Greedy knot REMOVAL (owner: "fewest knots, near-parity"): repeatedly drop any interior knot whose
  // removal still passes ALL gates — candidates tried least-active first (|Δ²| of the density carriers
  // around the knot; dead-tail and redundant-plateau knots go first). Gate-driven, zero hand tuning.
  // SKIP prune for multimodal/valley feature anchors (peaks ARE the shape). Stable-pack + plateau
  // anchors may prune further toward STABLE_NCP_MAX.
  if (passedGates && (!tg.featureAnchors || tg.plateau || STABLE_PACK.has(tg.name))) {
    let interior = hit.T.slice(P + 1, hit.T.length - P - 1);
    let changed = true;
    while (changed && interior.length > 1) {
      changed = false;
      const act = interior.map((kx, i) => {
        let j = 0, best = Infinity; // carrier whose support center is nearest this knot
        for (let m = 0; m < hit!.d.length; m++) { const xc = (hit!.T[m + 1] + hit!.T[m + P + 1]) / 2; const dd = Math.abs(xc - kx); if (dd < best) { best = dd; j = m; } }
        const dm = Math.max(...hit!.d, 1e-30);
        return Math.abs((hit!.d[j - 1] ?? hit!.d[j]) - 2 * hit!.d[j] + (hit!.d[j + 1] ?? hit!.d[j])) / dm + hit!.d[j] / dm * 1e-3 + i * 1e-9;
      });
      removal: for (const idx of [...interior.keys()].sort((a, b) => act[a] - act[b])) {
        const trial = interior.filter((_, i) => i !== idx);
        // λ-ESCALATION: a removal that fails at the current λ may pass with more smoothing — try the
        // current λ and the next two rungs before rejecting (fewer knots want a stiffer penalty).
        const li = LAMBDAS.indexOf(chosenLambda);
        for (const lam of LAMBDAS.slice(li, li + 3)) {
          const ft = fit(tg, trial, lam);
          const st = isCurve ? null : wallShape(tg, ft.segs);
          if (gates(ft, st)) { interior = trial; hit = ft; hitShape = st; chosenLambda = lam; changed = true; break removal; }
        }
      }
    }
    // λ re-selection at the pruned knots: LARGEST λ still passing = maximum smoothing the gates allow
    // (penalty is deviation-from-target-smoothness ⇒ higher λ hugs the target's own smooth character).
    for (const lam of [...LAMBDAS].reverse()) {
      if (lam <= chosenLambda) break;
      const ft = fit(tg, interior, lam);
      const st = isCurve ? null : wallShape(tg, ft.segs);
      if (gates(ft, st)) { hit = ft; hitShape = st; chosenLambda = lam; break; }
    }
  }
  // Stable-pack port budget: if still above STABLE_NCP_MAX, keep pruning under a slightly relaxed
  // densErr/extraInfl (shape essence retained; absolute target fidelity secondary to gas/ncp).
  if (STABLE_PACK.has(tg.name) && hit.ncp > STABLE_NCP_MAX && passedGates && !isCurve) {
    let interior = hit.T.slice(P + 1, hit.T.length - P - 1);
    const packGates = (f: Fit, s: WallShape): boolean =>
      f.seamJ <= SEAM_J_MAX && densErrPct(tg, f.segs) <= 85 && s.extraInfl <= 1 && f.coreErrPbps <= 500
      && s.modes === nExp && s.spuriousLobeMaxPct < 3 && s.tailMonotone
      && (!tg.plateau || s.plateauRipplePct <= 3.5);
    let changed = true;
    while (changed && interior.length > 1 && hit.ncp > STABLE_NCP_MAX) {
      changed = false;
      removal2: for (let idx = 0; idx < interior.length; idx++) {
        const trial = interior.filter((_, i) => i !== idx);
        const li = LAMBDAS.indexOf(chosenLambda);
        for (const lam of LAMBDAS.slice(Math.max(0, li), li + 4)) {
          const ft = fit(tg, trial, lam);
          const st = wallShape(tg, ft.segs);
          if (packGates(ft, st)) { interior = trial; hit = ft; hitShape = st; chosenLambda = lam; changed = true; break removal2; }
        }
      }
    }
  }
  // Cost of forcing single-peak liquidity: free NNLS fit is ALREADY single-peak for every unimodal
  // target (variation-diminishing) — constraint is a no-op. Only a multi-peak free fit re-fits.
  let uniCost: number | null = null, uniErr: number | null = null;
  if (tg.unimodal) {
    if (hit.peaks === 1) { uniCost = 0; uniErr = hit.coreErrPbps; }
    else { const fu = fit(tg, hit.T.slice(P + 1, hit.T.length - P - 1), chosenLambda, true); uniErr = fu.coreErrPbps; uniCost = fu.coreErrPbps - hit.coreErrPbps; }
  }
  const q = quantize(tg, hit);
  const ws = hitShape;
  results.targets[tg.name] = {
    chosen_ncp: hit.ncp, chosenLambda, chosenHbp, hitTol: isCurve ? hit.maxErrPbps <= TOL : true, gateMetric: isCurve ? 'full' : 'shape',
    maxErrPbps: hit.maxErrPbps, coreErrPbps: hit.coreErrPbps, bumpPct: hit.bumpPct, seamJ: hit.seamJ,
    densErrPct: isCurve ? null : +densErrPct(tg, hit.segs).toFixed(1),
    capitalM: hit.capitalM, peaks: hit.peaks, unimodalD: hit.unimodalD, deBoorRelErr: hit.deBoorRelErr, areaRelErr: hit.areaRelErr,
    shape: ws ? { modes: ws.modes, spuriousLobeMaxPct: +ws.spuriousLobeMaxPct.toFixed(3), tailMonotone: ws.tailMonotone, extraInfl: ws.extraInfl, peakAbsOffBp: ws.peakAbsOff.map((o) => +o.toFixed(2)), peakPosErrBp: nExp === 2 && ws.peakAbsOff.length ? +Math.max(...ws.peakAbsOff.map((o) => Math.abs(o - 15))).toFixed(3) : null, plateauRipplePct: +ws.plateauRipplePct.toFixed(3) } : null,
    edgeBp: Math.max(Math.abs(tg.edgeLo), Math.abs(tg.edgeHi)), edgeLoBp: tg.edgeLo, edgeHiBp: tg.edgeHi,
    stablePack: STABLE_PACK.has(tg.name),
    passedGates,
    portNcpOk: hit.ncp <= STABLE_NCP_MAX,
    uniEnforcedCoreErrPbps: uniErr, uniCostPbps: uniCost,
    quant: q,
    sweep: sweepOut,
    w: hit.w.map((v) => +v.toFixed(4)), deltaW: hit.e.map((v) => +v.toFixed(6)), d: hit.d.map((v) => +v.toFixed(6)),
    // UI series — sampled through powEval/powDeriv, the EXACT on-chain path, so the visualizer plots
    // the deployed object, not the mathematical ideal.
    series: {
      rows: Array.from({ length: 501 }, (_, k) => { const x = (k / 500) * BPS; return [Math.round(volAtX(x)), +(powEval(hit.segs, x) / 100).toFixed(4)]; }),
      density: densityAtUniformOffsets((x) => powEval(hit.segs, x), (x) => powDeriv(hit.segs, x), DENS_N,
        powEval(hit.segs, 0) / 100, powEval(hit.segs, BPS) / 100).map(([o, dv]) => [+o.toFixed(4), +dv.toFixed(1)]),
      knotsBps: hit.T.slice(P + 1, hit.T.length - P - 1).map((t) => +(volAtX(t) / 1e6).toFixed(3)), // interior knots, $M vol coord
    },
  };
}

// FC comparison: current best FC profile smooth_concentrated (14 knots). Same maxBumpPct code path.
const fc = PROFILES.smooth_concentrated; const fcPts = splinePoints(fc.knots, fc.weights, 1000);
const fcEdge = Math.abs((fc.knots[fc.knots.length - 1] * 1000) / 100 / 100);
const fcBump = maxBumpPct((x) => hermiteEval(fcPts, x), (x) => hermiteDeriv(fcPts, x), fcEdge);
results.fc = { knots: fc.knots.length, bumpPct: +fcBump.toFixed(4), contBreak: 'y″ jumps at every knot (C1 only)' };
results.stableNcpMax = STABLE_NCP_MAX;
results.stablePack = [...STABLE_PACK];

// Report-only wall sweep for Uni-flat density at ±{3,5,10}bp (not three production profiles).
results.wallSweep = {} as Record<string, any>;
for (const wall of WALL_SWEEP_BP) {
  const a = wall * 0.7, c = wall;
  const tg = densityTarget(`uni_flat_w${wall}`, -wall, wall, (o) => {
    const ao = Math.abs(o);
    return ao <= a ? 1 : ao >= c ? 0 : Math.sqrt(Math.max(0, 1 - ((ao - a) / (c - a)) ** 2));
  }, true);
  tg.plateau = true;
  tg.featureAnchors = wall <= 5 ? [-wall * 0.64, wall * 0.64] : [-wall * 0.84, -wall * 0.5, 0, wall * 0.5, wall * 0.84];
  let best: Fit | null = null, bestLam = 0, ok = false;
  for (const lam of LAMBDAS) {
    const f = fit(tg, shapeKnots(tg, 0), lam);
    const s = wallShape(tg, f.segs);
    const pass = f.seamJ <= SEAM_J_MAX && s.modes === 1 && s.spuriousLobeMaxPct < 2 && s.tailMonotone
      && s.plateauRipplePct <= 3.5 && f.coreErrPbps <= 500;
    if (!best || f.seamJ < best.seamJ) { best = f; bestLam = lam; }
    if (pass) { best = f; bestLam = lam; ok = true; break; }
  }
  // light prune toward ≤STABLE_NCP_MAX
  if (ok && best) {
    let interior = best.T.slice(P + 1, best.T.length - P - 1);
    let changed = true;
    while (changed && interior.length > 1 && best.ncp > STABLE_NCP_MAX) {
      changed = false;
      for (let idx = 0; idx < interior.length; idx++) {
        const trial = interior.filter((_, i) => i !== idx);
        const ft = fit(tg, trial, bestLam);
        const st = wallShape(tg, ft.segs);
        const pass = ft.seamJ <= SEAM_J_MAX && st.modes === 1 && st.spuriousLobeMaxPct < 2 && st.tailMonotone
          && st.plateauRipplePct <= 3.5 && ft.coreErrPbps <= 500;
        if (pass) { interior = trial; best = ft; changed = true; break; }
      }
    }
  }
  results.wallSweep[`±${wall}`] = {
    wallBp: wall, ncp: best!.ncp, knots: best!.ncp - P - 1, seamJ: +best!.seamJ.toFixed(4),
    lambda: bestLam, passedGates: ok, portNcpOk: best!.ncp <= STABLE_NCP_MAX,
    plateauRipplePct: +wallShape(tg, best!.segs).plateauRipplePct.toFixed(3),
  };
}

await Bun.write('out/spline_bspline.json', JSON.stringify(results, null, 2));
for (const [name, t] of Object.entries<any>(results.targets)) {
  const pack = t.stablePack ? ' PACK' : '';
  const gate = t.passedGates ? 'ok' : 'FALL';
  const ncpGate = t.portNcpOk ? '≤9' : '>9';
  console.log(`${name.padEnd(14)} knots=${String(t.chosen_ncp - P - 1).padStart(2)} ncp=${String(t.chosen_ncp).padStart(2)}(${ncpGate}) h=${t.chosenHbp || '-'} λ=${t.chosenLambda} J=${t.seamJ.toFixed(3)} gate=${gate}${pack} coreErr=${t.coreErrPbps.toFixed(2)}pbps`);
}
console.log('wallSweep', JSON.stringify(results.wallSweep));
console.log('FC smooth_concentrated bump%=', fcBump.toFixed(3), 'knots=', fc.knots.length);
} // import.meta.main
