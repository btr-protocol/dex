// export_parity_vectors.ts — TS↔Solidity parity vectors for the quartic B-spline proto.
// Reads out/spline_bspline.json (the shipped fits), reconstructs the EXACT integer-domain object the
// keeper would push (int x-knots — clampGap's 10-unit floor keeps them distinct — + w quantized to
// pbps·1e9), evaluates it through the TS on-chain path (segPowerBasis → powEval/powArea), and emits
// ../../evm/test/proto/quartic_vectors.json for QuarticProto.t.sol. Both sides evaluate the SAME
// rational object; any divergence is Solidity integer truncation (tolerance asserted in the test).
import { clampedKnots, segPowerBasis, powEval, powArea } from './spline_bspline.ts';

const Q = 1e9; // pbps fixed-point scale used by the Sol proto
const BPS = 10_000;
const J = JSON.parse(await Bun.file('out/spline_bspline.json').text());
// Cover the DIVERSE shape families so Sol≡TS parity is proven for every curve type the keeper can push,
// not just one: a Curve fit, a 2-peak, an inverted V/barbell, an asymmetric skew, a fat tail, a plateau.
const NAMES = ['curve_A4000', 'bimodal', 'valley', 'right_skew', 'skew_fat', 'fat_tail', 'eclp'];

const out: any = {};
for (const name of NAMES) {
  const t = J.targets[name];
  // series.knotsBps stores interior knots as (x-5000)*1000/1e6 $M, 3dp ⇒ x to 1 unit — exact ints.
  const interior = t.series.knotsBps.map((m: number) => Math.round(m * 1000 + 5000));
  for (let i = 1; i < interior.length; i++) if (interior[i] <= interior[i - 1]) throw new Error(`${name}: non-increasing int knots`);
  const wQ = t.w.map((v: number) => Math.round(v * Q)); // 4dp pbps ⇒ exact in f64 at ·1e9
  for (let i = 1; i < wQ.length; i++) if (wQ[i] < wQ[i - 1]) throw new Error(`${name}: Δw<0 after quantization`);
  const T = clampedKnots(wQ.length, 0, BPS, interior);
  const segs = segPowerBasis(T, wQ.map((v: number) => v / Q));
  // sample xs: uniform + tight straddles of every interior knot (the seam-sensitive spots)
  const xsSet = new Set<number>();
  for (let k = 0; k <= 60; k++) xsSet.add(Math.round((k / 60) * BPS));
  for (const kx of interior) for (const d of [-1, 0, 1]) { const x = kx + d; if (x >= 0 && x <= BPS) xsSet.add(x); }
  const xs = [...xsSet].sort((a, b) => a - b);
  const yQ = xs.map((x) => Math.round(powEval(segs, x) * Q));
  // area pairs: mixed narrow/wide spans, incl. cross-knot and full-domain (guard: short knot lists)
  const pairs = ([[0, BPS], [200, 9800], [4700, 5300], [interior[0], interior[interior.length - 1]], [1234, 8765], [0, interior[1]], [interior[interior.length - 2], BPS]] as [number, number][])
    .filter(([a, b]) => Number.isFinite(a) && Number.isFinite(b) && a < b);
  const areas = pairs.map(([a, b]) => ({ x1: a, x2: b, aQ: Math.round(powArea(segs, a, b) * Q) }));
  out[name] = { interior, wQ, xs, yQ, areas };
  console.log(`${name}: nInt=${interior.length} ncp=${wQ.length} xs=${xs.length} areas=${areas.length} yQ[0]=${yQ[0]} yQ[last]=${yQ[yQ.length - 1]}`);
}
await Bun.write('../../evm/test/proto/quartic_vectors.json', JSON.stringify(out));
console.log('wrote ../../evm/test/proto/quartic_vectors.json');
