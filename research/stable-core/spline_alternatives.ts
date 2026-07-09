// spline_alternatives.ts — VISUAL COMPARISON ONLY, not for production. Shows what the SAME knot/weight
// configuration looks like under different tangent/curvature constructions: Fritsch-Carlson (current,
// C1), Hyman-filtered global cubic (C2 "almost everywhere"), and monotone quintic Hermite (true C2 by
// construction, when the fixup actually converges). All math re-derives from spline_search_lib.ts's
// verified splinePoints/tangents/hermiteEval — nothing here changes what ships on-chain.
import { type Pt, BPS, splinePoints, tangents as tangentsFC, hermiteEval as hermiteEvalFC, hermiteDeriv as hermiteDerivFC } from './spline_search_lib.ts';

// ── Hyman-filtered global cubic (de Boor-Swartz box clamp on a global C2 tridiagonal solve) ──
function hymanTangents(pts: Pt[]): number[] {
  const n = pts.length;
  const h: number[] = [], S: number[] = [];
  for (let i = 0; i < n - 1; i++) { h.push(pts[i + 1][0] - pts[i][0]); S.push((pts[i + 1][1] - pts[i][1]) / h[i]); }
  const a = new Array(n).fill(0), b = new Array(n).fill(0), c = new Array(n).fill(0), d = new Array(n).fill(0);
  b[0] = 1; d[0] = S[0]; b[n - 1] = 1; d[n - 1] = S[n - 2];
  for (let i = 1; i < n - 1; i++) { a[i] = h[i]; b[i] = 2 * (h[i - 1] + h[i]); c[i] = h[i - 1]; d[i] = 3 * (h[i] * S[i - 1] + h[i - 1] * S[i]); }
  const cp = new Array(n).fill(0), dp = new Array(n).fill(0);
  cp[0] = c[0] / b[0]; dp[0] = d[0] / b[0];
  for (let i = 1; i < n; i++) { const m = b[i] - a[i] * cp[i - 1]; cp[i] = c[i] / m; dp[i] = (d[i] - a[i] * dp[i - 1]) / m; }
  const m = new Array(n).fill(0); m[n - 1] = dp[n - 1];
  for (let i = n - 2; i >= 0; i--) m[i] = dp[i] - cp[i] * m[i + 1];
  for (let i = 1; i < n - 1; i++) {
    const Sprev = S[i - 1], Scurr = S[i];
    if (Sprev * Scurr <= 0) { m[i] = 0; continue; }
    const hi = 3 * Math.min(Math.abs(Sprev), Math.abs(Scurr));
    const sign = Sprev >= 0 ? 1 : -1; const signedVal = m[i] * sign;
    if (signedVal < 0) m[i] = 0; else if (signedVal > hi) m[i] = sign * hi;
  }
  return m;
}
export function hymanEval(pts: Pt[], m: number[], x: number): number {
  const n = pts.length; if (x <= pts[0][0]) return pts[0][1]; if (x >= pts[n - 1][0]) return pts[n - 1][1];
  let i = 0; while (i < n - 2 && x >= pts[i + 1][0]) i++;
  const p0 = pts[i], p1 = pts[i + 1]; const h = p1[0] - p0[0]; const m0 = m[i], m1 = m[i + 1];
  const dy = p1[1] - p0[1]; const k0 = m0 * h, k1 = m1 * h; const c2 = 3 * dy - 2 * k0 - k1, c3 = -2 * dy + k0 + k1; const t = (x - p0[0]) / h;
  return p0[1] + k0 * t + c2 * t * t + c3 * t * t * t;
}
export function hymanDeriv(pts: Pt[], m: number[], x: number): number {
  const n = pts.length; let xc = x; if (xc <= pts[0][0]) xc = pts[0][0] + 1e-6; if (xc >= pts[n - 1][0]) xc = pts[n - 1][0] - 1e-6;
  let i = 0; while (i < n - 2 && xc >= pts[i + 1][0]) i++;
  const p0 = pts[i], p1 = pts[i + 1]; const h = p1[0] - p0[0]; const m0 = m[i], m1 = m[i + 1];
  const dy = p1[1] - p0[1]; const k0 = m0 * h, k1 = m1 * h; const c2 = 3 * dy - 2 * k0 - k1, c3 = -2 * dy + k0 + k1; const t = (xc - p0[0]) / h;
  return (k0 + 2 * c2 * t + 3 * c3 * t * t) / h;
}
export function hymanBuild(knots: number[], weights: number[], disp: number) {
  const pts = splinePoints(knots, weights, disp);
  const m = hymanTangents(pts);
  return { pts, m };
}

// ── Monotone quintic Hermite (basis verified against ACM TOMS Algorithm 1031 / MQSI course notes;
// IS_MONOTONE ported literally from the downloaded reference Fortran). Construction: FC-safe f', a
// global-C2 f'' with local shrink-to-monotone fixup (NOTE: this simplified fixup does NOT reliably
// converge for arbitrary/aggressive configs — verified earlier this session, 0/30 random profiles
// converged — shown here ONLY for gentle, already-smooth configs where it's known to hold). ──
function computeFprimeQuintic(pts: Pt[]): number[] {
  const n = pts.length; const f = new Array(n).fill(0);
  for (let i = 0; i < n - 1; i++) { const [m0, m1] = tangentsFC(pts, i, n); if (i === 0) f[0] = m0; f[i + 1] = m1; }
  return f;
}
function computeFdoubleprime(pts: Pt[]): number[] {
  const n = pts.length; const h: number[] = [], S: number[] = [];
  for (let i = 0; i < n - 1; i++) { h.push(pts[i + 1][0] - pts[i][0]); S.push((pts[i + 1][1] - pts[i][1]) / h[i]); }
  const a = new Array(n).fill(0), b = new Array(n).fill(0), c = new Array(n).fill(0), d = new Array(n).fill(0);
  b[0] = 1; d[0] = 0; b[n - 1] = 1; d[n - 1] = 0;
  for (let i = 1; i < n - 1; i++) { a[i] = h[i - 1]; b[i] = 2 * (h[i - 1] + h[i]); c[i] = h[i]; d[i] = 6 * (S[i] - S[i - 1]); }
  const cp = new Array(n).fill(0), dp = new Array(n).fill(0);
  cp[0] = c[0] / b[0]; dp[0] = d[0] / b[0];
  for (let i = 1; i < n; i++) { const m = b[i] - a[i] * cp[i - 1]; cp[i] = c[i] / m; dp[i] = (d[i] - a[i] * dp[i - 1]) / m; }
  const f2 = new Array(n).fill(0); f2[n - 1] = dp[n - 1];
  for (let i = n - 2; i >= 0; i--) f2[i] = dp[i] - cp[i] * f2[i + 1];
  return f2;
}
function isMonotoneQuintic(u0: number, u1: number, f0: number, f1: number, df0: number, df1: number, ddf0: number, ddf1: number): boolean {
  const EPS = 1e-14;
  if (Math.abs(f1 - f0) < EPS * (1 + Math.abs(f1) + Math.abs(f0))) return df0 === 0 && df1 === 0 && ddf0 === 0 && ddf1 === 0;
  const sign = f1 > f0 ? 1 : -1; const w = u1 - u0;
  if (Math.abs(df0) < EPS || Math.abs(df1) < EPS) {
    if (sign * ddf1 * w > sign * 4 * df1) return false;
    let temp = df0 * (4 * df1 - ddf1 * w); if (temp > 0) temp = 2 * Math.sqrt(temp);
    if (temp + sign * (3 * df0 + ddf0 * w) < 0) return false;
    if (60 * (f1 - f0) * sign - w * (sign * (24 * df0 + 32 * df1) - 2 * temp + w * sign * (3 * ddf0 - 5 * ddf1)) < 0) return false;
    return true;
  } else {
    if (w * (2 * Math.sqrt(df0 * df1) - sign * 3 * (df0 + df1)) - sign * 24 * (f0 - f1) <= 0) return false;
    const t = Math.pow(df0 * df1, 0.75);
    const alpha = sign * (4 * df1 - ddf1 * w) * Math.sqrt(sign * df0) / t;
    const gamma = sign * (4 * df0 + ddf0 * w) * Math.sqrt(sign * df1) / t;
    const beta = sign * (3 * ((ddf1 - ddf0) * w - 8 * (df0 + df1)) + 60 * (f1 - f0) / w) / (2 * Math.sqrt(df0 * df1));
    const thresh = beta <= 6 ? -(beta + 2) / 2 : -2 * Math.sqrt(beta - 2);
    return alpha > thresh && gamma > thresh;
  }
}
function fixupQuintic(pts: Pt[], fp: number[], f2: number[], maxIter = 60): { f2: number[]; converged: boolean } {
  const n = pts.length; const g = f2.slice();
  for (let iter = 0; iter < maxIter; iter++) {
    let anyFail = false;
    for (let i = 0; i < n - 1; i++) {
      const ok = isMonotoneQuintic(pts[i][0], pts[i + 1][0], pts[i][1], pts[i + 1][1], fp[i], fp[i + 1], g[i], g[i + 1]);
      if (!ok) { anyFail = true; g[i] *= 0.7; g[i + 1] *= 0.7; }
    }
    if (!anyFail) return { f2: g, converged: true };
  }
  let stillFailing = 0;
  for (let i = 0; i < n - 1; i++) if (!isMonotoneQuintic(pts[i][0], pts[i + 1][0], pts[i][1], pts[i + 1][1], fp[i], fp[i + 1], g[i], g[i + 1])) stillFailing++;
  return { f2: g, converged: stillFailing === 0 };
}
export function quinticEval(pts: Pt[], fp: number[], f2: number[], x: number): number {
  const n = pts.length; if (x <= pts[0][0]) return pts[0][1]; if (x >= pts[n - 1][0]) return pts[n - 1][1];
  let i = 0; while (i < n - 2 && x >= pts[i + 1][0]) i++;
  const x0 = pts[i][0], x1 = pts[i + 1][0], h = x1 - x0, t = (x - x0) / h;
  const p0 = pts[i][1], p1 = pts[i + 1][1], v0 = fp[i] * h, v1 = fp[i + 1] * h, a0 = f2[i] * h * h, a1 = f2[i + 1] * h * h;
  const t2 = t * t, t3 = t2 * t, t4 = t3 * t, t5 = t4 * t;
  const H0 = 1 - 10 * t3 + 15 * t4 - 6 * t5, H1 = t - 6 * t3 + 8 * t4 - 3 * t5, H2 = 0.5 * t2 - 1.5 * t3 + 1.5 * t4 - 0.5 * t5;
  const H3 = 0.5 * t3 - t4 + 0.5 * t5, H4 = -4 * t3 + 7 * t4 - 3 * t5, H5 = 10 * t3 - 15 * t4 + 6 * t5;
  return H0 * p0 + H1 * v0 + H2 * a0 + H3 * a1 + H4 * v1 + H5 * p1;
}
export function quinticDeriv(pts: Pt[], fp: number[], f2: number[], x: number): number {
  const n = pts.length; let xc = x; if (xc <= pts[0][0]) xc = pts[0][0] + 1e-6; if (xc >= pts[n - 1][0]) xc = pts[n - 1][0] - 1e-6;
  let i = 0; while (i < n - 2 && xc >= pts[i + 1][0]) i++;
  const x0 = pts[i][0], x1 = pts[i + 1][0], h = x1 - x0, t = (xc - x0) / h;
  const p0 = pts[i][1], p1 = pts[i + 1][1], v0 = fp[i] * h, v1 = fp[i + 1] * h, a0 = f2[i] * h * h, a1 = f2[i + 1] * h * h;
  const t2 = t * t, t3 = t2 * t, t4 = t3 * t;
  const dH0 = -30 * t2 + 60 * t3 - 30 * t4, dH1 = 1 - 18 * t2 + 32 * t3 - 15 * t4, dH2 = t - 4.5 * t2 + 6 * t3 - 2.5 * t4;
  const dH3 = 1.5 * t2 - 4 * t3 + 2.5 * t4, dH4 = -12 * t2 + 28 * t3 - 15 * t4, dH5 = 30 * t2 - 60 * t3 + 30 * t4;
  return (dH0 * p0 + dH1 * v0 + dH2 * a0 + dH3 * a1 + dH4 * v1 + dH5 * p1) / h;
}
export function quinticBuild(knots: number[], weights: number[], disp: number) {
  const pts = splinePoints(knots, weights, disp);
  const fp = computeFprimeQuintic(pts);
  const f2raw = computeFdoubleprime(pts);
  const { f2, converged } = fixupQuintic(pts, fp, f2raw);
  return { pts, fp, f2, converged };
}
