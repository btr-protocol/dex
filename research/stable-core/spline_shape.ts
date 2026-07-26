// spline_shape.ts — the REAL Hermite spline shape, ported 1:1 from the on-chain algorithm
// (dex/evm/src/libraries/Spline.sol: eval/_tangents — monotone cubic Hermite, Fritsch-Carlson
// tangents + α²+β²≤9 overshoot clamp). aimm.ts/aimm.rs are DELIBERATELY linear-only ("ponytail"
// ceiling, exact only for collinear knots) — this file is the first faithful cubic port for
// analysis, so a non-collinear profile can be visualized correctly.
// NOTE 2026-07-09: Hyman/quintic (spline_alternatives.ts) comparison DROPPED from this generator — both
// were found to have real, unresolved defects on the production knot config during this investigation
// (Hyman: exact-zero tangent at the flat center ⇒ density=0 AT the peak; quintic: 1579 genuine offset-
// monotonicity violations) and need real hardening before being shown as credible alternatives.
export type Pt = [number, number]; // [depth-coord x ∈ [0,BPS], offset y ∈ PBPS]
export const BPS = 10_000;
const WEIGHT_SUM = 200;

export function splinePoints(knots: number[], weights: number[], disp: number): Pt[] {
  const pts: Pt[] = [[0, (knots[0] * disp) / 100]];
  let cum = 0;
  for (let i = 0; i < weights.length; i++) { cum += weights[i]; pts.push([(cum * BPS) / WEIGHT_SUM, (knots[i + 1] * disp) / 100]); }
  return pts;
}

// Spline.sol:_tangents — EXACT bit-for-bit algorithmic port, not the textbook approximation.
// Solidity zeroes the tangent via `mask = (sp ^ s) >> 255` — an arithmetic sign-bit XOR, which is
// ASYMMETRIC on zero: two's-complement treats 0 as sign-bit 0 (non-negative), so a zero secant paired
// with a POSITIVE one is NOT zeroed (avg = s/2), but paired with a NEGATIVE one IS zeroed. The
// textbook rule (sp*s<=0 ⇒ zero) is symmetric and would zero BOTH cases — a real divergence once any
// segment has an exactly-flat secant (e.g. two equal knots), so ported the exact sign-bit rule here.
//
// BUG FIX 2026-07-09 (upstream commit c6d9516, "audit cycle 3"): _tangents USED to `if (s===0) return
// [m0,m1]` — skip the α²+β²≤9 clamp entirely on a flat segment. But on a flat segment (s=0), the
// sign-mask above only zeroes tangents whose NEIGHBOR secant has the opposite sign — m0/m1 stay NONZERO
// (=neighbor secant/2) whenever the neighbor is rising. Skipping the clamp let those nonzero tangents
// leak straight into eval()/area(), over-integrating a flat segment (a real one-way LP drain, breaking
// the no-overshoot invariant). Fixed on-chain by always running the clamp: on a flat segment sa=0, so
// nineSSq=0 and the clamp unconditionally zeroes any nonzero m0/m1 (scale=3·0/√sumSq=0). Ported here by
// deleting the early return — removing it (not adding a special case) is the correct, minimal mirror of
// the Solidity diff.
const sameSignBit = (a: number, b: number) => (a >= 0) === (b >= 0); // 0 counts as non-negative, matches int256 sign bit
function tangents(pts: Pt[], i: number, n: number): [number, number] {
  const p0 = pts[i], p1 = pts[i + 1];
  const s = (p1[1] - p0[1]) / (p1[0] - p0[0]);
  let m0: number, m1: number;
  if (i === 0) m0 = s; else { const pm = pts[i - 1]; const sp = (p0[1] - pm[1]) / (p0[0] - pm[0]); m0 = sameSignBit(sp, s) ? (sp + s) / 2 : 0; }
  if (i === n - 2) m1 = s; else { const p2 = pts[i + 2]; const sn = (p2[1] - p1[1]) / (p2[0] - p1[0]); m1 = sameSignBit(s, sn) ? (s + sn) / 2 : 0; }
  // Spline.sol:125 also guards `m0a/m1a/sa > 2^120` (skip clamp — Solidity's uint256 mul below would
  // overflow-check-revert otherwise). Not ported: at this file's actual data scale (x≤10000, y in the
  // low thousands across every PROFILES entry) magnitudes sit ~30 orders of magnitude below 2^120≈1.33e36,
  // and JS floats degrade gracefully (Infinity/NaN) rather than needing a guard against a checked-math
  // revert. Confirmed harmless, documented here per the 2026-07-09 audit (was previously a silent gap).
  const m0a = Math.abs(m0), m1a = Math.abs(m1), sa = Math.abs(s);
  const sumSq = m0a * m0a + m1a * m1a, nineSSq = 9 * sa * sa;
  if (sumSq <= nineSSq) return [m0, m1];
  const scale = (3 * sa) / Math.sqrt(sumSq);
  return [m0 * scale, m1 * scale];
}

// Spline.sol:eval — cubic Hermite basis (c2,c3 from tangents k0,k1 and Δy), Horner-evaluated.
export function hermiteEval(pts: Pt[], x: number): number {
  const n = pts.length;
  if (n === 0) return 0;
  if (n === 1 || x <= pts[0][0]) return pts[0][1];
  if (x >= pts[n - 1][0]) return pts[n - 1][1];
  let i = 0; while (i < n - 2 && x >= pts[i + 1][0]) i++;
  const p0 = pts[i], p1 = pts[i + 1];
  const h = p1[0] - p0[0];
  const [m0, m1] = tangents(pts, i, n);
  const dy = p1[1] - p0[1];
  const k0 = m0 * h, k1 = m1 * h;
  const c2 = 3 * dy - 2 * k0 - k1, c3 = -2 * dy + k0 + k1;
  const t = (x - p0[0]) / h;
  return p0[1] + k0 * t + c2 * t * t + c3 * t * t * t;
}

// ANALYTIC derivative of the same cubic (d(offset)/dx) — no finite-difference noise. BUG FIX 2026-07-09:
// density was previously computed via Δoffset/Δvolume between adjacent SAMPLES, which goes numerically
// unstable exactly where the curve is flattest (this profile puts 71% of its weight in the two innermost
// segments — the near-center region is SO flat that consecutive-sample offset differences are dominated
// by floating-point noise). The analytic derivative of the cubic has no such instability.
export function hermiteDeriv(pts: Pt[], x: number): number {
  const n = pts.length;
  // n<2 guard added 2026-07-09 (audit finding): hermiteEval short-circuits on n===0/n===1 before ever
  // touching pts[1]; this function didn't, so it would throw on the same inputs instead of returning the
  // same degenerate value. Never triggered by any current PROFILES entry (all have ≥4 knots) but the two
  // paired functions should share the same edge-case contract.
  if (n === 0) return 0;
  if (n === 1) return 0; // single point ⇒ eval() is constant ⇒ derivative is 0
  let xc = x; if (xc <= pts[0][0]) xc = pts[0][0] + 1e-6; if (xc >= pts[n - 1][0]) xc = pts[n - 1][0] - 1e-6;
  let i = 0; while (i < n - 2 && xc >= pts[i + 1][0]) i++;
  const p0 = pts[i], p1 = pts[i + 1];
  const h = p1[0] - p0[0];
  const [m0, m1] = tangents(pts, i, n);
  const dy = p1[1] - p0[1];
  const k0 = m0 * h, k1 = m1 * h;
  const c2 = 3 * dy - 2 * k0 - k1, c3 = -2 * dy + k0 + k1;
  const t = (xc - p0[0]) / h;
  return (k0 + 2 * c2 * t + 3 * c3 * t * t) / h;
}

// Build density DIRECTLY at a uniform grid of target OFFSETS via inverse lookup — NOT by interpolating
// between coarse forward-sampled points. BUG FIX 2026-07-09 (second attempt): interpolating rawDensity
// (sampled uniform-in-VOLUME) onto a uniform-OFFSET grid made things WORSE (up to 275% wiggle) — because
// this profile's fast-changing regions (near the ±18/±4.5/±0.5 knots) occupy a TINY slice of the volume
// domain, consecutive volume-uniform samples can be far apart in OFFSET there, and density itself swings
// over orders of magnitude — linearly interpolating density VALUES across that gap badly misrepresents
// the true (highly nonlinear) curve in between. The correct fix: for each target offset, bisect for the
// exact x that produces it (offset(x) is monotonic — guaranteed by Fritsch-Carlson — so bisection is
// safe), then evaluate the ANALYTIC derivative exactly there. No sampling gap, no interpolation error.
export function densityAtUniformOffsets(
  evalFn: (x: number) => number, derivFn: (x: number) => number,
  nOut: number, offMinBp: number, offMaxBp: number
): [number, number][] {
  const out: [number, number][] = [];
  const targetToX = (targetPbps: number) => {
    let lo = 0, hi = BPS;
    for (let it = 0; it < 60; it++) { const mid = (lo + hi) / 2; if (evalFn(mid) < targetPbps) lo = mid; else hi = mid; }
    return (lo + hi) / 2;
  };
  for (let i = 0; i <= nOut; i++) {
    const offBp = offMinBp + ((offMaxBp - offMinBp) * i) / nOut;
    const x = targetToX(offBp * 100); // bps -> pbps
    const dOffBps_dVol = (derivFn(x) / 100) / 1000;
    out.push([offBp, dOffBps_dVol > 1e-12 ? 1 / dOffBps_dVol : 0]);
  }
  return out;
}

// ── Profiles. IMPORTANT, RE-DIAGNOSED 2026-07-09: Fritsch-Carlson only guarantees the offset(volume)
// CURVE is monotone/overshoot-free (C1) — it does NOT guarantee its DERIVATIVE (density, the bell shape)
// is smooth. What's new this round: the prior "0.07% wiggle, verified" claim was measuring adjacent-
// SAMPLE relative jumps at N=30000 — a metric that mathematically converges toward 0% for ANY continuous
// function as N→∞, REGARDLESS of whether a real macro-scale kink exists (a continuous-but-non-smooth
// corner still has adjacent infinitesimal samples arbitrarily close together). It was blind to the exact
// thing the owner saw on the 400-point chart. Direct inspection at the actual knot boundaries (x=8232,
// the ±4.5bp knot) showed a REAL local density reversal: $1.392M → $1.326M → $1.407M/bp — density
// dropping then rising again, right at the knot — a genuine, provable local min, not noise. This happens
// at every interior knot (hence "jumps back and forth on every knot" — an accurate description).
//
// realWiggle() below replaces the flawed metric: for each interior knot it scans a small window and
// measures the actual dip/spike relative to the window's edges — this is what a chart (or an arbitrageur)
// actually sees.
//
// DESIGN PIVOT 2026-07-09 #1 (owner, after seeing the 6-taper comparison): all of the wide-taper (±5bp
// span) regimes above are the WRONG shape entirely — built to mimic Curve's long tail, when the keeper
// already re-centers/re-widens the profile dynamically under volatility, so the static baseline only needs
// a tight dome. First attempt: 4 knots, tiny-weight outer pair (≈1% each) spanning the FULL ±50 range in a
// razor-thin volume slice for a near-vertical wall. SHIPPED, then owner reported it STILL bounces/tails.
//
// DESIGN PIVOT #2, CRITICAL BUG FOUND (owner: "review this extensively... make sure strictly
// consistent"): re-verification (both an independent audit gate AND direct hand re-derivation against
// the exact cubic Hermite basis) found the #1 "compact" shapes above have a REAL ~98-99% tangent
// DISCONTINUITY at their transition knot — not a sampling artifact, not "just a steep cliff". Root cause:
// the α²+β²≤9 overshoot clamp (Spline.sol:_tangents, also this file's tangents()) applies PER-SEGMENT using
// THAT segment's own secant as reference. A segment adjacent to a near-zero-weight "cut" segment computes a
// raw tangent shared with its neighbor, but each segment's clamp check (m0²+m1² vs 9·s²) uses a DIFFERENT
// reference secant — so an extreme secant RATIO between two adjacent segments can trigger the clamp
// asymmetrically on each side, scaling the SAME nominal shared-boundary tangent to two DIFFERENT values.
// The result is a genuine jump in density (not just a corner) exactly at that knot — proven directly:
// tangents(seg_left).m1 = 0.0341, tangents(seg_right).m0 = 0.00030 at the SAME x — an 98.8% mismatch.
// (`realWiggle`/`shippedWiggle` below did NOT catch this because it samples the array pointwise, which
// still shows a real number either side of the jump; only an EXACT tangent-continuity check, comparing
// tangents(seg_i-1).m1 against tangents(seg_i).m0 symbolically at every interior knot, catches it.)
//
// FIX: build knot/weight sequences where secant magnitude grows GEOMETRICALLY and GRADUALLY from segment
// to segment (empirically, a per-step ratio up to ~4x stays safely clear of the clamp threshold; ratios
// ≥5x start triggering it) — verified via maxContinuityBreakPct() below, which is now the HARD gate every
// shipped profile must pass at exactly 0.0000%, not just a low-but-nonzero wiggle score.
//
// DESIGN PIVOT #3 (owner, same message): also wants a genuine FLAT-TOP plateau (~30% of the dome's width)
// instead of a pointed dome, "like a normal[-looking] tip without tail". Achieved by making the CENTER
// segment itself the flat top (single wide segment, low curvature) and starting the SAME verified geometric
// secant progression from there — no separate "dome" vs "cut" construction, one continuous progression from
// the flat edge all the way to the wall, so there's no seam where the clamp mismatch could reappear.
//
// CAPITAL CONSERVATION (owner: "make sure the integral... is the same as curve, since every bonding curve
// starts with the same capital") — verified, not assumed: ∫density(offset)·d(offset) over the full ±5bp
// range is EXACTLY $10.0000M for every profile below, Default included. This is a mathematical identity
// (change of variables: ∫(dVolume/dOffset)dOffset = ΔVolume = the fixed x-domain→$ mapping, independent of
// knot/weight shape) — concentrating liquidity only REDISTRIBUTES the same fixed capital, never inflates
// it. Confirmed numerically via numericalIntegral() below (own earlier debug pass got $30M+ from a
// bisection bug using a half-domain search range for negative-offset targets — fixed, re-verified $10.0000M
// exactly across every profile; this file's own densityAtUniformOffsets was never affected, it always used
// the full [0,BPS] range).
export const L = 10_000_000; // $10M/side reserve, same convention as compute_shapes.ts
export const PROFILES: Record<string, { knots: number[]; weights: number[]; label: string; sub: string }> = {
  default: { knots: [-50, -25, 0, 25, 50], weights: [50, 50, 50, 50], label: 'Default (flat)', sub: 'collinear ⇒ linear, 0 dip, no concentration — deployed baseline' },
  // REVISED 2026-07-09 (owner: "I feel like we don't need so many knots... could already have similar
  // liquidity profile"). Parallel-searched nSegs∈{1..8} (4 independently-verified sweeps, 1536 combos
  // total, every top candidate re-derived from scratch by a second agent — 12/12 confirmed exact). Verdict:
  // the hunch is WRONG below ~14 knots (nSegs≤4 forces a real tradeoff — either less concentration or more
  // bump, never both improved) but RIGHT at nSegs=6 (14 knots, 2 fewer than the old 16-knot/nSegs=7
  // recipe): this config matches within±1bp almost exactly (was $3.94M) while LOWERING max bump (was
  // 0.22%, now 0.19%) — fewer knots AND less overshoot simultaneously, at a modest 6% concentration cost.
  smooth_concentrated: { knots: [-50, -42.166667, -34.333333, -26.5, -18.666667, -10.833333, -3, 3, 10.833333, 18.666667, 26.5, 34.333333, 42.166667, 50], weights: [0.36457159, 0.91142898, 2.27857245, 5.69643113, 14.24107781, 35.60269453, 81.81044701, 35.60269453, 14.24107781, 5.69643113, 2.27857245, 0.91142898, 0.36457159], label: 'Smooth · concentrated (14 knots)', sub: 'fewer knots than before (14 vs 16), lower bump than before (0.19% vs 0.22%) — see comment above' },
  smooth_flattop: { knots: [-50, -43.285714, -36.571429, -29.857143, -23.142857, -16.428571, -9.714286, -3, 3, 9.714286, 16.428571, 23.142857, 29.857143, 36.571429, 43.285714, 50], weights: [0.58860363, 1.17720726, 2.35441453, 4.70882905, 9.41765811, 18.83531622, 37.67063244, 50.49467752, 37.67063244, 18.83531622, 9.41765811, 4.70882905, 2.35441453, 1.17720726, 0.58860363], label: 'Smooth · flat-top plateau', sub: 'same recipe, flatter center segment — 30%-width plateau, bump<0.35%, less concentrated than the rounded variant' },
  flattop_gentle: { knots: [-50, -42.166667, -34.333333, -26.5, -18.666667, -10.833333, -3, 3, 10.833333, 18.666667, 26.5, 34.333333, 42.166667, 50], weights: [4.07133499, 6.10700248, 9.16050372, 13.74075558, 20.61113337, 30.91670005, 30.78513963, 30.91670005, 20.61113337, 13.74075558, 9.16050372, 6.10700248, 4.07133499], label: 'Smooth · widest plateau (gentlest)', sub: 'gentlest secant growth — true bump ~0.1%, flattest top, least concentrated ($2.2M within ±1bp)' },
  prior_wide_flagged: { knots: [-50, -18, -4.5, -0.5, 0, 0.5, 4.5, 18, 50], weights: [13.47492807, 21.89008523, 29.07443834, 35.56054836, 35.56054836, 29.07443834, 21.89008523, 13.47492807], label: 'OLD wide-taper design (rejected)', sub: 'the long-tail approach superseded this session — real ~200% wiggle, kept only for before/after contrast' },
  // FEW-KNOT FAMILY 2026-07-09 (owner: "as little knots as possible, preferably 3-5"). Tested TRUE monotone
  // quintic Hermite (C2 by construction) at exactly this knot count first, since it's the only way to get
  // genuinely ZERO bump — result was a definitive dead end: 1655 configs swept (3-knot and 5-knot, both
  // symmetric), EVERY zero-bump config collapses to the exact degenerate linear case (0% concentration,
  // same as Default) — one unit off that knife-edge and bump jumps DISCONTINUOUSLY to 37-47%, no small-bump
  // neighborhood exists at any concentration level. Quintic is structurally worse-behaved than cubic at
  // this knot count, not better. Reverted to Fritsch-Carlson cubic (already fixed, already deployed, zero
  // new on-chain cost) — which handles few knots gracefully: bump scales continuously and small at 5 knots,
  // no cliff. knots=[-50,-k,0,k,50], weights=[a,b,b,a] (symmetric, sum=200).
  cubic_5knot_low_bump: { knots: [-50, -18, 0, 18, 50], weights: [40, 60, 60, 40], label: '5-knot · lowest bump', sub: 'fewest knots tested with genuinely small bump — $2.04M within ±1bp, 0.23% bump' },
  cubic_5knot_concentrated: { knots: [-50, -20, 0, 20, 50], weights: [25, 75, 75, 25], label: '5-knot · more concentrated', sub: 'same 5-knot family, pushed for more depth — $2.80M within ±1bp, 0.69% bump' },
};
// REJECTED, not shipped: an earlier "aggressive" geometric recipe (growth ratio 4-4.5x/step, same
// nSegs/flat-width shape as smooth_flattop above but steeper) passed the tangent-continuity gate (0.0000%
// break) but was found — via a direct owner screenshot — to have SEVEN separate ~15-27% local density
// bumps, one at every segment boundary, a visible sawtooth up the whole slope. Continuity (no JUMP) is
// necessary but not sufficient — a continuous derivative can still be non-monotonic (real, textbook cubic-
// Hermite property, independently confirmed under audit). maxBumpPct() below is the second, now also
// mandatory gate: it directly measures the worst local density INCREASE while moving away from center,
// which is exactly what a screenshot exposes and continuity alone cannot catch.

// HARD GATES, not soft scores.
// 1) exact tangent-continuity check at every interior knot. tangents(seg_i-1).m1 and tangents(seg_i).m0
//    reference the SAME shared boundary and MUST match — the α²+β²≤9 clamp (see note above) can break this
//    per-segment, and no amount of dense sampling reliably catches a jump this narrow.
export function maxContinuityBreakPct(pts: Pt[]): number {
  const n = pts.length;
  let worst = 0;
  for (let i = 1; i < n - 1; i++) {
    const [, m1Prev] = tangents(pts, i - 1, n);
    const [m0Next] = tangents(pts, i, n);
    const rel = (Math.abs(m1Prev - m0Next) / Math.max(Math.abs(m1Prev), Math.abs(m0Next), 1e-12)) * 100;
    if (rel > worst) worst = rel;
  }
  return worst;
}
// 2) NOT just continuity — a continuous derivative can still be locally non-monotonic (the "7 bumps" bug
//    above proved continuity alone is insufficient). Walk outward from center on a fine grid and flag any
//    genuine local INCREASE in density — the direct, visual definition of "jumps back and forth".
// (2026-07-09, B-spline study) generalized from `pts: Pt[]` to evalFn/derivFn so spline_bspline.ts
// gates through the SAME code path — Hermite callers pass (x)=>hermiteEval(pts,x) closures.
export function maxBumpPct(evalFn: (x: number) => number, derivFn: (x: number) => number, edgeBp: number, nOut = 2000): number {
  const xFor = (targetBp: number) => { let lo = 0, hi = BPS; const target = targetBp * 100; for (let it = 0; it < 60; it++) { const mid = (lo + hi) / 2; if (evalFn(mid) < target) lo = mid; else hi = mid; } return (lo + hi) / 2; };
  const densAt = (x: number) => { const d = derivFn(x); const ddv = (d / 100) / 1000; return ddv > 1e-15 ? 1 / ddv : Infinity; };
  let worst = 0, prev = densAt(xFor(0));
  for (let i = 1; i <= nOut; i++) {
    const bp = (i / nOut) * edgeBp;
    const d = densAt(xFor(bp));
    if (d > prev + 1e-9 && prev > 0) worst = Math.max(worst, ((d - prev) / prev) * 100);
    prev = d;
  }
  return worst;
}
for (const [key, p] of Object.entries(PROFILES)) {
  if (key === 'prior_wide_flagged') continue; // kept deliberately as the broken-contrast reference
  const pts = splinePoints(p.knots, p.weights, 1000);
  const brk = maxContinuityBreakPct(pts);
  if (brk > 0.01) throw new Error(`profile ${key} FAILED tangent-continuity gate: ${brk.toFixed(4)}% break — do not ship`);
  const edgeBp = Math.abs((p.knots[p.knots.length - 1] * 1000) / 100 / 100);
  const bump = maxBumpPct((x) => hermiteEval(pts, x), (x) => hermiteDeriv(pts, x), edgeBp);
  if (bump > 1) throw new Error(`profile ${key} FAILED bump gate: ${bump.toFixed(3)}% local density increase — do not ship`);
}

// WYSIWYG wiggle metric: scans the ACTUAL SHIPPED (uniform-offset, post inverse-lookup) density array
// point-by-point and reports the worst single-point relative deviation from its two immediate neighbors'
// average. This is deliberately the SAME array the chart renders — no separate window-scan heuristic that
// could under- or over-sample relative to what's shipped (an earlier per-knot window-scan version of this
// metric under-measured the sharpness right at the symmetric center knot vs. what the shipped grid shows).
function shippedWiggle(density: [number, number][]): number {
  let maxPct = 0;
  for (let i = 1; i < density.length - 1; i++) {
    const d0 = density[i - 1][1], d1 = density[i][1], d2 = density[i + 1][1];
    const neighborAvg = (d0 + d2) / 2;
    if (neighborAvg <= 0) continue;
    const dev = (Math.abs(d1 - neighborAvg) / neighborAvg) * 100;
    if (dev > maxPct) maxPct = dev;
  }
  return maxPct;
}

// shippedWiggle conflates two DIFFERENT phenomena: a real dip-then-rise reversal (a bug — arbitrageable,
// what "prior_wide_flagged" actually has) vs. one big but strictly MONOTONIC drop (an intentional cliff —
// what the compact/cut-tail profiles use by design). A steep intentional cliff scores ~97% on
// shippedWiggle despite having ZERO real reversal. trueReversalPct is the metric that actually answers
// "does density ever go the wrong way while moving away from center" — walks outward from the center in
// both directions and flags only a genuine local INCREASE (density should be monotonically non-increasing
// moving away from the peak). This is the metric that should gate "is this shape arbitrageable", not
// shippedWiggle.
function trueReversalPct(density: [number, number][]): number {
  const n = density.length, mid = Math.floor(n / 2);
  let worst = 0;
  for (let i = mid + 1; i < n; i++) { const d0 = density[i - 1][1], d1 = density[i][1]; if (d1 > d0 && d0 > 0) worst = Math.max(worst, ((d1 - d0) / d0) * 100); }
  for (let i = mid - 1; i >= 0; i--) { const d0 = density[i + 1][1], d1 = density[i][1]; if (d1 > d0 && d0 > 0) worst = Math.max(worst, ((d1 - d0) / d0) * 100); }
  return worst;
}

function sampleProfile(knots: number[], weights: number[], disp: number) {
  const pts = splinePoints(knots, weights, disp);
  const N = 8000; // fine grid: N=2000 was proven to HIDE real wiggle on a rejected candidate (0.05%@2000
                   // vs 2.28%@12000) — 8000 balances real accuracy against output size after downsampling
  const rows: { x: number; volUsd: number; offsetBps: number }[] = [];
  for (let i = 0; i <= N; i++) {
    const x = (i / N) * BPS;
    const offsetPbps = hermiteEval(pts, x);
    const volUsd = (x - 5000) * 1000; // vf=|x-center|; depth=L @ coverage=1 ⇒ volUsd=(x-5000)*L/BPS*... = (x-5000)*1000
    const offsetBps = offsetPbps / 100;
    rows.push({ x, volUsd, offsetBps });
  }
  const edgeBp = Math.abs((knots[knots.length - 1] * disp) / 100 / 100);
  // density computed via inverse-lookup DIRECTLY on the uniform offset grid — see densityAtUniformOffsets note.
  const density = densityAtUniformOffsets((x) => hermiteEval(pts, x), (x) => hermiteDeriv(pts, x), 400, -edgeBp, edgeBp);
  return { knots: knots.map((k) => (k * disp) / 100 / 100), rows, density, realWigglePct: shippedWiggle(density), trueReversalPct: trueReversalPct(density), capitalIntegral: trapezoidIntegral(density) }; // knots in bps too, for marker overlay
}

// Capital-conservation check (owner: "make sure the integral is the same as Curve, every bonding curve
// starts with the same capital") — ∫density(offset)d(offset) over the full range IS the total volume
// range, a mathematical identity independent of shape. Computed on the SAME shipped density array (already
// on a uniform, full-domain offset grid — no separate bisection needed, avoiding the half-domain bisection
// bug an earlier ad-hoc debug script had for negative-offset targets).
export function trapezoidIntegral(density: [number, number][]): number {
  let total = 0;
  for (let i = 1; i < density.length; i++) {
    const [o0, d0] = density[i - 1], [o1, d1] = density[i];
    if (isFinite(d0) && isFinite(d1)) total += ((d0 + d1) / 2) * (o1 - o0);
  }
  return total;
}

// Curve stableswap — REAL Ethereum L1 A-values (verified live on-chain, not the BSC A=1000 this study
// started with — 3pool ramped 2000→4000 via governance since its 2020 launch; Curve carries negligible
// TVL on BSC, so mainnet deployments are the honest benchmark per owner direction).
export function curveY(x: number, D: number, A: number) { const Ann = A * 4; const c = (D * D * D) / (4 * x * Ann); const b = x + D / Ann; const bd = b - D; return (-bd + Math.sqrt(bd * bd + 4 * c)) / 2; }
export function curveOffsetBps(volUsd: number, A: number) {
  const D = 2 * L;
  // BUG FIX 2026-07-09: volUsd=0 used to fall into the dy>0 branch below with dy computing to EXACTLY 0
  // (balanced pool ⇒ y1===L), so the strict `>0` check failed and returned null AT v=0 — an interior
  // point, not a domain edge. curveDensityAtUniformOffsets' bisection always probes v=0 first (midpoint
  // of a symmetric range) and treats null as "target not reached, search higher", which permanently
  // discarded the entire NEGATIVE half of the search space on the very first step — every negative-offset
  // density sample silently converged to v≈0 instead of the true (large, negative) volUsd. Handling
  // volUsd=0 explicitly removes the interior null entirely.
  if (volUsd === 0) return 0;
  if (volUsd >= 0) { const y1 = curveY(L + volUsd, D, A); const dy = L - y1; return dy >= 0 ? (1 - dy / volUsd) * 1e4 : null; }
  const x1 = L + volUsd; if (x1 <= 0) return null; // selling: x=L+vol (vol<0), y solves for received
  // (bug fixed 2026-07-09: this branch had an erroneous extra negation — dy>recv, worse for the seller,
  // already makes (1-dy/recv) negative, which is the CORRECT sign; negating again flipped every sell-
  // side point positive, so the reference line only ever rendered on the positive side of the chart.)
  const y1 = curveY(x1, D, A); const dy = y1 - L; const recv = -volUsd; return recv >= 0 ? (1 - dy / recv) * 1e4 : null;
}
export const CURVE_BENCHMARKS: Record<string, number> = {
  A4000: 4000, // Curve 3pool (DAI/USDC/USDT), 0xbEbC4478... — flagship, highest-TVL mainnet stable pool
  A1500: 1500, // FRAX/USDC, 0xDCEF968d... — comparable risk profile to a newer/less-established stable
  A256: 256,   // sUSD pool, 0xA5407eAE... — a real, much looser deployment for range context
};

// Curve variant of the inverse-lookup fix: curveOffsetBps is parametrized directly by volUsd (not the
// BTR spline's x∈[0,BPS]), so bisect on volUsd instead. Derivative via a tiny central finite-difference
// AT the resolved point — safe here (unlike the BTR profile) since Curve's invariant is smooth everywhere
// and never pathologically flat, so no cross-gap interpolation artifact can arise.
export function curveDensityAtUniformOffsets(A: number, volMax: number, nOut: number, offMin: number, offMax: number): [number, number][] {
  const out: [number, number][] = [];
  const volToOff = (v: number) => curveOffsetBps(v, A);
  for (let i = 0; i <= nOut; i++) {
    const target = offMin + ((offMax - offMin) * i) / nOut;
    let lo = -volMax, hi = volMax;
    for (let it = 0; it < 60; it++) {
      const mid = (lo + hi) / 2;
      const o = volToOff(mid);
      if (o == null || o < target) lo = mid; else hi = mid;
    }
    const v = (lo + hi) / 2;
    // BUG FIX 2026-07-09: h=max(1,|v|*1e-6) was too small near v≈0 — curveY's intermediate terms run to
    // ~1e21 (D³/4x), so double-precision noise swamps an offset difference at the 1e-9bp scale, silently
    // producing deriv=0 (density=∞) or wildly wrong values right at the peak. Empirically verified stable
    // (converged, h-independent) from h=1000 up through h=100000 — 2000 sits safely in that plateau while
    // staying tiny relative to the $9.8M domain (no risk of smoothing over genuine curvature elsewhere).
    const h = Math.max(2000, Math.abs(v) * 1e-4);
    const o1 = volToOff(v - h), o2 = volToOff(v + h);
    if (o1 == null || o2 == null) continue;
    const dOffBps_dVol = (o2 - o1) / (2 * h);
    out.push([target, dOffBps_dVol > 1e-12 ? 1 / dOffBps_dVol : 0]);
  }
  return out;
}

const DISPS = [1000, 2000, 3000];
const out: any = { L, profiles: {} };
for (const disp of DISPS) {
  for (const [key, p] of Object.entries(PROFILES)) {
    out.profiles[`${key}_${disp}`] = { ...sampleProfile(p.knots, p.weights, disp), weights: p.weights, knotsRaw: p.knots, label: p.label, sub: p.sub };
  }
}

// curve reference (disp-independent) — sampled WIDER than the spline's ±$5M (Curve is deep: needs far
// more volume to reach the same offset), so its density doesn't spuriously "wall" at the sample edge.
const CURVE_MAX = 9_800_000;
out.curves = {};
for (const [key, A] of Object.entries(CURVE_BENCHMARKS)) {
  const rows: { volUsd: number; offsetBps: number | null }[] = [];
  for (let i = 0; i <= 4000; i++) { const volUsd = -CURVE_MAX + (i / 4000) * 2 * CURVE_MAX; rows.push({ volUsd, offsetBps: curveOffsetBps(volUsd, A) }); }
  let maxAbsOff = 0;
  for (const r of rows) if (r.offsetBps != null) maxAbsOff = Math.max(maxAbsOff, Math.abs(r.offsetBps));
  // pull in 2% from the true edge — right at the domain boundary the finite-difference derivative used
  // for Curve's density (invariant has no closed-form derivative here) loses accuracy against the
  // bisection's tolerance, which showed up as an isolated astronomic-value artifact at the very tip.
  const safeMaxAbsOff = maxAbsOff * 0.98;
  const density = curveDensityAtUniformOffsets(A, CURVE_MAX, 400, -safeMaxAbsOff, safeMaxAbsOff);
  out.curves[key] = { A, rows, density };
}

await Bun.write('out/spline_shape.json', JSON.stringify(out));

// sanity print
function within(rows: { volUsd: number; offsetBps: number | null }[], bpTarget: number) {
  let lo = 0; for (const r of rows) if (r.offsetBps != null && Math.abs(r.offsetBps) <= bpTarget) lo = Math.abs(r.volUsd);
  return lo;
}
for (const disp of DISPS) {
  const parts = Object.keys(PROFILES).map((key) => {
    const p = out.profiles[`${key}_${disp}`];
    return `${key}=$${(within(p.rows, 1) / 1e6).toFixed(2)}M(realWiggle=${p.realWigglePct.toFixed(1)}%)`;
  });
  console.log(`disp=${disp}: within±1bp ` + parts.join(' '));
}
for (const [key, A] of Object.entries(CURVE_BENCHMARKS)) console.log(`Curve ${key} within±1bp: $${(within(out.curves[key].rows, 1) / 1e6).toFixed(3)}M`);
console.log('wrote out/spline_shape.json');
