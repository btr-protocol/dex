// sa_nhalf4.ts — SA on raw half-knot increments, nHalf=4 (8 segments total, fewer free params than
// the 16-segment sa_free_knots.ts attempt). Combined objective = maxWigglePct/2 + hwhmBp*3 to avoid
// the flat-plateau degenerate optimum a pure-wiggle objective finds. Imports scorer as-is.
import { scoreProfile, isValidProfile, DEFAULT_WITHIN_1BP, type Score } from "./spline_search_lib";

const NHALF = 4; // 4 increments/half -> 8 segments total
const WEIGHTS = Array(8).fill(25); // equal weights, sum=200
const MIN_WITHIN1BP = 1.15 * DEFAULT_WITHIN_1BP;
const ITERS_PER_RESTART = 12000; // >= 8000 required
const RESTARTS = 6; // >= 4 required
const DEGEN_GAP_PCT = 0.05; // % of 100-unit span; task's post-hoc discard threshold
// SA must not be allowed to ride the exact edge of DEGEN_GAP_PCT (empirically it will: a first pass
// with only the 0.05 filter converged on minGap=0.050004%, hwhmBp=4e-6, peakDensity=2.6e10 — the same
// numerical-spike exploit at a hair above the post-hoc line). Enforce a 10x safety margin *during* the
// search itself so found solutions are genuinely non-degenerate, not boundary-riding.
const SAFE_MIN_GAP_PCT = 0.5;

function knotsFromIncrements(deltas: number[]): number[] {
  const cum: number[] = [];
  let s = 0;
  for (const d of deltas) { s += d; cum.push(s); }
  const scale = 50 / s;
  const half = cum.map(v => v * scale); // NHALF positive knot values, half[NHALF-1] = 50 exactly
  const posSide = [0, ...half]; // length NHALF+1: 0..50
  const negSide = posSide.slice(1).map(v => -v).reverse(); // length NHALF: -50..-eps (excludes 0)
  return [...negSide, ...posSide]; // length 2*NHALF+1 knots -> 2*NHALF segments
}

function minKnotGapPct(knots: number[]): number {
  let min = Infinity;
  for (let i = 1; i < knots.length; i++) min = Math.min(min, knots[i] - knots[i - 1]);
  return (min / 100) * 100; // % of the 100-unit span
}

function scoreDeltas(deltas: number[]): { knots: number[]; score: Score } {
  const knots = knotsFromIncrements(deltas);
  const score = scoreProfile(knots, WEIGHTS, 1000, 2000);
  return { knots, score };
}

function feasible(score: Score, gapPct: number): boolean {
  return score.valid && score.curveMonotone && score.within1bp >= MIN_WITHIN1BP && gapPct >= SAFE_MIN_GAP_PCT;
}

// combined objective: minimize maxWigglePct/2 + hwhmBp*3, heavily penalize infeasibility so SA can
// still gradient down toward the feasible region rather than being blind-random outside it.
function combinedRaw(score: Score): number {
  return score.maxWigglePct / 2 + score.hwhmBp * 3;
}
function objective(score: Score, gapPct: number): number {
  if (!score.valid) return 1e9;
  let pen = 0;
  if (!score.curveMonotone) pen += 1e6;
  if (score.within1bp < MIN_WITHIN1BP) pen += (MIN_WITHIN1BP - score.within1bp) / 1000;
  if (gapPct < SAFE_MIN_GAP_PCT) pen += (SAFE_MIN_GAP_PCT - gapPct) * 50; // steer away from the boundary-riding exploit
  return combinedRaw(score) + pen;
}

function rngSeed(seed: number) {
  let s = seed >>> 0;
  return () => { s ^= s << 13; s >>>= 0; s ^= s >> 17; s ^= s << 5; s >>>= 0; return s / 4294967296; };
}

const T0 = 5.0, T1 = 0.001;

function runChain(seed: number, initRatio: number) {
  const rand = rngSeed(seed);
  // geometric-ish start: deltas[0] (innermost segment, adjacent to center) smallest,
  // deltas[NHALF-1] (outermost segment, adjacent to +/-50 edge) largest.
  let cur = Array.from({ length: NHALF }, (_, i) => Math.pow(initRatio, i));
  let curEval = scoreDeltas(cur);
  let curGap = minKnotGapPct(curEval.knots);
  let curObj = objective(curEval.score, curGap);

  let chainBest: { knots: number[]; score: Score; combined: number } | null = null;
  if (feasible(curEval.score, curGap)) {
    chainBest = { knots: curEval.knots, score: curEval.score, combined: combinedRaw(curEval.score) };
  }
  let chainBestIter = chainBest ? 0 : -1;

  for (let it = 0; it < ITERS_PER_RESTART; it++) {
    const frac = it / ITERS_PER_RESTART;
    const T = T0 * Math.pow(T1 / T0, frac);

    const cand = cur.slice();
    const nPerturb = rand() < 0.7 ? 1 : 2;
    for (let k = 0; k < nPerturb; k++) {
      const idx = Math.floor(rand() * NHALF);
      const factor = Math.exp((rand() - 0.5) * 0.6);
      cand[idx] = Math.max(1e-6, cand[idx] * factor);
    }

    const candEval = scoreDeltas(cand);
    const candGap = minKnotGapPct(candEval.knots);
    const candObj = objective(candEval.score, candGap);

    const delta = candObj - curObj;
    if (delta < 0 || rand() < Math.exp(-delta / T)) {
      cur = cand;
      curEval = candEval;
      curGap = candGap;
      curObj = candObj;
    }

    if (feasible(candEval.score, candGap)) {
      const c = combinedRaw(candEval.score);
      if (!chainBest || c < chainBest.combined) {
        chainBest = { knots: candEval.knots, score: candEval.score, combined: c };
        chainBestIter = it;
      }
    }
  }
  return { chainBest, chainBestIter };
}

let globalBest: { knots: number[]; score: Score; combined: number } | null = null;
let globalBestTotalIter = -1;
let globalBestRestart = -1;

const initRatios = [1.6, 1.3, 2.0, 1.45, 1.8, 1.2];
for (let r = 0; r < RESTARTS; r++) {
  const { chainBest, chainBestIter } = runChain(1000 + r * 777, initRatios[r % initRatios.length]);
  if (chainBest && (!globalBest || chainBest.combined < globalBest.combined)) {
    globalBest = chainBest;
    globalBestTotalIter = r * ITERS_PER_RESTART + chainBestIter;
    globalBestRestart = r;
  }
}

if (globalBest) {
  const gapPct = minKnotGapPct(globalBest.knots);
  const degenerate = gapPct < DEGEN_GAP_PCT;
  console.log(JSON.stringify({
    found: degenerate ? "best_was_degenerate_no_replacement_logic_hit" : "feasible_nondegenerate",
    knots: globalBest.knots.map(v => Math.round(v * 1e8) / 1e8),
    weights: WEIGHTS,
    score: globalBest.score,
    minKnotGapPct: gapPct,
    degenerate,
    bestFoundAtIter: globalBestTotalIter,
    bestFoundAtRestart: globalBestRestart,
    itersPerRestart: ITERS_PER_RESTART,
    restarts: RESTARTS,
    totalItersRun: ITERS_PER_RESTART * RESTARTS,
  }, null, 2));
} else {
  console.log(JSON.stringify({ found: "none_feasible", totalItersRun: ITERS_PER_RESTART * RESTARTS }, null, 2));
}
