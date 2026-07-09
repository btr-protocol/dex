// edge_range_search.ts — does reaching the SAME edge magnitude (50 => ±5bp @ disp=1000) over a
// SHORTER volume range (early-plateau: rise finishes before the last half-segment, rest flat at 50)
// beat a curve that uses the FULL half-range to get there (plateauDepth=0, baseline)?
// Imports scorer as-is — no reimplementation.
import { scoreProfile, isValidProfile, DEFAULT_WITHIN_1BP, type Score } from "./spline_search_lib";

const MIN_WITHIN1BP = 1.15 * DEFAULT_WITHIN_1BP;
const combinedScore = (s: Score) => s.maxWigglePct / 2 + s.hwhmBp * 3;
const feasible = (s: Score) => s.valid && s.curveMonotone && s.within1bp >= MIN_WITHIN1BP;

// half-weights, center-to-edge order (idx0 = segment adjacent to center = the "leading" one).
// leadFrac = idx0 share (of 100 half-total); remainder geometrically decayed across the rest.
function buildHalfWeights(nHalf: number, leadFrac: number, decayRatio: number): number[] {
  const m = nHalf - 1;
  if (m === 0) return [leadFrac];
  const remaining = 100 - leadFrac;
  const raw = Array.from({ length: m }, (_, i) => Math.pow(decayRatio, i));
  const rawSum = raw.reduce((a, b) => a + b, 0);
  return [leadFrac, ...raw.map(v => (v * remaining) / rawSum)];
}

// half knot Y-values, center-to-edge order, length nHalf, last = 50 always.
// active = nHalf - plateauDepth rising segments reach 50 at index=active; remaining plateauDepth
// segments are deliberate flat (0-gap) — this is the "shorter volume range to the wall" mechanism.
function buildHalfKnotsY(nHalf: number, ratio: number, plateauDepth: number): number[] {
  const active = nHalf - plateauDepth;
  const y: number[] = [];
  for (let i = 1; i <= active; i++) y.push((50 * (Math.pow(ratio, i) - 1)) / (Math.pow(ratio, active) - 1));
  for (let i = 0; i < plateauDepth; i++) y.push(50);
  return y;
}

function assemble(halfW: number[], halfY: number[]) {
  const weights = [...[...halfW].reverse(), ...halfW];
  const posKnots = [0, ...halfY];
  const negKnots = posKnots.slice(1).map(v => -v).reverse();
  const knots = [...negKnots, ...posKnots];
  return { knots, weights };
}

const NHALFS = [3, 4, 5, 6];
const LEAD_FRACS = Array.from({ length: 26 }, (_, i) => 40 + 2 * i); // 40..90 step 2
const DECAY_RATIOS = [0.3, 0.45, 0.6, 0.75];
const Y_RATIOS = [1.4, 1.8, 2.2, 2.6, 3.0];

type Best = { knots: number[]; weights: number[]; score: Score; combined: number; nHalf: number; leadFrac: number; decayRatio: number; yRatio: number; plateauDepth: number };

const bestPerNHalf: Record<number, Best | null> = {};

for (const nHalf of NHALFS) {
  let best: Best | null = null;
  const maxDepth = Math.min(3, nHalf - 2); // leave >=2 active rising segments
  for (const leadFrac of LEAD_FRACS) {
    for (const decayRatio of DECAY_RATIOS) {
      const halfW = buildHalfWeights(nHalf, leadFrac, decayRatio);
      for (const yRatio of Y_RATIOS) {
        for (let plateauDepth = 0; plateauDepth <= maxDepth; plateauDepth++) {
          const halfY = buildHalfKnotsY(nHalf, yRatio, plateauDepth);
          const { knots, weights } = assemble(halfW, halfY);
          if (!isValidProfile(knots, weights)) continue;
          const score = scoreProfile(knots, weights, 1000);
          if (!feasible(score)) continue;
          const combined = combinedScore(score);
          if (!best || combined < best.combined) {
            best = { knots, weights, score, combined, nHalf, leadFrac, decayRatio, yRatio, plateauDepth };
          }
        }
      }
    }
  }
  bestPerNHalf[nHalf] = best;
}

let overallBest: Best | null = null;
for (const nHalf of NHALFS) {
  const b = bestPerNHalf[nHalf];
  if (b && (!overallBest || b.combined < overallBest.combined)) overallBest = b;
}

console.log(JSON.stringify({
  minWithin1bp: MIN_WITHIN1BP,
  bestPerNHalf: Object.fromEntries(NHALFS.map(n => [n, bestPerNHalf[n] && {
    nHalf: n,
    leadFrac: bestPerNHalf[n]!.leadFrac,
    decayRatio: bestPerNHalf[n]!.decayRatio,
    yRatio: bestPerNHalf[n]!.yRatio,
    plateauDepth: bestPerNHalf[n]!.plateauDepth,
    combined: bestPerNHalf[n]!.combined,
    score: bestPerNHalf[n]!.score,
  }])),
  overallBest: overallBest && {
    nHalf: overallBest.nHalf,
    leadFrac: overallBest.leadFrac,
    decayRatio: overallBest.decayRatio,
    yRatio: overallBest.yRatio,
    plateauDepth: overallBest.plateauDepth,
    combined: overallBest.combined,
    score: overallBest.score,
    knots: overallBest.knots,
    weights: overallBest.weights,
  },
}, null, 2));
