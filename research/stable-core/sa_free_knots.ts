// sa_free_knots.ts — free-form SA on raw half-knot increments (no geometric family constraint).
// Imports scorer as-is from spline_search_lib.ts — no reimplementation.
import { scoreProfile, isValidProfile, DEFAULT_WITHIN_1BP, type Score } from "./spline_search_lib";

const NHALF = 8; // 8 increments/half -> 16 segments total (on-chain max), equal weights 12.5 each
const WEIGHTS = Array(16).fill(12.5);
const MIN_WITHIN1BP = 1.3 * DEFAULT_WITHIN_1BP;
const ITERS_PER_RESTART = 20000;
const RESTARTS = 8;

function knotsFromIncrements(deltas: number[]): number[] {
  // cumulative sum, rescale so total = 50, mirror negative half, prepend 0
  const cum: number[] = [];
  let s = 0;
  for (const d of deltas) { s += d; cum.push(s); }
  const scale = 50 / s;
  const half = cum.map(v => v * scale); // 8 positive knot values summing-structured, half[7] = 50
  const negHalf = half.slice(0, -1).map(v => -v).reverse(); // 7 negative knots excluding -50 dup... build properly below
  // Full knot sequence: [-50, ..., -half[0], 0? no] -> build as mirror of [0,...,50]
  const posSide = [0, ...half]; // length 9: 0..50
  const negSide = posSide.slice(1).map(v => -v).reverse(); // length 8: -50..-eps (excludes 0)
  return [...negSide, ...posSide]; // length 17 knots -> 16 segments
}

function scoreDeltas(deltas: number[]): { knots: number[]; score: Score } {
  const knots = knotsFromIncrements(deltas);
  const score = scoreProfile(knots, WEIGHTS, 1000, 1000);
  return { knots, score };
}

function feasible(score: Score): boolean {
  return score.valid && score.curveMonotone && score.within1bp >= MIN_WITHIN1BP;
}

// penalized objective: minimize maxWigglePct, heavily penalize infeasibility so SA can still gradient
// down toward feasible region rather than being blind-random outside it.
function objective(score: Score): number {
  if (!score.valid) return 1e9;
  let pen = 0;
  if (!score.curveMonotone) pen += 1e6;
  if (score.within1bp < MIN_WITHIN1BP) pen += (MIN_WITHIN1BP - score.within1bp) / 1000; // scaled bps of $ deficit
  return score.maxWigglePct + pen;
}

function rngSeed(seed: number) {
  let s = seed >>> 0;
  return () => { s ^= s << 13; s >>>= 0; s ^= s >> 17; s ^= s << 5; s >>>= 0; return s / 4294967296; };
}

const T0 = 5.0, T1 = 0.001;

function runChain(seed: number) {
  const rand = rngSeed(seed);
  // init: geometric growth ratio 1.4, [1, 1.4, 1.4^2, ..., 1.4^7]
  let cur = Array.from({ length: NHALF }, (_, i) => Math.pow(1.4, i));
  let curEval = scoreDeltas(cur);
  let curObj = objective(curEval.score);

  let chainBestFeasible: { knots: number[]; score: Score } | null = feasible(curEval.score) ? curEval : null;
  let chainBestWiggle = chainBestFeasible ? chainBestFeasible.score.maxWigglePct : Infinity;
  let chainBestIter = chainBestFeasible ? 0 : -1;

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
    const candObj = objective(candEval.score);

    const delta = candObj - curObj;
    if (delta < 0 || rand() < Math.exp(-delta / T)) {
      cur = cand;
      curEval = candEval;
      curObj = candObj;
    }

    if (feasible(candEval.score) && candEval.score.maxWigglePct < chainBestWiggle) {
      chainBestFeasible = candEval;
      chainBestWiggle = candEval.score.maxWigglePct;
      chainBestIter = it;
    }
  }
  return { chainBestFeasible, chainBestIter };
}

let globalBest: { knots: number[]; score: Score } | null = null;
let globalBestWiggle = Infinity;
let globalBestTotalIter = -1;

for (let r = 0; r < RESTARTS; r++) {
  const { chainBestFeasible, chainBestIter } = runChain(1000 + r * 777);
  if (chainBestFeasible && chainBestFeasible.score.maxWigglePct < globalBestWiggle) {
    globalBest = chainBestFeasible;
    globalBestWiggle = chainBestFeasible.score.maxWigglePct;
    globalBestTotalIter = r * ITERS_PER_RESTART + chainBestIter;
  }
}

if (globalBest) {
  console.log(JSON.stringify({
    found: "feasible",
    knots: globalBest.knots.map(v => Math.round(v * 1e8) / 1e8),
    weights: WEIGHTS,
    score: globalBest.score,
    bestFoundAtIter: globalBestTotalIter,
    itersPerRestart: ITERS_PER_RESTART,
    restarts: RESTARTS,
    totalItersRun: ITERS_PER_RESTART * RESTARTS,
  }, null, 2));
} else {
  console.log(JSON.stringify({ found: "none_feasible", totalItersRun: ITERS_PER_RESTART * RESTARTS }, null, 2));
}
