// export_parity_vectors.ts — TS↔Solidity parity vectors for every PORTABLE (regime,W) fit — the
// deployability whitelist from spline_shared_grid.json (portable:false fits are NEVER exported).
// Post-quantization re-gate (chair mandate): seamJ + mode count are re-checked on the QUANTIZED
// object (integer interior knots, integer wQ) and the export FAILS LOUDLY if quantization broke a
// gate — the vectors must certify the exact object the chain will hold, not the float fit.
import {
  clampedKnots, segPowerBasis, powEval, powArea, seamJ, densityModes, SEAM_J_MAX_EXPORT,
} from './spline_bspline.ts';

const Q = 1e9;
const BPS = 10_000;
const J = JSON.parse(await Bun.file('out/spline_shared_grid.json').text());

function exportWall(wallKey: string, outPrefix: string, out: Record<string, any>) {
  const wall = J.walls[wallKey];
  if (!wall) throw new Error(`missing wall ${wallKey}`);
  const names: string[] = J.regimes.filter((n: string) => wall.presets[n]?.portable);
  if (!names.length) { console.warn(`⚠ ${wallKey}: no portable fits — nothing exported`); return; }
  const interior = wall.shared.interiorX.map((x: number) => Math.round(x));
  for (let i = 1; i < interior.length; i++) {
    if (interior[i] <= interior[i - 1]) interior[i] = interior[i - 1] + 1;
  }
  for (const name of names) {
    const t = wall.presets[name];
    const wQ = t.w.map((v: number) => Math.round(v * Q));
    for (let i = 1; i < wQ.length; i++) if (wQ[i] < wQ[i - 1]) throw new Error(`${name}: Δw<0 after quantization`);
    if (wQ.length !== interior.length + 5) {
      throw new Error(`${name}: w len ${wQ.length} vs interior ${interior.length} (want ${interior.length + 5})`);
    }
    const T = clampedKnots(wQ.length, 0, BPS, interior);
    const segs = segPowerBasis(T, wQ.map((v: number) => v / Q));
    // Re-gate the QUANTIZED object: rounding interior knots + w to ints is a real perturbation.
    const qSeam = seamJ(segs), qModes = densityModes(segs);
    if (qSeam > SEAM_J_MAX_EXPORT) {
      throw new Error(`${wallKey}.${name}: quantization broke seamJ gate: ${qSeam.toFixed(4)} > ${SEAM_J_MAX_EXPORT} (fit ${t.seamJ.toFixed(4)})`);
    }
    if (qModes !== t.shape.modes) {
      throw new Error(`${wallKey}.${name}: quantization changed mode count: ${qModes} ≠ ${t.shape.modes}`);
    }
    const xsSet = new Set<number>();
    for (let k = 0; k <= 60; k++) xsSet.add(Math.round((k / 60) * BPS));
    for (const kx of interior) for (const d of [-1, 0, 1]) { const x = kx + d; if (x >= 0 && x <= BPS) xsSet.add(x); }
    const xs = [...xsSet].sort((a, b) => a - b);
    const yQ = xs.map((x) => Math.round(powEval(segs, x) * Q));
    const pairs = ([[0, BPS], [200, 9800], [4700, 5300], [interior[0], interior[interior.length - 1]], [1234, 8765], [0, interior[1]], [interior[interior.length - 2], BPS]] as [number, number][])
      .filter(([a, b]) => Number.isFinite(a) && Number.isFinite(b) && a < b);
    const areas = pairs.map(([a, b]) => ({ x1: a, x2: b, aQ: Math.round(powArea(segs, a, b) * Q) }));
    const key = outPrefix ? `${outPrefix}_${name}` : name;
    out[key] = { interior, wQ, xs, yQ, areas, wall: wall.W, seamJQuant: +qSeam.toFixed(4), modes: qModes };
    console.log(`${key}: nInt=${interior.length} ncp=${wQ.length} segs=${wQ.length - 4} xs=${xs.length} qSeamJ=${qSeam.toFixed(3)} modes=${qModes}`);
  }
}

const out: Record<string, any> = {};
exportWall('W5', '', out); // canonical 9, unprefixed (primary wall)
exportWall('W2', 'W2', out); // the all-clear small wall (ncp=18, 14 segs)
exportWall('W1', 'W1', out);
exportWall('W0_5', 'W05', out);

await Bun.write('../../evm/test/proto/quartic_vectors.json', JSON.stringify(out));
console.log(`wrote ../../evm/test/proto/quartic_vectors.json (${Object.keys(out).length} portable fits, quantization re-gated)`);
