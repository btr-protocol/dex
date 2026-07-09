// coord_descent_8seg.ts — local coordinate-descent hill-climb on the 8-segment (4/half) symmetric
// seed profile. Imports scorer as-is from spline_search_lib.ts — no reimplementation.
import { scoreProfile, DEFAULT_WITHIN_1BP, type Score } from "./spline_search_lib";

const MIN_WITHIN1BP = 1.15 * DEFAULT_WITHIN_1BP;
const MAGS = [0.01, 0.03, 0.08, 0.15, 0.25];
const STEPS = 6000; // >= 4000 required

// Symmetry-reduced free params. Full 9 knots = [-50,-k3,-k2,-k1,0,k1,k2,k3,50] (center fixed 0,
// outer fixed 50 by the span=100 validity constraint -> not perturbable w/o violating span).
// Full 8 weights = [w0,w1,w2,w3,w3,w2,w1,w0] (sum unique*2 = 200 -> renormalize unique to sum 100).
type Params = { k1: number; k2: number; k3: number; w0: number; w1: number; w2: number; w3: number };

function build(p: Params): { knots: number[]; weights: number[] } {
  const knots = [-50, -p.k3, -p.k2, -p.k1, 0, p.k1, p.k2, p.k3, 50];
  const wsum = p.w0 + p.w1 + p.w2 + p.w3;
  const scale = 100 / wsum;
  const w0 = p.w0 * scale, w1 = p.w1 * scale, w2 = p.w2 * scale, w3 = p.w3 * scale;
  const weights = [w0, w1, w2, w3, w3, w2, w1, w0];
  return { knots, weights };
}

function combined(s: Score): number {
  return s.maxWigglePct / 2 + s.hwhmBp * 3;
}

function feasible(s: Score): boolean {
  return s.valid && s.curveMonotone && s.within1bp >= MIN_WITHIN1BP;
}

function rngSeed(seed: number) {
  let s = seed >>> 0;
  return () => { s ^= s << 13; s >>>= 0; s ^= s >> 17; s ^= s << 5; s >>>= 0; return s / 4294967296; };
}
const rand = rngSeed(42);

// seed
let cur: Params = { k1: 5, k2: 15, k3: 30, w0: 15, w1: 25, w2: 30, w3: 30 };
let curBuild = build(cur);
let curScore = scoreProfile(curBuild.knots, curBuild.weights, 1000);
const seedScore = curScore;
const seedCombined = combined(seedScore);
let curCombined = feasible(curScore) ? seedCombined : Infinity;

const paramKeys: (keyof Params)[] = ["k1", "k2", "k3", "w0", "w1", "w2", "w3"];
let accepted = 0;

for (let step = 0; step < STEPS; step++) {
  const key = paramKeys[Math.floor(rand() * paramKeys.length)];
  const mag = MAGS[Math.floor(rand() * MAGS.length)];
  const sign = rand() < 0.5 ? -1 : 1;
  const cand: Params = { ...cur };
  cand[key] = cur[key] * (1 + sign * mag);

  const cb = build(cand);
  const candScore = scoreProfile(cb.knots, cb.weights, 1000);
  const candCombined = combined(candScore);

  if (feasible(candScore) && candCombined < curCombined) {
    cur = cand;
    curScore = candScore;
    curCombined = candCombined;
    accepted++;
  }
}

const finalBuild = build(cur);
console.log(JSON.stringify({
  seed: {
    knots: [-50, -30, -15, -5, 0, 5, 15, 30, 50],
    weights: [15, 25, 30, 30, 30, 30, 25, 15],
    score: seedScore,
    combined: seedCombined,
  },
  refined: {
    knots: finalBuild.knots.map(v => Math.round(v * 1e8) / 1e8),
    weights: finalBuild.weights.map(v => Math.round(v * 1e8) / 1e8),
    score: curScore,
    combined: curCombined,
  },
  stepsRun: STEPS,
  accepted,
  combinedImprovementPct: ((seedCombined - curCombined) / seedCombined) * 100,
}, null, 2));
