// Independent re-verification of all 5 search-workflow candidates using the SAME canonical scorer.
// Do not trust agent-reported numbers — recompute from the raw (knots,weights) arrays they returned.
import { scoreProfile, isValidProfile, DEFAULT_WITHIN_1BP } from './spline_search_lib.ts';

const CANDIDATES: Record<string, { knots: number[]; weights: number[] }> = {
  grid_geometric: {
    knots: [-50,-49.68367400851410,-49.09983127782770,-48.02223302997535,-46.03331046103414,-42.36235702998724,-35.58688004392800,-23.08138542218705,0,23.08138542218705,35.58688004392800,42.36235702998724,46.03331046103414,48.02223302997535,49.09983127782770,49.68367400851410,50],
    weights: [0.13384240822996527,0.31867240054753637,0.75874381082746770,1.80653288292254200,4.30126876886319600,10.24111611634094200,24.38360980081177000,58.05621381145659400,58.05621381145659400,24.38360980081177000,10.24111611634094200,4.30126876886319600,1.80653288292254200,0.75874381082746770,0.31867240054753637,0.13384240822996527],
  },
  freeform_anneal: {
    knots: [-50,-40.12342615,-30.41309722,-21.11458968,-12.75633161,-6.34143996,-2.3599455,-0.00003584,0,0.00003584,2.3599455,6.34143996,12.75633161,21.11458968,30.41309722,40.12342615,50],
    weights: Array(16).fill(12.5),
  },
  smooth_target_fn: {
    knots: [-50,-35.40328167355882,-21.763764082403103,-9.47322854068999,0,9.47322854068999,21.763764082403103,35.40328167355882,50],
    weights: Array(8).fill(25),
  },
  variable_weight_family: {
    knots: [-50,-36.66201789182086,-24.732164021195054,-14.400607505796991,-5.964926935312902,0,5.964926935312902,14.400607505796991,24.732164021195054,36.66201789182086,50],
    weights: [11.929853870625807,16.87136114096818,20.663113030796126,23.859707741251615,26.675964216358288,26.675964216358288,23.859707741251615,20.663113030796126,16.87136114096818,11.929853870625807],
  },
  local_refine: {
    knots: [-50,-47.0956065,-43.1247,-38.6763,-33.2137965,-27.211782,-20.54976,-10.5304009125,0,10.5304009125,20.54976,27.211782,33.2137965,38.6763,43.1247,47.0956065,50],
    weights: [2.0065483893870026,2.789857006285259,3.333985498554715,4.862417748295715,9.056680683714042,15.390188852351805,29.460359556514874,33.099962264896575,33.099962264896575,29.460359556514874,15.390188852351805,9.056680683714042,4.862417748295715,3.333985498554715,2.789857006285259,2.0065483893870026],
  },
};

console.log('key                      valid  monotone  maxWiggle%   within1bp     within0.5bp   peak$/bp        weightSum');
for (const [key, c] of Object.entries(CANDIDATES)) {
  const sum = c.weights.reduce((a, b) => a + b, 0);
  const valid = isValidProfile(c.knots, c.weights);
  const s = scoreProfile(c.knots, c.weights, 1000);
  console.log(
    key.padEnd(24) +
    String(s.valid).padEnd(7) +
    String(s.curveMonotone).padEnd(10) +
    s.maxWigglePct.toFixed(5).padEnd(13) +
    ('$' + (s.within1bp / 1e6).toFixed(3) + 'M').padEnd(14) +
    ('$' + (s.within05bp / 1e6).toFixed(3) + 'M').padEnd(14) +
    ('$' + (s.peakDensity / 1e6).toFixed(1) + 'M').padEnd(16) +
    sum.toFixed(6)
  );
}

// Specifically inspect the suspicious freeform_anneal near-duplicate-knot case.
console.log('\n=== freeform_anneal center-knot gap check ===');
const fa = CANDIDATES.freeform_anneal.knots;
const mid = fa.length >> 1;
console.log('knots around center:', fa.slice(mid - 2, mid + 3));
console.log('center gap (knot[mid]-knot[mid-1]):', (fa[mid] - fa[mid - 1]).toExponential(4));
console.log('as fraction of total span (100):', ((fa[mid] - fa[mid - 1]) / 100 * 100).toExponential(4) + '%');

console.log('\n=== re-check ALL candidates against hardened validator (MIN_KNOT_GAP guard) ===');
for (const [key, c] of Object.entries(CANDIDATES)) {
  console.log(key.padEnd(24), 'isValidProfile:', isValidProfile(c.knots, c.weights));
}

console.log('\n=== high-resolution stress test (N=12000) of top surviving candidates ===');
for (const key of ['grid_geometric', 'local_refine', 'smooth_target_fn']) {
  const c = CANDIDATES[key];
  const s = scoreProfile(c.knots, c.weights, 1000, 12000);
  console.log(key.padEnd(20), 'maxWiggle%='+s.maxWigglePct.toFixed(5), 'violFrac='+(s.violFrac*100).toFixed(2)+'%', 'within1bp=$'+(s.within1bp/1e6).toFixed(3)+'M', 'curveMonotone='+s.curveMonotone, 'peak=$'+(s.peakDensity/1e6).toFixed(2)+'M/bp');
}

console.log('\n=== FINAL: local_refine at N=30000 (extreme resolution) ===');
{
  const c = CANDIDATES.local_refine;
  const s = scoreProfile(c.knots, c.weights, 1000, 30000);
  console.log('maxWiggle%='+s.maxWigglePct.toFixed(5), 'violFrac='+(s.violFrac*100).toFixed(2)+'%', 'within1bp=$'+(s.within1bp/1e6).toFixed(4)+'M', 'within0.5bp=$'+(s.within05bp/1e6).toFixed(4)+'M', 'curveMonotone='+s.curveMonotone, 'peak=$'+(s.peakDensity/1e6).toFixed(3)+'M/bp', 'valid='+s.valid);
  // also check disp=2000/3000
  for (const disp of [2000,3000]) {
    const s2 = scoreProfile(c.knots, c.weights, disp, 12000);
    console.log('  disp='+disp, 'maxWiggle%='+s2.maxWigglePct.toFixed(5), 'curveMonotone='+s2.curveMonotone, 'within1bp=$'+(s2.within1bp/1e6).toFixed(3)+'M');
  }
}
