import { BPS, curveOffsetBps, CURVE_BENCHMARKS } from './spline_shape.ts';
import { clampedKnots, segPowerBasis, powEval, powArea } from './spline_bspline.ts';

// Reconstruct a bspline value fn (de Boor) locally to compare — copy of primitives.
const P = 3;
function findSpan(deg: number, T: number[], ncp: number, x: number): number {
  const n = ncp - 1;
  if (x >= T[n + 1]) return n;
  if (x <= T[deg]) return deg;
  let lo = deg, hi = n + 1, mid = (lo + hi) >> 1;
  while (x < T[mid] || x >= T[mid + 1]) { if (x < T[mid]) hi = mid; else lo = mid; mid = (lo + hi) >> 1; }
  return mid;
}
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

// Build a few representative monotone control setups from Curve targets.
function makeW(A: number, ncp: number): { T: number[]; w: number[] } {
  const T = clampedKnots(ncp, 0, BPS);
  // control points = target offset at greville abscissae (monotone-ish); ensure Δw≥0 by cumulative offset.
  const off = (x: number) => (curveOffsetBps((x - 5000) * 1000, A) ?? 0) * 100;
  const w: number[] = [];
  for (let i = 0; i < ncp; i++) {
    // greville
    let g = 0; for (let k = 1; k <= P; k++) g += T[i + k]; g /= P;
    w.push(off(g));
  }
  // enforce nondecreasing
  for (let i = 1; i < ncp; i++) if (w[i] < w[i - 1]) w[i] = w[i - 1];
  return { T, w };
}

const cases = [
  makeW(CURVE_BENCHMARKS.A4000, 6),
  makeW(CURVE_BENCHMARKS.A1500, 6),
  makeW(CURVE_BENCHMARKS.A256, 8),
  makeW(CURVE_BENCHMARKS.A4000, 10),
];

// (a) power-basis == de Boor at 10k random pts
let worstRelA = 0, worstAbsA = 0;
for (const { T, w } of cases) {
  const segs = segPowerBasis(T, w);
  for (let k = 0; k < 10000; k++) {
    const x = Math.random() * BPS;
    const a = bsplineEval(P, T, w, x), c = powEval(segs, x);
    const rel = Math.abs(a - c) / Math.max(Math.abs(a), 1);
    worstRelA = Math.max(worstRelA, rel);
    worstAbsA = Math.max(worstAbsA, Math.abs(a - c));
  }
}

// (b) clamped-end exact interpolation y(x0)=w_first, y(xN)=w_last
let worstEnd = 0;
for (const { T, w } of cases) {
  const segs = segPowerBasis(T, w);
  const y0 = powEval(segs, 0), yN = powEval(segs, BPS);
  worstEnd = Math.max(worstEnd, Math.abs(y0 - w[0]), Math.abs(yN - w[w.length - 1]));
  // also de Boor endpoints
  worstEnd = Math.max(worstEnd, Math.abs(bsplineEval(P, T, w, 0) - w[0]), Math.abs(bsplineEval(P, T, w, BPS) - w[w.length - 1]));
}

// (c) segment antiderivative vs numeric quadrature (high-order) on 1k random intervals
let worstRelC = 0;
for (const { T, w } of cases) {
  const segs = segPowerBasis(T, w);
  for (let k = 0; k < 250; k++) {
    let xa = Math.random() * BPS, xb = Math.random() * BPS; if (xb < xa) [xa, xb] = [xb, xa];
    if (xb - xa < 1) continue;
    // composite Simpson, many points
    const NQ = 4000; const h = (xb - xa) / NQ; let s = powEval(segs, xa) + powEval(segs, xb);
    for (let i = 1; i < NQ; i++) s += (i % 2 ? 4 : 2) * powEval(segs, xa + i * h);
    const num = (h / 3) * s;
    const clf = powArea(segs, xa, xb);
    const rel = Math.abs(clf - num) / Math.max(Math.abs(num), 1);
    worstRelC = Math.max(worstRelC, rel);
  }
}

// (d) fixed-point scaling worst-case intermediate magnitudes.
// y up to ~500 pbps, x up to 10000 bps, P=1e18. Analyze on-chain int math.
// Contract stores per-seg: y0,k0,c2,c3 (in pbps*P), x0/x1/d (bps, maybe *P or raw int).
// eval Horner: t=(x-x0)/d in [0,1]; if fixed-point t scaled by P: tP = (x-x0)*P/d.
// Horner term: s.y0 + t*(k0 + t*(c2 + t*c3)). Each mult of two P-scaled quantities needs /P.
// Worst intermediate BEFORE /P divide: coeff(P-scaled ~500*1e18=5e20) * tP(~1e18) = 5e38. Fine.
// But naive (val*tP) chained: max coeff magnitude ~ |c3| etc.
const P18 = 1e18;
let worstCoeffAbs = 0;
for (const { T, w } of cases) {
  for (const s of segPowerBasis(T, w)) {
    worstCoeffAbs = Math.max(worstCoeffAbs, Math.abs(s.y0), Math.abs(s.k0), Math.abs(s.c2), Math.abs(s.c3));
  }
}
// pbps coeff max (~ up to a few hundred to ~1e3 for k with steep segs). Scale to P.
const coeffP = worstCoeffAbs * P18;           // P-scaled coeff magnitude
const tP = 1 * P18;                            // t in [0,1] scaled by P
const mulNoReduce = coeffP * tP;               // worst product before /P
// area: F = d * (t*(y0 + t*(k0/2 + t*(c2/3 + t*c3/4)))). d up to ~1e4 (bps). If d raw int *coeffP*tP...
const dMax = BPS;
const areaWorst = dMax * coeffP * tP;          // if all P-scaled and multiplied w/o intermediate reduce
const INT256_MAX = 5.789e76;

console.log(JSON.stringify({
  a_worstRel: worstRelA, a_worstAbs: worstAbsA,
  b_worstEndErr: worstEnd,
  c_worstRel: worstRelC,
  d_worstCoeffAbs_pbps: worstCoeffAbs,
  d_coeffP: coeffP, d_mulNoReduce: mulNoReduce, d_areaWorst: areaWorst,
  d_int256_max: INT256_MAX,
  d_mulNoReduce_over_1e70: mulNoReduce > 1e70,
  d_areaWorst_over_1e70: areaWorst > 1e70,
  d_areaWorst_over_int256: areaWorst > INT256_MAX,
}, null, 2));
