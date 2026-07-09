// spline_search_lib.ts — SHARED, VERIFIED evaluation core for the FC knot/weight search.
// Tangent math re-verified line-by-line against dex/evm/src/libraries/Spline.sol:96-135 (2026-07-09).
// Every search worker imports THIS file rather than reimplementing the math — the whole point of a
// shared scorer is to eliminate the risk of divergent, independently-buggy re-implementations.
export type Pt = [number, number];
export const BPS = 10_000, WEIGHT_SUM = 200;

export function splinePoints(knots: number[], weights: number[], disp: number): Pt[] {
  const pts: Pt[] = [[0, (knots[0] * disp) / 100]];
  let cum = 0;
  for (let i = 0; i < weights.length; i++) { cum += weights[i]; pts.push([(cum * BPS) / WEIGHT_SUM, (knots[i + 1] * disp) / 100]); }
  return pts;
}
const sameSignBit = (a: number, b: number) => (a >= 0) === (b >= 0);
export function tangents(pts: Pt[], i: number, n: number): [number, number] {
  const p0 = pts[i], p1 = pts[i + 1];
  const s = (p1[1] - p0[1]) / (p1[0] - p0[0]);
  let m0: number, m1: number;
  if (i === 0) m0 = s; else { const pm = pts[i - 1]; const sp = (p0[1] - pm[1]) / (p0[0] - pm[0]); m0 = sameSignBit(sp, s) ? (sp + s) / 2 : 0; }
  if (i === n - 2) m1 = s; else { const p2 = pts[i + 2]; const sn = (p2[1] - p1[1]) / (p2[0] - p1[0]); m1 = sameSignBit(s, sn) ? (s + sn) / 2 : 0; }
  // BUG FIX 2026-07-09 (upstream Spline.sol commit c6d9516): this early return used to skip the clamp on a
  // flat segment, letting nonzero neighbor-averaged tangents leak through uncapped (over-integration / LP
  // drain in area()). Deleted to match — see spline_shape.ts's tangents() for the full note. Stale copy,
  // fixed for consistency; not used by the current production generator (spline_shape.ts owns that).
  const m0a = Math.abs(m0), m1a = Math.abs(m1), sa = Math.abs(s);
  const sumSq = m0a * m0a + m1a * m1a, nineSSq = 9 * sa * sa;
  if (sumSq <= nineSSq) return [m0, m1];
  const scale = (3 * sa) / Math.sqrt(sumSq);
  return [m0 * scale, m1 * scale];
}
export function hermiteEval(pts: Pt[], x: number): number {
  const n = pts.length;
  if (n === 0) return 0;
  if (n === 1 || x <= pts[0][0]) return pts[0][1];
  if (x >= pts[n - 1][0]) return pts[n - 1][1];
  let i = 0; while (i < n - 2 && x >= pts[i + 1][0]) i++;
  const p0 = pts[i], p1 = pts[i + 1];
  const h = p1[0] - p0[0];
  const [m0, m1] = tangents(pts, i, n);
  const dy = p1[1] - p0[1];
  const k0 = m0 * h, k1 = m1 * h;
  const c2 = 3 * dy - 2 * k0 - k1, c3 = -2 * dy + k0 + k1;
  const t = (x - p0[0]) / h;
  return p0[1] + k0 * t + c2 * t * t + c3 * t * t * t;
}
export function hermiteDeriv(pts: Pt[], x: number): number {
  const n = pts.length;
  let xc = x; if (xc <= pts[0][0]) xc = pts[0][0] + 1e-6; if (xc >= pts[n - 1][0]) xc = pts[n - 1][0] - 1e-6;
  let i = 0; while (i < n - 2 && xc >= pts[i + 1][0]) i++;
  const p0 = pts[i], p1 = pts[i + 1];
  const h = p1[0] - p0[0];
  const [m0, m1] = tangents(pts, i, n);
  const dy = p1[1] - p0[1];
  const k0 = m0 * h, k1 = m1 * h;
  const c2 = 3 * dy - 2 * k0 - k1, c3 = -2 * dy + k0 + k1;
  const t = (xc - p0[0]) / h;
  return (k0 + 2 * c2 * t + 3 * c3 * t * t) / h;
}

// ── validity per PoolAdmin.sol:17-40: weights sum=200 (≤16 segments), knots monotonic non-decreasing, span=100.
// MIN_KNOT_GAP guards against a degenerate exploit found during search: two knots collapsed to within a
// vanishingly small distance pass the naive monotonicity check but create a near-infinite-density "needle"
// segment that an under-sampled wiggle-check can't see — technically valid, practically undeployable.
const MIN_KNOT_GAP = 0.02; // the found degenerate exploit had a gap of ~3.6e-5; legitimate aggressive
                            // near-edge concentration goes down to ~0.1-0.3 — 0.02 separates them cleanly
export function isValidProfile(knots: number[], weights: number[]): boolean {
  if (weights.length < 1 || weights.length > 16) return false;
  const sum = weights.reduce((a, b) => a + b, 0);
  if (Math.abs(sum - 200) > 1e-6) return false;
  for (let i = 1; i < knots.length; i++) {
    if (knots[i] < knots[i - 1] - 1e-9) return false;
    if (knots[i] - knots[i - 1] < MIN_KNOT_GAP && knots[i] - knots[i - 1] > 1e-9) return false; // reject a tiny-but-nonzero Y-gap (the exploit); an EXACT 0 gap (deliberate flat segment) is fine
  }
  if (Math.abs((knots[knots.length - 1] - knots[0]) - 100) > 1e-6) return false;
  return true;
}

// ── scoring: minimize density wiggle AND plateau-width (peakedness), subject to a real-concentration
// floor vs Default. A pure wiggle-minimizer degenerates toward a broad, gently-tapering PLATEAU (low
// curvature = low wiggle) rather than genuine concentration — hwhmBp (half-width at half-max density)
// catches this: a small hwhmBp means density actually falls off near the peak, not just far past it. ──
// Default's ±1bp depth at disp=1000 is exactly $1.0M (linear profile) — used as the concentration floor.
export const DEFAULT_WITHIN_1BP = 1_000_000;
// PEAK_DENSITY_CAP: a DIRECT sanity bound, not an indirect knot-gap proxy. Found THREE times now that
// knot-gap thresholds alone leak — a gap can sit just above any chosen threshold and still produce an
// absurd, undeployable peak (one candidate scored $198 BILLION/bp with a gap 3x the guard's minimum).
// Nothing legitimate should need more than ~100x Default's implicit $1M/bp density.
const PEAK_DENSITY_CAP = 100 * DEFAULT_WITHIN_1BP;
export interface Score { maxWigglePct: number; violCount: number; violFrac: number; within1bp: number; within05bp: number; peakDensity: number; hwhmBp: number; curveMonotone: boolean; valid: boolean; }
export function scoreProfile(knots: number[], weights: number[], disp = 1000, N = 2000): Score {
  if (!isValidProfile(knots, weights)) return { maxWigglePct: Infinity, violCount: Infinity, violFrac: 1, within1bp: 0, within05bp: 0, peakDensity: 0, hwhmBp: Infinity, curveMonotone: false, valid: false };
  const pts = splinePoints(knots, weights, disp);
  const n = pts.length;
  let curveMonotone = true, prevOff = -Infinity;
  const densPts: [number, number][] = [];
  for (let i = 0; i <= N; i++) {
    const x = (i / N) * BPS;
    const off = hermiteEval(pts, x);
    if (off < prevOff - 1e-7) curveMonotone = false;
    prevOff = off;
    const d = hermiteDeriv(pts, x);
    const doffBps_dvol = (d / 100) / 1000;
    if (doffBps_dvol > 1e-12) densPts.push([off / 100, 1 / doffBps_dvol]);
  }
  const half = densPts.filter(p => p[0] >= 0).sort((a, b) => a[0] - b[0]);
  let viol = 0, maxPct = 0;
  for (let i = 1; i < half.length; i++) { if (half[i][1] > half[i - 1][1]) { viol++; maxPct = Math.max(maxPct, (half[i][1] / half[i - 1][1] - 1) * 100); } }
  const within = (bp: number) => { let lo = 0, hi = 5_000_000; for (let it = 0; it < 44; it++) { const mid = (lo + hi) / 2; const x = 5000 + mid / 1000; const off = hermiteEval(pts, x) / 100; if (Math.abs(off) <= bp) lo = mid; else hi = mid; } return lo; };
  const peakDensity = half.length ? half[0][1] : 0; // density AT (or nearest) center — the true peak, since half is sorted by ascending offset from 0
  let hwhmBp = half.length ? half[half.length - 1][0] : Infinity;
  for (const p of half) { if (p[1] <= peakDensity / 2) { hwhmBp = p[0]; break; } }
  if (peakDensity > PEAK_DENSITY_CAP) return { maxWigglePct: Infinity, violCount: Infinity, violFrac: 1, within1bp: 0, within05bp: 0, peakDensity, hwhmBp, curveMonotone: false, valid: false }; // reject as degenerate, regardless of knot-gap distance
  return { maxWigglePct: maxPct, violCount: viol, violFrac: half.length ? viol / half.length : 1, within1bp: within(1), within05bp: within(0.5), peakDensity, hwhmBp, curveMonotone, valid: true };
}
