// Independent re-verification of all v2 search candidates using the hardened scorer (PEAK_DENSITY_CAP).
import { scoreProfile, isValidProfile } from './spline_search_lib.ts';

const CANDIDATES: Record<string, { knots: number[]; weights: number[] }> = {
  local_refine_fewknot: { // FLAGGED by the agent itself — expect rejection
    knots: [-50, -29.997, -16.23336135, -0.05835247, 0, 0.05835247, 16.23336135, 29.997, 50],
    weights: [7.36058458, 5.78551662, 11.42812676, 75.42577205, 75.42577205, 11.42812676, 5.78551662, 7.36058458],
  },
  freeform_fewknot_anneal: {
    knots: [-50, -13.26662621, -3.5107074, -0.87727954, 0, 0.87727954, 3.5107074, 13.26662621, 50],
    weights: [25, 25, 25, 25, 25, 25, 25, 25],
  },
  variable_weight_nHalf4: {
    knots: [-50, -18, -4.5, -0.5, 0, 0.5, 4.5, 18, 50],
    weights: [13.47492807, 21.89008523, 29.07443834, 35.56054836, 35.56054836, 29.07443834, 21.89008523, 13.47492807],
  },
  variable_weight_nHalf3: {
    knots: [-50, -8.67346939, -0.51020408, 0, 0.51020408, 8.67346939, 50],
    weights: [20.91099121, 33.97000544, 45.11900335, 45.11900335, 33.97000544, 20.91099121],
  },
  variable_weight_nHalf5: {
    knots: [-50, -23.15452936, -8.78233817, -2.35997998, -0.29631594, 0, 0.29631594, 2.35997998, 8.78233817, 23.15452936, 50],
    weights: [7.52284506, 14.03812526, 20.22047002, 26.19606801, 32.02249165, 32.02249165, 26.19606801, 20.22047002, 14.03812526, 7.52284506],
  },
  grid_nHalf3: {
    knots: [-50, -34.894259818731115, -18.27794561933535, 0, 18.27794561933535, 34.894259818731115, 50],
    weights: [2.4105429977479362, 14.179664692634919, 83.40979230961716, 83.40979230961716, 14.179664692634919, 2.4105429977479362],
  },
  grid_nHalf4: {
    knots: [-50, -39.22645981469512, -27.375565610859738, -14.339581986640816, 0, 14.339581986640816, 27.375565610859738, 39.22645981469512, 50],
    weights: [1.9054340155257585, 6.3514467184191945, 21.171489061397317, 70.57163020465772, 70.57163020465772, 21.171489061397317, 6.3514467184191945, 1.9054340155257585],
  },
};

function minGapPct(knots: number[]) {
  let m = Infinity;
  for (let i = 1; i < knots.length; i++) m = Math.min(m, knots[i] - knots[i - 1]);
  return m;
}

console.log('key                          valid  monotone  maxWiggle%(N=12000)  hwhmBp     within1bp    peak$/bp        minKnotGap%');
for (const [key, c] of Object.entries(CANDIDATES)) {
  const gap = minGapPct(c.knots);
  const s = scoreProfile(c.knots, c.weights, 1000, 12000);
  console.log(
    key.padEnd(29) +
    String(s.valid).padEnd(7) +
    String(s.curveMonotone).padEnd(10) +
    s.maxWigglePct.toFixed(4).padEnd(21) +
    s.hwhmBp.toFixed(5).padEnd(11) +
    ('$' + (s.within1bp / 1e6).toFixed(3) + 'M').padEnd(13) +
    ('$' + (s.peakDensity / 1e6).toFixed(2) + 'M').padEnd(16) +
    gap.toFixed(4) + '%'
  );
}

console.log('\n=== extreme-resolution (N=30000) check of the 3 surviving strong candidates ===');
for (const key of ['freeform_fewknot_anneal', 'variable_weight_nHalf4', 'variable_weight_nHalf5']) {
  const c = CANDIDATES[key];
  const s = scoreProfile(c.knots, c.weights, 1000, 30000);
  console.log(key.padEnd(28), 'maxWiggle%='+s.maxWigglePct.toFixed(5), 'hwhm='+s.hwhmBp.toFixed(6), 'within1bp=$'+(s.within1bp/1e6).toFixed(3)+'M', 'curveMonotone='+s.curveMonotone, 'peak=$'+(s.peakDensity/1e6).toFixed(2)+'M/bp');
  for (const disp of [2000,3000]) {
    const s2 = scoreProfile(c.knots, c.weights, disp, 12000);
    console.log('  disp='+disp, 'maxWiggle%='+s2.maxWigglePct.toFixed(4), 'curveMonotone='+s2.curveMonotone, 'within1bp=$'+(s2.within1bp/1e6).toFixed(3)+'M', 'peak=$'+(s2.peakDensity/1e6).toFixed(2)+'M/bp');
  }
}
