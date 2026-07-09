// powerlaw_fewseg_search.ts — power-law weight+slope family, FEWER segments (nHalf=3..6) than the prior
// 16-segment attempt. Imports scoring math as-is from spline_search_lib.ts — no reimplementation.
import { scoreProfile, DEFAULT_WITHIN_1BP, type Score } from "./spline_search_lib.ts";

const MIN_WITHIN1BP = 1.15 * DEFAULT_WITHIN_1BP;

function buildHalf(nHalf: number, p1: number, p2: number) {
  // weight_i = (nHalf-i)^p1, i=0(center-adjacent)..nHalf-1(edge); normalized to sum 100
  const rawW = Array.from({ length: nHalf }, (_, i) => Math.pow(nHalf - i, p1));
  const sumW = rawW.reduce((a, b) => a + b, 0);
  const W = rawW.map(w => (w * 100) / sumW);
  // slope_i = (i+1)^p2, same index convention; rescaled so cumulative Δy sums to 50
  const rawS = Array.from({ length: nHalf }, (_, i) => Math.pow(i + 1, p2));
  const sumS = rawS.reduce((a, b) => a + b, 0);
  const S = rawS.map(s => (s * 50) / sumS);
  return { W, S };
}

function buildProfile(nHalf: number, p1: number, p2: number) {
  const { W, S } = buildHalf(nHalf, p1, p2);
  const yRight: number[] = [0];
  for (let k = 0; k < nHalf; k++) yRight.push(yRight[k] + S[k]);
  const leftKnots = yRight.slice(1).map(v => -v).reverse(); // -50(edge)...-S[0](center-adjacent)
  const knots = [...leftKnots, ...yRight]; // length 2*nHalf+1
  const leftW = W.slice().reverse(); // edge...center-adjacent, matches leftKnots order
  const weights = [...leftW, ...W]; // length 2*nHalf
  return { knots, weights };
}

function combined(score: Score): number {
  return score.maxWigglePct / 2 + score.hwhmBp * 3;
}
function feasible(score: Score): boolean {
  return score.valid && score.curveMonotone && score.within1bp >= MIN_WITHIN1BP;
}

const NHALVES = [3, 4, 5, 6];
const results: Record<number, { p1: number; p2: number; score: Score; knots: number[]; weights: number[]; combined: number }> = {};

for (const nHalf of NHALVES) {
  let best: { p1: number; p2: number; score: Score; knots: number[]; weights: number[]; combined: number } | null = null;
  for (let s1 = 3; s1 <= 40; s1++) {
    const p1 = s1 / 10;
    for (let s2 = 3; s2 <= 40; s2++) {
      const p2 = s2 / 10;
      const { knots, weights } = buildProfile(nHalf, p1, p2);
      const score = scoreProfile(knots, weights, 1000);
      if (!feasible(score)) continue;
      const c = combined(score);
      if (!best || c < best.combined) best = { p1, p2, score, knots, weights, combined: c };
    }
  }
  if (best) results[nHalf] = best;
}

for (const nHalf of NHALVES) {
  const r = results[nHalf];
  if (!r) { console.log(`nHalf=${nHalf}: NO FEASIBLE COMBO FOUND`); continue; }
  console.log(`nHalf=${nHalf} best p1=${r.p1} p2=${r.p2} combined=${r.combined.toFixed(4)}`);
  console.log(`  maxWigglePct=${r.score.maxWigglePct.toFixed(4)} hwhmBp=${r.score.hwhmBp.toFixed(4)} within1bp=${r.score.within1bp.toFixed(0)} within05bp=${r.score.within05bp.toFixed(0)} peakDensity=${r.score.peakDensity.toFixed(2)}`);
  if (nHalf <= 5) {
    console.log(`  knots=${JSON.stringify(r.knots.map(v => Math.round(v * 1e8) / 1e8))}`);
    console.log(`  weights=${JSON.stringify(r.weights.map(v => Math.round(v * 1e8) / 1e8))}`);
  }
}
