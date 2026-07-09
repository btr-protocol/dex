// spline_shape.ts — the REAL Hermite spline shape, ported 1:1 from the on-chain algorithm
// (dex/evm/src/libraries/Spline.sol: eval/_tangents — monotone cubic Hermite, Fritsch-Carlson
// tangents + α²+β²≤9 overshoot clamp). aimm.ts/aimm.rs are DELIBERATELY linear-only ("ponytail"
// ceiling, exact only for collinear knots) — this file is the first faithful cubic port for
// analysis, so a non-collinear profile can be visualized correctly.
type Pt = [number, number]; // [depth-coord x ∈ [0,BPS], offset y ∈ PBPS]
const BPS = 10_000, WEIGHT_SUM = 200;

function splinePoints(knots: number[], weights: number[], disp: number): Pt[] {
  const pts: Pt[] = [[0, (knots[0] * disp) / 100]];
  let cum = 0;
  for (let i = 0; i < weights.length; i++) { cum += weights[i]; pts.push([(cum * BPS) / WEIGHT_SUM, (knots[i + 1] * disp) / 100]); }
  return pts;
}

// Spline.sol:_tangents — standard Fritsch-Carlson: zero tangent when adjacent secants disagree in
// sign (sp*s<=0), else simple average; then the α²+β²≤9 magnitude clamp (Spline.sol:117-134).
function tangents(pts: Pt[], i: number, n: number): [number, number] {
  const p0 = pts[i], p1 = pts[i + 1];
  const s = (p1[1] - p0[1]) / (p1[0] - p0[0]);
  let m0: number, m1: number;
  if (i === 0) m0 = s; else { const pm = pts[i - 1]; const sp = (p0[1] - pm[1]) / (p0[0] - pm[0]); m0 = sp * s <= 0 ? 0 : (sp + s) / 2; }
  if (i === n - 2) m1 = s; else { const p2 = pts[i + 2]; const sn = (p2[1] - p1[1]) / (p2[0] - p1[0]); m1 = s * sn <= 0 ? 0 : (s + sn) / 2; }
  if (s === 0) return [m0, m1];
  const m0a = Math.abs(m0), m1a = Math.abs(m1), sa = Math.abs(s);
  const sumSq = m0a * m0a + m1a * m1a, nineSSq = 9 * sa * sa;
  if (sumSq <= nineSSq) return [m0, m1];
  const scale = (3 * sa) / Math.sqrt(sumSq);
  return [m0 * scale, m1 * scale];
}

// Spline.sol:eval — cubic Hermite basis (c2,c3 from tangents k0,k1 and Δy), Horner-evaluated.
function hermiteEval(pts: Pt[], x: number): number {
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

// ── Profiles: DEPLOYED default (collinear ⇒ cubic degenerates to a straight line — not a bug,
// a mathematical consequence of equal knots+weights) vs an EXAMPLE non-collinear "concentrated"
// profile (same ±50 knot ceiling, same total weight budget — front-loads depth-coordinate to the
// center so most volume trades near-zero offset, tapering fast only at the very edge). ──
const DEFAULT_K = [-50, -25, 0, 25, 50], DEFAULT_W = [50, 50, 50, 50];
const CONC_K = [-50, -5, 0, 5, 50], CONC_W = [10, 90, 90, 10];
const L = 10_000_000; // $10M/side reserve, same convention as compute_shapes.ts

function sampleProfile(knots: number[], weights: number[], disp: number) {
  const pts = splinePoints(knots, weights, disp);
  const N = 2000; // fine grid: the concentrated profile's center is near-flat, needs resolution to resolve the spike
  const rows: { x: number; volUsd: number; offsetBps: number }[] = [];
  for (let i = 0; i <= N; i++) {
    const x = (i / N) * BPS;
    const offsetPbps = hermiteEval(pts, x);
    const volUsd = (x - 5000) * 1000; // vf=|x-center|; depth=L @ coverage=1 ⇒ volUsd=(x-5000)*L/BPS*... = (x-5000)*1000
    rows.push({ x, volUsd, offsetBps: offsetPbps / 100 });
  }
  // density(offset) = |Δvolume/Δoffset| — the actual liquidity density (bell/spike), the DERIVATIVE of the
  // offset(volume) curve above. Computed from consecutive samples on the fine grid; offset(volume) is
  // monotonic by construction (Fritsch-Carlson preserves monotonicity) so this stays well-defined.
  const density: [number, number][] = [];
  for (let i = 1; i < rows.length; i++) {
    const a = rows[i - 1], b = rows[i];
    const dOff = b.offsetBps - a.offsetBps, dVol = b.volUsd - a.volUsd;
    if (dOff <= 0) continue;
    density.push([(a.offsetBps + b.offsetBps) / 2, dVol / dOff]);
  }
  return { knots: knots.map((k) => (k * disp) / 100 / 100), rows, density }; // knots in bps too, for marker overlay
}

// Curve stableswap (real A=1000, matches compute_shapes.ts) for a shape reference overlay.
function curveY(x: number, D: number, A: number) { const Ann = A * 4; const c = (D * D * D) / (4 * x * Ann); const b = x + D / Ann; const bd = b - D; return (-bd + Math.sqrt(bd * bd + 4 * c)) / 2; }
function curveOffsetBps(volUsd: number, A = 1000) {
  const D = 2 * L;
  if (volUsd >= 0) { const y1 = curveY(L + volUsd, D, A); const dy = L - y1; return dy > 0 ? (1 - dy / volUsd) * 1e4 : null; }
  const x1 = L + volUsd; if (x1 <= 0) return null; // selling: x=L+vol (vol<0), y solves for received
  const y1 = curveY(x1, D, A); const dy = y1 - L; const recv = -volUsd; return recv > 0 ? -(1 - dy / recv) * 1e4 : null;
}

const DISPS = [1000, 2000, 3000];
const out: any = { L, profiles: {} };
for (const disp of DISPS) {
  out.profiles[`default_${disp}`] = { ...sampleProfile(DEFAULT_K, DEFAULT_W, disp), weights: DEFAULT_W, knotsRaw: DEFAULT_K };
  out.profiles[`conc_${disp}`] = { ...sampleProfile(CONC_K, CONC_W, disp), weights: CONC_W, knotsRaw: CONC_K };
}
// curve reference (disp-independent) — sampled WIDER than the spline's ±$5M (Curve is deep: needs far
// more volume to reach the same offset), so its density doesn't spuriously "wall" at the sample edge.
const CURVE_MAX = 9_800_000;
const curveRows: { volUsd: number; offsetBps: number | null }[] = [];
for (let i = 0; i <= 2000; i++) { const volUsd = -CURVE_MAX + (i / 2000) * 2 * CURVE_MAX; curveRows.push({ volUsd, offsetBps: curveOffsetBps(volUsd) }); }
out.curveA1000 = curveRows;
const curveDensity: [number, number][] = [];
for (let i = 1; i < curveRows.length; i++) {
  const a = curveRows[i - 1], b = curveRows[i];
  if (a.offsetBps == null || b.offsetBps == null) continue;
  const dOff = b.offsetBps - a.offsetBps, dVol = b.volUsd - a.volUsd;
  if (dOff <= 0) continue;
  curveDensity.push([(a.offsetBps + b.offsetBps) / 2, dVol / dOff]);
}
out.curveA1000Density = curveDensity;

await Bun.write('out/spline_shape.json', JSON.stringify(out));

// sanity print: within ±1bp / ±2bp $ capacity, default vs concentrated, at disp=1000
function within(rows: { volUsd: number; offsetBps: number }[], bpTarget: number) {
  let lo = 0; for (const r of rows) if (Math.abs(r.offsetBps) <= bpTarget) lo = Math.abs(r.volUsd);
  return lo;
}
for (const disp of DISPS) {
  const d = out.profiles[`default_${disp}`].rows, c = out.profiles[`conc_${disp}`].rows;
  console.log(`disp=${disp}: within±1bp default=$${(within(d, 1) / 1e6).toFixed(2)}M conc=$${(within(c, 1) / 1e6).toFixed(2)}M  |  within±0.5bp default=$${(within(d, 0.5) / 1e6).toFixed(2)}M conc=$${(within(c, 0.5) / 1e6).toFixed(2)}M`);
}
console.log('wrote out/spline_shape.json');
