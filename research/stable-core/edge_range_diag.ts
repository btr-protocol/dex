// diag: best combined score PER plateauDepth (pooled across nHalf/leadFrac/decay/yRatio) to confirm
// plateauDepth=0 (full-range) genuinely beats plateauDepth>0 (shorter-range/early-plateau) on merit,
// not just by feasibility filtering artifacts.
import { scoreProfile, isValidProfile, DEFAULT_WITHIN_1BP, type Score } from "./spline_search_lib";

const MIN_WITHIN1BP = 1.15 * DEFAULT_WITHIN_1BP;
const combinedScore = (s: Score) => s.maxWigglePct / 2 + s.hwhmBp * 3;
const feasible = (s: Score) => s.valid && s.curveMonotone && s.within1bp >= MIN_WITHIN1BP;

function buildHalfWeights(nHalf: number, leadFrac: number, decayRatio: number): number[] {
  const m = nHalf - 1;
  if (m === 0) return [leadFrac];
  const remaining = 100 - leadFrac;
  const raw = Array.from({ length: m }, (_, i) => Math.pow(decayRatio, i));
  const rawSum = raw.reduce((a, b) => a + b, 0);
  return [leadFrac, ...raw.map(v => (v * remaining) / rawSum)];
}
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
  return { knots: [...negKnots, ...posKnots], weights };
}

const NHALFS = [3, 4, 5, 6];
const LEAD_FRACS = Array.from({ length: 26 }, (_, i) => 40 + 2 * i);
const DECAY_RATIOS = [0.3, 0.45, 0.6, 0.75];
const Y_RATIOS = [1.4, 1.8, 2.2, 2.6, 3.0];

const byDepth: Record<number, { feasCount: number; totalCount: number; bestCombined: number; bestFeasCombined: number }> = {};

for (const nHalf of NHALFS) {
  const maxDepth = Math.min(3, nHalf - 2);
  for (const leadFrac of LEAD_FRACS) {
    for (const decayRatio of DECAY_RATIOS) {
      const halfW = buildHalfWeights(nHalf, leadFrac, decayRatio);
      for (const yRatio of Y_RATIOS) {
        for (let plateauDepth = 0; plateauDepth <= maxDepth; plateauDepth++) {
          const halfY = buildHalfKnotsY(nHalf, yRatio, plateauDepth);
          const { knots, weights } = assemble(halfW, halfY);
          if (!isValidProfile(knots, weights)) continue;
          const score = scoreProfile(knots, weights, 1000);
          if (!byDepth[plateauDepth]) byDepth[plateauDepth] = { feasCount: 0, totalCount: 0, bestCombined: Infinity, bestFeasCombined: Infinity };
          const rec = byDepth[plateauDepth];
          rec.totalCount++;
          if (score.valid && score.curveMonotone) {
            const c = combinedScore(score);
            rec.bestCombined = Math.min(rec.bestCombined, c);
            if (feasible(score)) { rec.feasCount++; rec.bestFeasCombined = Math.min(rec.bestFeasCombined, c); }
          }
        }
      }
    }
  }
}
console.log(JSON.stringify(byDepth, null, 2));
