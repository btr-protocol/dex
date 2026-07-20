// spline_shared_grid.ts — SHARED knot grid per wall W + 9 regime weight presets.
// Formula: clamped quartic I-spline. Walls W∈{0.5,1,2,5} (W=40 CUT: gate-failing hyper/platy,
// Pareto-dominated by W=5, ncp=44 breaks the 15-segment packed layout).
// ONE uniform gate set (seamJ≤0.18, no exceptions). Every (regime,W) preset carries portable:true|false
// — the deployability whitelist; gate-failing fits are still emitted (explorer contrast) but NEVER
// exported to parity vectors and warn loudly.
import {
  BPS, DEGREE as P, SEAM_J_MAX_EXPORT as SEAM_J_MAX, LAMBDAS_EXPORT as LAMBDAS,
  densityTarget, fit, wallShape, densErrPct, clampGap, powEval, powDeriv, volAtX,
  phi, Phi, type Target, type Fit,
} from './spline_bspline.ts';
import { curveOffsetBps, CURVE_BENCHMARKS, densityAtUniformOffsets } from './spline_shape.ts';

const DENS_N = 1600;
const L_SIDE = 10_000_000; // $10M/side
const MAX_SEGS = 15; // packed-layout hard cap (2-slot segs); segments = ncp - 4

/** Honest Curve comparison basis: REAL N=3 3pool (DAI/USDC/USDT) at A=4000, $10M/side (D=3L),
 * MARGINAL (spot) density at the peg — the same basis the spline's own density uses (the spline
 * offset curve is a marginal quote). ≈$18.0M/bp. The earlier $8.0M/bp figure was an N=2
 * average-execution density — wrong pool dimension AND wrong basis; retired. */
function curve3MarginalPeak(A: number): number {
  const D = 3 * L_SIDE, h = 500;
  const getY3 = (x1: number, x2: number) => {
    const Ann = A * 27, c = D ** 4 / (27 * x1 * x2 * Ann), b = x1 + x2 + D / Ann, bd = b - D;
    return (-bd + Math.sqrt(bd * bd + 4 * c)) / 2;
  };
  const spotOff = (v: number) => {
    const yA = getY3(L_SIDE + v - h, L_SIDE), yB = getY3(L_SIDE + v + h, L_SIDE);
    return (1 / (-(yB - yA) / (2 * h)) - 1) * 1e4; // spot price offset, bps
  };
  return 1 / ((spotOff(2000) - spotOff(-2000)) / 4000); // $/bp
}
const CURVE3_A4000_PEAK = curve3MarginalPeak(4000);
const HYPER_PEAK_MIN = 80_000_000; // absolute floor $80M/bp (hyper tip target, W≤1)
const HYPER_WITHIN05_FRAC = 0.85; // ≥ 0.85 L within ±0.5bp

/** Canonical 9 (port + explorer core). */
const REGIME_NAMES = [
  'hyper', 'flat', 'plateau', 'meso', 'lepto', 'platy', 'skew_L', 'skew_R', 'pin_M',
] as const;
type Regime = (typeof REGIME_NAMES)[number];

/** pin_M explorer variants (not required for port pack). */
const PIN_VARIANTS = ['pin_M_tight', 'pin_M_med', 'pin_M_wide'] as const;

const WALLS = [0.5, 1, 2, 5] as const;

/** Coarsest-first h ladders per wall (bp). */
const H_BY_WALL: Record<number, number[]> = {
  0.5: [0.12, 0.1, 0.08, 0.06, 0.05, 0.04],
  1: [0.25, 0.2, 0.15, 0.12, 0.1, 0.08, 0.06, 0.05, 0.04],
  2: [0.5, 0.4, 0.3, 0.25, 0.2, 0.15],
  5: [2.5, 2, 1.5, 1.25, 1, 0.75, 0.5],
};

function sharedInterior(W: number, hBp: number): number[] {
  const m = Math.max(0, Math.floor((W - hBp / 2) / hBp));
  const offs: number[] = [];
  for (let k = -m; k <= m; k++) offs.push(k * hBp);
  // Near-wall seam helpers scale with W (avoid sub-gap collapse on tiny walls).
  const nearA = Math.min(W * 0.1, hBp * 2.5), nearB = Math.min(W * 0.25, hBp * 5);
  offs.push(-W + nearA, -W + nearB, W - nearB, W - nearA);
  offs.sort((x, y) => x - y);
  const uniq: number[] = [];
  for (const o of offs) if (!uniq.length || Math.abs(o - uniq[uniq.length - 1]) > 1e-12) uniq.push(o);
  return clampGap(uniq.map((o) => (BPS * (o / W + 1)) / 2));
}

/** Tip-biased interiors for hyper walls (W≤1). Coarsest-first. The 11/13/14-interior tight-tip
 * variants are the chair-mandated W=1 refit attempt against the UNIFORM seamJ≤0.18 gate (the old
 * seamJ≤1.05 hyper@W1 exception is deleted); 14 interior = 15 segments = the packed-layout cap. */
const TIP_GRIDS_W1: number[][] = [
  [-0.85, -0.5, -0.25, -0.1, 0, 0.1, 0.25, 0.5, 0.85],
  [-0.9, -0.55, -0.3, -0.12, 0, 0.12, 0.3, 0.55, 0.9],
  [-0.88, -0.6, -0.35, -0.18, -0.06, 0, 0.06, 0.18, 0.35, 0.6, 0.88],
  [-0.8, -0.5, -0.3, -0.16, -0.07, 0, 0.07, 0.16, 0.3, 0.5, 0.8],
  [-0.92, -0.7, -0.45, -0.25, -0.12, -0.04, 0, 0.04, 0.12, 0.25, 0.45, 0.7, 0.92],
  [-0.85, -0.55, -0.35, -0.2, -0.1, -0.04, 0, 0.04, 0.1, 0.2, 0.35, 0.55, 0.85],
  [-0.9, -0.6, -0.38, -0.23, -0.13, -0.06, 0, 0.06, 0.13, 0.23, 0.38, 0.6, 0.9],
  [-0.9, -0.62, -0.42, -0.28, -0.18, -0.11, -0.05, 0.05, 0.11, 0.18, 0.28, 0.42, 0.62, 0.9],
];
const TIP_GRIDS_W05: number[][] = [
  [-0.42, -0.28, -0.14, -0.05, 0, 0.05, 0.14, 0.28, 0.42],
  [-0.45, -0.3, -0.15, -0.06, 0, 0.06, 0.15, 0.3, 0.45],
  [-0.4, -0.22, -0.1, 0, 0.1, 0.22, 0.4],
];

function tipInterior(W: number, offs: number[]): number[] {
  const uniq: number[] = [];
  for (const o of [...offs].sort((a, b) => a - b)) {
    if (Math.abs(o) >= W - 1e-12) continue;
    if (!uniq.length || Math.abs(o - uniq[uniq.length - 1]) > 1e-12) uniq.push(o);
  }
  return clampGap(uniq.map((o) => (BPS * (o / W + 1)) / 2));
}

/** Density metrics on emitted series ($/bp, capital within ±bp). */
function densMetrics(f: Fit) {
  const dens = densityAtUniformOffsets(
    (x) => powEval(f.segs, x), (x) => powDeriv(f.segs, x), DENS_N,
    powEval(f.segs, 0) / 100, powEval(f.segs, BPS) / 100,
  );
  let peak = 0, within05 = 0, within1 = 0, cap = 0;
  for (let i = 0; i < dens.length; i++) {
    const [o, d] = dens[i];
    if (d > peak) peak = d;
    const prev = i ? dens[i - 1] : dens[i];
    const dx = Math.abs(o - prev[0]);
    const mid = (d + prev[1]) / 2;
    if (i) {
      cap += mid * dx;
      if (Math.abs(o) <= 0.5 && Math.abs(prev[0]) <= 0.5) within05 += mid * dx;
      else if (Math.abs(o) <= 0.5 || Math.abs(prev[0]) <= 0.5) {
        // partial edge bin
        const lo = Math.max(-0.5, Math.min(o, prev[0]));
        const hi = Math.min(0.5, Math.max(o, prev[0]));
        if (hi > lo) within05 += mid * (hi - lo);
      }
      if (Math.abs(o) <= 1 && Math.abs(prev[0]) <= 1) within1 += mid * dx;
      else if (Math.abs(o) <= 1 || Math.abs(prev[0]) <= 1) {
        const lo = Math.max(-1, Math.min(o, prev[0]));
        const hi = Math.min(1, Math.max(o, prev[0]));
        if (hi > lo) within1 += mid * (hi - lo);
      }
    }
  }
  // Mid-trough depth for M shapes: min near 0 vs max peak.
  let midMin = Infinity;
  for (const [o, d] of dens) if (Math.abs(o) < 0.08 * Math.max(1, Math.abs(dens[0][0]))) midMin = Math.min(midMin, d);
  if (!isFinite(midMin)) midMin = dens[Math.floor(dens.length / 2)][1];
  const troughDepth = peak > 0 ? 1 - midMin / peak : 0;
  return {
    peak, within05, within1, capital: cap,
    troughDepth,
    peakOverCurve: peak / CURVE3_A4000_PEAK,
    within05Frac: within05 / L_SIDE,
  };
}

function pinDensity(W: number, pkFrac: number, sigFrac: number, midFloor: number) {
  const pk = W * pkFrac, sig = Math.max(W * sigFrac, 0.02);
  return (o: number) =>
    Math.exp(-((o + pk) ** 2) / (2 * sig * sig))
    + Math.exp(-((o - pk) ** 2) / (2 * sig * sig))
    + midFloor;
}

/** 9 canonical regimes + optional pin variants at wall W. */
function regimesAtWall(W: number, includePinVariants = false): Record<string, Target> {
  const flat = densityTarget('flat', -W, W, (o) => {
    const a = W * 0.7, c = W, ao = Math.abs(o);
    return ao <= a ? 1 : ao >= c ? 0 : Math.sqrt(Math.max(0, 1 - ((ao - a) / (c - a)) ** 2));
  }, true);
  flat.plateau = true;

  const plateau = densityTarget('plateau', -W, W, (o) => {
    const a = W * 0.55, c = W, ao = Math.abs(o);
    return ao <= a ? 1 : ao >= c ? 0 : Math.sqrt(Math.max(0, 1 - ((ao - a) / (c - a)) ** 2));
  }, true);
  plateau.plateau = true;

  // hyper: Laplace (+ soft super-Gaussian on W≤0.5). W=1 s=0.05; W=0.5 s=0.06 (empirically
  // clears the $80M/bp floor at seamJ≪0.18 on h≈0.12). Wider walls: mild tip, relative gate only.
  const sHyp = W <= 0.5 ? 0.06 : W <= 1 ? 0.05 : W * 0.1;
  const hyper = densityTarget('hyper', -W, W,
    (o) => {
      const lap = Math.exp(-Math.abs(o) / sHyp);
      return W <= 0.5 ? lap * Math.exp(-((Math.abs(o) / (sHyp * 2.2)) ** 4)) : lap;
    }, true);

  const meso = densityTarget('meso', -W, W, (o) => Math.exp(-(o * o) / (2 * (W * 0.28) ** 2)), true);

  const sFat = W * 0.22, nu = 1.5;
  const lepto = densityTarget('lepto', -W, W, (o) => (1 + (o / sFat) ** 2 / nu) ** (-(nu + 1) / 2), true);

  const platy = densityTarget('platy', -W, W, (o) => Math.exp(-((Math.abs(o) / (W * 0.55)) ** 4)), true);

  const sigS = W * 0.32;
  const skew_L = densityTarget('skew_L', -W, W, (o) => { const z = o / sigS; return phi(z) * Phi(-1.1 * z); }, true);
  const skew_R = densityTarget('skew_R', -W, W, (o) => { const z = o / sigS; return phi(z) * Phi(1.1 * z); }, true);

  // pin_M: sharp twin peaks, deep mid (floor small → trough ≥80%).
  const pin_M = densityTarget('pin_M', -W, W, pinDensity(W, 0.42, 0.07, 0.02), false, 2);

  const out: Record<string, Target> = {
    hyper, flat, plateau, meso, lepto, platy, skew_L, skew_R, pin_M,
  };

  if (includePinVariants) {
    out.pin_M_tight = densityTarget('pin_M_tight', -W, W, pinDensity(W, 0.28, 0.055, 0.015), false, 2);
    out.pin_M_med = densityTarget('pin_M_med', -W, W, pinDensity(W, 0.42, 0.07, 0.02), false, 2);
    out.pin_M_wide = densityTarget('pin_M_wide', -W, W, pinDensity(W, 0.58, 0.08, 0.025), false, 2);
  }
  return out;
}

function regimeGates(tg: Target, f: Fit, metrics: ReturnType<typeof densMetrics>): { ok: boolean; why: string } {
  const nExp = tg.expectedModes ?? 1;
  const s = wallShape(tg, f.segs);
  const W = Math.max(Math.abs(tg.edgeLo), Math.abs(tg.edgeHi));
  const platMax = (tg.edgeHi - tg.edgeLo) <= 12 ? 4 : 3;
  const isSkew = tg.name === 'skew_L' || tg.name === 'skew_R';
  const isHyper = tg.name === 'hyper';
  const isPin = tg.name.startsWith('pin_M');
  const coreMax = isSkew ? 2000 : isHyper ? 2500 : 800;

  // ONE uniform seam gate — the old hyper@W≤1 seamJ≤1.05 exception is DELETED (chair verdict).
  if (f.seamJ > SEAM_J_MAX) return { ok: false, why: `seamJ=${f.seamJ.toFixed(3)}` };
  if (f.coreErrPbps > coreMax) return { ok: false, why: `coreErr=${f.coreErrPbps.toFixed(1)}` };
  if (!isHyper && s.extraInfl > 3) return { ok: false, why: `xInfl=${s.extraInfl}` };
  if (s.spuriousLobeMaxPct >= (isHyper ? 15 : 8)) return { ok: false, why: `spur=${s.spuriousLobeMaxPct.toFixed(1)}` };
  if (!isHyper && !s.tailMonotone) return { ok: false, why: 'tail' };
  if (tg.plateau && s.plateauRipplePct > platMax) return { ok: false, why: `plat=${s.plateauRipplePct.toFixed(1)}` };
  if (isHyper) {
    if (s.modes > 1) return { ok: false, why: `modes=${s.modes}>1` };
  } else if (s.modes !== nExp) {
    return { ok: false, why: `modes=${s.modes}≠${nExp}` };
  }

  if (isPin && metrics.troughDepth < 0.80) {
    return { ok: false, why: `trough=${(metrics.troughDepth * 100).toFixed(0)}%<80` };
  }
  if (isHyper) {
    if (W <= 1) {
      if (metrics.peak < HYPER_PEAK_MIN) {
        return { ok: false, why: `peak=${(metrics.peak / 1e6).toFixed(1)}M<${(HYPER_PEAK_MIN / 1e6).toFixed(0)}M` };
      }
      if (metrics.within05Frac < HYPER_WITHIN05_FRAC) {
        return { ok: false, why: `w05=${(metrics.within05Frac * 100).toFixed(0)}%<85` };
      }
    } else if (metrics.within05Frac < 0.55) {
      return { ok: false, why: `tip=${(metrics.within05Frac * 100).toFixed(0)}%<55` };
    }
  }
  return { ok: true, why: 'ok' };
}

function bestFitOnGrid(tg: Target, interior: number[]): {
  f: Fit; lam: number; ok: boolean; why: string; metrics: ReturnType<typeof densMetrics>;
} {
  const base = [...LAMBDAS];
  const lams = tg.name === 'hyper'
    ? [...new Set([1, 1.5, 2, 2.5, 3, 4, ...base])].sort((a, b) => a - b)
    : base;
  let best: Fit | null = null, bestLam = lams[0], bestWhy = '', bestMet: ReturnType<typeof densMetrics> | null = null;
  let bestScore = -Infinity;
  for (const lam of lams) {
    const f = fit(tg, interior, lam);
    const metrics = densMetrics(f);
    const g = regimeGates(tg, f, metrics);
    if (g.ok) return { f, lam, ok: true, why: 'ok', metrics };
    const score = tg.name === 'hyper'
      ? metrics.peakOverCurve * metrics.within05Frac - 0.1 * f.seamJ
      : -f.seamJ;
    if (!best || score > bestScore) {
      best = f; bestLam = lam; bestWhy = g.why; bestMet = metrics; bestScore = score;
    }
  }
  return { f: best!, lam: bestLam, ok: false, why: bestWhy, metrics: bestMet! };
}

function seriesOf(f: Fit) {
  return {
    rows: Array.from({ length: 501 }, (_, k) => {
      const x = (k / 500) * BPS;
      return [Math.round(volAtX(x)), +(powEval(f.segs, x) / 100).toFixed(4)];
    }),
    density: densityAtUniformOffsets(
      (x) => powEval(f.segs, x), (x) => powDeriv(f.segs, x), DENS_N,
      powEval(f.segs, 0) / 100, powEval(f.segs, BPS) / 100,
    ).map(([o, dv]) => [+o.toFixed(4), +dv.toFixed(1)]),
    knotsBps: f.T.slice(P + 1, f.T.length - P - 1).map((t) => +(volAtX(t) / 1e6).toFixed(3)),
  };
}

function packPreset(name: string, tg: Target, f: Fit, lam: number, ok: boolean, why: string,
  metrics: ReturnType<typeof densMetrics>, W: number) {
  const s = wallShape(tg, f.segs);
  const segments = f.ncp - 4; // clamped quartic: segments = nInt+1 = ncp-4
  // portable = the deployability whitelist: ALL gates pass AND fits the 15-seg packed layout.
  const portable = ok && segments <= MAX_SEGS;
  if (ok && !portable) console.warn(`⚠ ${name}@W${W}: gates pass but ${segments} segs > ${MAX_SEGS} cap ⇒ portable:false`);
  return {
    ok, why, portable, ncp: f.ncp, segments,
    lambda: lam, seamJ: f.seamJ, coreErrPbps: f.coreErrPbps,
    densErrPct: densErrPct(tg, f.segs),
    w: f.w.map((v) => +v.toFixed(4)),
    deltaW: f.e.map((v) => +v.toFixed(6)),
    series: seriesOf(f),
    edgeBp: W, edgeLoBp: -W, edgeHiBp: W,
    metrics: {
      peakUsdPerBp: +metrics.peak.toFixed(1),
      peakOverCurve: +metrics.peakOverCurve.toFixed(3),
      within05Usd: +metrics.within05.toFixed(1),
      within05Frac: +metrics.within05Frac.toFixed(4),
      within1Usd: +metrics.within1.toFixed(1),
      troughDepth: +metrics.troughDepth.toFixed(4),
      capitalUsd: +metrics.capital.toFixed(1),
    },
    shape: {
      modes: s.modes, spuriousLobeMaxPct: +s.spuriousLobeMaxPct.toFixed(3),
      tailMonotone: s.tailMonotone, plateauRipplePct: +s.plateauRipplePct.toFixed(3),
      peakAbsOffBp: s.peakAbsOff.map((o) => +o.toFixed(2)),
      troughDepth: +metrics.troughDepth.toFixed(4),
    },
  };
}

function curveCheck(interior: number[], A: number, name: string) {
  const off = (x: number) => (curveOffsetBps(volAtX(x), A) ?? 0) * 100;
  const e = Math.abs(off(BPS)) / 100;
  const tg: Target = { name, offAtX: off, edgeLo: -e, edgeHi: e, unimodal: true };
  let best: Fit | null = null, bestLam = 1;
  for (const lam of LAMBDAS) {
    const f = fit(tg, interior, lam);
    if (!best || f.maxErrPbps < best.maxErrPbps) { best = f; bestLam = lam; }
  }
  return {
    name, A, ncp: best!.ncp, lambda: bestLam,
    maxErrPbps: +best!.maxErrPbps.toFixed(4), seamJ: +best!.seamJ.toFixed(4),
    hitTol05: best!.maxErrPbps <= 0.5,
  };
}

/** Names that must clear for this wall (hyper only required on tiny walls; all 9 on W∈{2,5}). */
function requiredNames(W: number): string[] {
  if (W === 0.5 || W === 1) return ['hyper'];
  return [...REGIME_NAMES];
}

async function runWall(W: number) {
  const wantPins = W === 5;
  const regimes = regimesAtWall(W, wantPins);
  const required = requiredNames(W);
  const fitNames = wantPins
    ? [...REGIME_NAMES, ...PIN_VARIANTS]
    : [...REGIME_NAMES];

  // W≤1: tip-biased grids (hyper-first). Wider walls: uniform-offset h sweep.
  type Cand = { label: string; interior: number[]; hBp: number };
  const cands: Cand[] = [];
  if (W === 0.5) {
    for (const offs of TIP_GRIDS_W05) {
      const interior = tipInterior(W, offs);
      cands.push({ label: `tip${interior.length}`, interior, hBp: +(2 * W / Math.max(1, interior.length - 1)).toFixed(4) });
    }
    for (const hBp of H_BY_WALL[0.5]) cands.push({ label: `h${hBp}`, interior: sharedInterior(W, hBp), hBp });
  } else if (W === 1) {
    for (const offs of TIP_GRIDS_W1) {
      const interior = tipInterior(W, offs);
      cands.push({ label: `tip${interior.length}`, interior, hBp: +(2 * W / Math.max(1, interior.length - 1)).toFixed(4) });
    }
    for (const hBp of H_BY_WALL[1]) cands.push({ label: `h${hBp}`, interior: sharedInterior(W, hBp), hBp });
  } else {
    for (const hBp of H_BY_WALL[W]) {
      cands.push({ label: `h${hBp}`, interior: sharedInterior(W, hBp), hBp });
    }
  }

  let chosen: {
    hBp: number; interior: number[]; ncp: number; knots: number;
    presets: Record<string, any>;
  } | null = null;
  const sweep: any[] = [];
  let fallback: { cand: Cand; presets: Record<string, any>; okCount: number } | null = null;

  for (const cand of cands) {
    const { interior, hBp, label } = cand;
    const ncp = interior.length + P + 1;
    const row: any = { hBp, label, nInt: interior.length, ncp, regimes: {} };
    let reqOk = true;
    const presets: Record<string, any> = {};
    // On hyper walls only fit required (+ all 9 for reporting when cheap).
    const names = (W <= 1) ? required : fitNames;
    for (const name of names) {
      const { f, lam, ok, why, metrics } = bestFitOnGrid(regimes[name], interior);
      row.regimes[name] = {
        ok, why, lambda: lam, seamJ: +f.seamJ.toFixed(4), coreErrPbps: +f.coreErrPbps.toFixed(2),
        densErrPct: +densErrPct(regimes[name], f.segs).toFixed(1),
        modes: wallShape(regimes[name], f.segs).modes,
        peakM: +(metrics.peak / 1e6).toFixed(2),
        peakXCurve: +metrics.peakOverCurve.toFixed(2),
        w05pct: +(metrics.within05Frac * 100).toFixed(1),
        trough: +(metrics.troughDepth * 100).toFixed(0),
      };
      if (required.includes(name) && !ok) reqOk = false;
      presets[name] = packPreset(name, regimes[name], f, lam, ok, why, metrics, W);
    }
    // On hyper walls, also fit remaining regimes for explorer contrast (same T).
    if (W <= 1) {
      for (const name of REGIME_NAMES) {
        if (presets[name]) continue;
        const { f, lam, ok, why, metrics } = bestFitOnGrid(regimes[name], interior);
        presets[name] = packPreset(name, regimes[name], f, lam, ok, why, metrics, W);
        row.regimes[name] = {
          ok, why, lambda: lam, seamJ: +f.seamJ.toFixed(4),
          peakM: +(metrics.peak / 1e6).toFixed(2), peakXCurve: +metrics.peakOverCurve.toFixed(2),
        };
      }
    }
    sweep.push(row);
    const okCount = REGIME_NAMES.filter((n) => row.regimes[n]?.ok).length;
    const flag = required.map((n) => `${n}:${row.regimes[n]?.ok ? 'Y' : 'N'}(${row.regimes[n]?.why})`).join(' ');
    console.log(`W=${W} ${label} ncp=${ncp} reqOk=${reqOk} ok9=${okCount} ${flag}`);
    if (!fallback || okCount > fallback.okCount) fallback = { cand, presets, okCount };
    if (reqOk && !chosen) {
      for (const name of fitNames) {
        if (!presets[name]) {
          const { f, lam, ok, why, metrics } = bestFitOnGrid(regimes[name], interior);
          presets[name] = packPreset(name, regimes[name], f, lam, ok, why, metrics, W);
        }
      }
      if (required.every((n) => presets[n].ok)) {
        chosen = { hBp, interior, ncp, knots: interior.length, presets };
        break;
      }
    }
  }

  if (!chosen) {
    // NO silent pass-through (chair fix): required regime(s) failed on EVERY candidate grid. Keep the
    // grid clearing the most of the 9 (so the wall still exposes its portable subset), warn loudly;
    // failed presets carry portable:false and are never exported to parity vectors.
    const { cand, presets, okCount } = fallback!;
    for (const name of fitNames) {
      if (!presets[name]) {
        const { f, lam, ok, why, metrics } = bestFitOnGrid(regimes[name], cand.interior);
        presets[name] = packPreset(name, regimes[name], f, lam, ok, why, metrics, W);
      }
    }
    const failed = required.filter((n) => !presets[n].ok);
    console.warn(`⚠ W=${W}: required regime(s) FAILED on every candidate grid: `
      + `${failed.map((n) => `${n}(${presets[n].why})`).join(' ')} — keeping best grid ${cand.label} `
      + `(${okCount}/9 clear); failing presets exported portable:false, NOT deployable.`);
    chosen = {
      hBp: cand.hBp, interior: cand.interior,
      ncp: cand.interior.length + P + 1, knots: cand.interior.length, presets,
    };
  }

  // Packed-layout hard cap: every portable fit MUST fit MAX_SEGS segments.
  for (const [n, p] of Object.entries(chosen.presets) as [string, any][]) {
    if (p.portable && p.segments > MAX_SEGS) throw new Error(`W=${W} ${n}: portable but ${p.segments} segs > ${MAX_SEGS}`);
  }

  const curveChecks = [256, 1500, 4000].map((A) =>
    curveCheck(chosen!.interior, CURVE_BENCHMARKS[`A${A}` as keyof typeof CURVE_BENCHMARKS] ?? A, `curve_A${A}`));

  const allRequiredClear = required.every((n) => chosen!.presets[n].ok);
  const allNineClear = REGIME_NAMES.every((n) => chosen!.presets[n]?.ok);
  const portableRegimes = [...REGIME_NAMES, ...(wantPins ? PIN_VARIANTS : [])]
    .filter((n) => chosen!.presets[n]?.portable);
  return {
    W, degree: P, seamJMax: SEAM_J_MAX, maxSegs: MAX_SEGS,
    required, hyperPeakMin: HYPER_PEAK_MIN, hyperWithin05Frac: HYPER_WITHIN05_FRAC,
    shared: {
      hBp: chosen.hBp, ncp: chosen.ncp, knots: chosen.knots,
      interiorX: chosen.interior.map((x) => +x.toFixed(4)),
      allRequiredClear, allNineClear,
      portableRegimes,
    },
    presets: chosen.presets,
    curveChecks,
    sweep,
  };
}

const out: any = {
  formula: 'clamped quartic I-spline (non-negative cubic density)',
  objectives: [
    'monotone Δw≥0', 'seamJ≤0.18 C2 density (uniform, no exceptions)', 'hard ±W walls',
    'minimal shared knots per W', '≤15 packed segments (portable cap)', 'gas≤FC+2k',
    '9 shape primitives (mode count + smoothness, NOT pointwise density fidelity)',
    'hyper peak ≥$80M/bp + within±0.5 ≥0.85L @W≤1', 'pin_M trough ≥80%',
  ],
  regimes: [...REGIME_NAMES],
  pinVariants: [...PIN_VARIANTS],
  wallLadder: [...WALLS],
  hyper: {
    curve3A4000MarginalPeakUsdPerBp: +CURVE3_A4000_PEAK.toFixed(0),
    curveBasis: 'N=3 3pool A=4000, $10M/side, MARGINAL (spot) density at peg',
    peakMinUsdPerBp: HYPER_PEAK_MIN, within05Frac: HYPER_WITHIN05_FRAC,
  },
  walls: {},
};

for (const W of WALLS) {
  console.log(`\n=== shared-grid search W=±${W}bp ===`);
  out.walls[`W${String(W).replace('.', '_')}`] = await runWall(W);
}

const w05 = out.walls.W0_5;
const w1 = out.walls.W1;
const w2 = out.walls.W2;
const w5 = out.walls.W5;
// Deployability whitelist: regime × W matrix of portable (gates + ≤15-seg cap) fits.
out.portableMatrix = Object.fromEntries(
  Object.entries(out.walls).map(([k, w]: [string, any]) => [k, w.shared.portableRegimes]));
out.port = {
  primaryWallBp: 5,
  ncpW5: w5.shared.ncp,
  allNineClearW5: w5.shared.allNineClear,
  allNineClearW2: w2.shared.allNineClear,
  hyperClearW05: w05.presets.hyper.portable,
  hyperClearW1: w1.presets.hyper.portable, // refit under uniform 0.18 gate — false ⇒ rung dropped
  hyperPeakW05: w05.presets.hyper.metrics?.peakOverCurve,
  hyperPeakW1: w1.presets.hyper.metrics?.peakOverCurve,
  curve3A4000MarginalPeakUsdPerBp: +CURVE3_A4000_PEAK.toFixed(0),
  solPort: w5.shared.allNineClear && w2.shared.allNineClear && w05.presets.hyper.portable,
  note: `Portable: ${Object.entries(out.portableMatrix).map(([k, v]: [string, any]) => `${k}{${v.length}}`).join(' ')}; `
    + `hyper@W1 ${w1.presets.hyper.portable ? 'refit CLEARS uniform 0.18 gate' : 'DROPPED (refit fails uniform 0.18 gate)'}`,
};

await Bun.write('out/spline_shared_grid.json', JSON.stringify(out, null, 2));
console.log('\nportableMatrix', out.portableMatrix);
console.log('port', out.port);
console.log('wrote out/spline_shared_grid.json');
