// grid_search_fewseg.ts — exhaustive grid search explicitly preferring FEWER segments (nHalf 2..6,
// i.e. 4..12 total segments, vs prior 16-segment result). Symmetric family: wHalf_i=rho^i (center-out,
// rho<1 decays outward), slope/delta_i=r^i (center-out, r>1 grows toward center) — same construction
// convention as the prior grid_geometric 16-seg candidate (reverse-engineered: that candidate = rho=0.42,
// nHalf=8). Imports scorer as-is, no reimplementation.
import { scoreProfile, DEFAULT_WITHIN_1BP, type Score } from "./spline_search_lib.ts";

const MIN_WITHIN1BP = 1.15 * DEFAULT_WITHIN_1BP;

function buildProfile(nHalf: number, rho: number, r: number) {
  // weights: w_k = rho^k, k=0(center)..nHalf-1(edge), normalized to sum 100 per half
  const wk = Array.from({ length: nHalf }, (_, k) => Math.pow(rho, k));
  const wSum = wk.reduce((a, b) => a + b, 0);
  const wScale = 100 / wSum;
  const wScaled = wk.map((v) => v * wScale);
  // deltas: d_k = r^(nHalf-1-k), k=0(center, largest)..nHalf-1(edge, smallest), normalized to sum 50 per half
  const dk = Array.from({ length: nHalf }, (_, k) => Math.pow(r, nHalf - 1 - k));
  const dSum = dk.reduce((a, b) => a + b, 0);
  const dScale = 50 / dSum;
  const dScaled = dk.map((v) => v * dScale);
  const yPos: number[] = [];
  let cum = 0;
  for (let k = 0; k < nHalf; k++) { cum += dScaled[k]; yPos.push(cum); }
  const negKnots = yPos.slice().reverse().map((v) => -v);
  const knots = [...negKnots, 0, ...yPos];
  const negWeights = wScaled.slice().reverse();
  const weights = [...negWeights, ...wScaled];
  return { knots, weights };
}

function feasible(s: Score): boolean {
  return s.valid && s.curveMonotone && s.within1bp >= MIN_WITHIN1BP;
}
function combinedScore(s: Score): number {
  return s.maxWigglePct / 2 + s.hwhmBp * 3;
}

const NHALFS = [2, 3, 4, 5, 6];
const results: Record<number, { rho: number; r: number; knots: number[]; weights: number[]; score: Score; combined: number } | null> = {};

for (const nHalf of NHALFS) {
  let best: { rho: number; r: number; knots: number[]; weights: number[]; score: Score; combined: number } | null = null;
  for (let ri = 15; ri <= 100; ri++) {
    const rho = ri / 100;
    for (let rj = 110; rj <= 300; rj += 2) {
      const r = rj / 100;
      const { knots, weights } = buildProfile(nHalf, rho, r);
      const score = scoreProfile(knots, weights, 1000, 2000);
      if (!feasible(score)) continue;
      const combined = combinedScore(score);
      if (!best || combined < best.combined) {
        best = { rho, r, knots, weights, score, combined };
      }
    }
  }
  results[nHalf] = best;
}

console.log("nHalf  totalSeg  rho     r       combined   maxWigglePct  hwhmBp     within1bp($M)  within05bp($M)  peakDensity($M/bp)");
for (const nHalf of NHALFS) {
  const b = results[nHalf];
  if (!b) { console.log(String(nHalf).padEnd(6), "NO FEASIBLE CONFIG FOUND"); continue; }
  console.log(
    String(nHalf).padEnd(7) +
    String(nHalf * 2).padEnd(10) +
    b.rho.toFixed(2).padEnd(8) +
    b.r.toFixed(2).padEnd(8) +
    b.combined.toFixed(4).padEnd(11) +
    b.score.maxWigglePct.toFixed(5).padEnd(14) +
    b.score.hwhmBp.toFixed(4).padEnd(11) +
    (b.score.within1bp / 1e6).toFixed(4).padEnd(15) +
    (b.score.within05bp / 1e6).toFixed(4).padEnd(16) +
    (b.score.peakDensity / 1e6).toFixed(3)
  );
}

console.log("\n=== full score objects ===");
for (const nHalf of NHALFS) {
  const b = results[nHalf];
  console.log(`nHalf=${nHalf}:`, b ? JSON.stringify({ rho: b.rho, r: b.r, combined: b.combined, score: b.score }) : "none");
}

console.log("\n=== knots/weights JSON for nHalf=3,4,5 ===");
for (const nHalf of [3, 4, 5]) {
  const b = results[nHalf];
  if (!b) { console.log(`nHalf=${nHalf}: none feasible`); continue; }
  console.log(`nHalf=${nHalf}:`, JSON.stringify({ rho: b.rho, r: b.r, knots: b.knots, weights: b.weights }));
}
