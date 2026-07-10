# make_spline_ui.py — Spline Shape Explorer: the REAL Hermite curve (ported 1:1 from Spline.sol).
# Primary view = liquidity DENSITY (the bell/spike the shape actually implies — the derivative of the
# cumulative offset-vs-size curve). Secondary view = that cumulative curve itself (impact vs size).
# v6 (2026-07-09) SECOND FIX: v5's "aggressive" recipe (growth ratio 4-4.5x/step) passed the exact
# tangent-continuity gate (0.0000% break) but the owner's screenshot showed SEVEN separate ~15-27% local
# density bumps — one at every segment boundary, a visible sawtooth. Continuity (no jump) ≠ monotonic
# derivative (textbook cubic-Hermite property: a continuous segment's derivative can still have an interior
# extremum). Added a SECOND hard gate, maxBumpPct() in spline_shape.ts — measures the worst local density
# INCREASE while moving away from center, the direct definition of a visible bump — and re-tuned every
# profile to pass BOTH gates (max shipped bump now ≤2.1%, down from 15-27%, verified on the actual shipped
# JSON, not just the generator's own claim). v5's aggressive nose8/nose10/pointy variants are retired
# entirely, not just relabeled. Capital-conservation still verified: ∫density d(offset) = $10.0000M
# exactly for every profile (a mathematical identity, not shape-dependent — concentrating liquidity only
# redistributes the same fixed capital, confirmed numerically, not just assumed).
# v7 (2026-07-09): + B-spline group — clamped cubic B-spline (C2) fits from spline_bspline.ts /
# out/spline_bspline.json, sampled through powEval/powDeriv (the exact on-chain binary-search+Horner
# path the Solidity port will run). Candidate replacement for the FC Hermite: monotone via Δw≥0,
# density kink-free BY CONSTRUCTION (y C2 ⇒ density C1), multimodal capable (bimodal proof included).
import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
S = json.load(open(os.path.join(HERE, 'out', 'spline_shape.json')))
B = json.load(open(os.path.join(HERE, 'out', 'spline_bspline.json')))
DISPS = [1000, 2000, 3000]
PROFILE_KEYS = ['default', 'smooth_concentrated', 'smooth_flattop', 'flattop_gentle', 'cubic_5knot_low_bump', 'cubic_5knot_concentrated', 'prior_wide_flagged']

def stride(arr, target=380):
    # linspace-index pick (NOT floor-div step): decimation degrades smoothly with n and always
    # returns exactly min(n,target) points incl. both endpoints — no cliff at n=2*target.
    n = len(arr)
    if n <= target: return arr
    return [arr[round(i * (n - 1) / (target - 1))] for i in range(target)]

def series_for(key):
    out = []
    for disp in DISPS:
        p = S['profiles'][f'{key}_{disp}']
        rows = stride([[round(r['volUsd']), round(r['offsetBps'], 4)] for r in p['rows']])
        dens = stride([[round(o, 4), round(d, 1)] for o, d in p['density']])
        out.append({'disp': disp, 'rows': rows, 'density': dens, 'knots': [round(k, 3) for k in p['knots']],
                    'label': p['label'], 'sub': p['sub'], 'realWigglePct': round(p['realWigglePct'], 2),
                    'trueReversalPct': round(p['trueReversalPct'], 3), 'capitalIntegral': round(p['capitalIntegral'], 1)})
    return out

CURVE_META = {
    'A4000': {'label': 'Curve 3pool', 'sub': 'A=4000 · mainnet flagship, highest-TVL stable pool'},
    'A1500': {'label': 'Curve FRAX/USDC', 'sub': 'A=1500 · comparable risk profile'},
    'A256':  {'label': 'Curve sUSD pool', 'sub': 'A=256 · real, looser mainnet deployment'},
}
curves = {}
for key, meta in CURVE_META.items():
    c = S['curves'][key]
    curves[key] = {
        'A': c['A'], 'label': meta['label'], 'sub': meta['sub'],
        'rows': stride([[round(r['volUsd']), r['offsetBps']] for r in c['rows'] if r['offsetBps'] is not None]),
        'density': stride([[round(o, 4), round(d, 1)] for o, d in c['density']]),
    }

# B-spline fits (QUARTIC v2 — C2 density): (label, kind) per target; sub-labels built from measured
# metrics, never hand-typed numbers. kind drives the honest quality metric shown: curve→err-vs-target,
# plateau/bimodal→visual gates, skew/tail shapes→a static shape descriptor (their "error" is dominated
# by the unfittable ±wall). seamJ = worst knot-seam footprint in decades (gate ≤0.3, kinky was ≥1.18).
BSPLINE_META = {
    'curve_A4000': ('B-spline · fits Curve A=4000', 'curve'),
    'curve_A1500': ('B-spline · fits Curve A=1500', 'curve'),
    'curve_A256':  ('B-spline · fits Curve A=256', 'curve'),
    'eclp':        ('B-spline · Gyro E-CLP plateau', 'plateau'),
    'bimodal':     ('B-spline · bimodal ±15bp', 'bimodal'),
    'right_skew':  ('B-spline · right-skew', 'skew-normal · heavier RIGHT tail'),
    'left_skew':   ('B-spline · left-skew', 'skew-normal · heavier LEFT tail'),
    'lognormal':   ('B-spline · log-normal', 'one-sided · heavy right tail'),
    'normal':      ('B-spline · mesokurtic (normal)', 'pure Gaussian σ=10bp · the kurtosis reference'),
    'fat_tail':    ('B-spline · leptokurtic (fat tail)', 'Student-t · sharp peak, heavy tails'),
    'thin_tail':   ('B-spline · platykurtic (thin tail)', 'super-Gaussian · broad top, light tails'),
    'valley':      ('B-spline · valley (V / barbell)', 'INVERTED · liquidity pulled OFF peg to the wings'),
    'skew_fat':    ('B-spline · skew-t (skew×lepto)', 'asymmetric AND fat-tailed · long heavy right tail'),
    'skew_thin':   ('B-spline · skew-platy', 'asymmetric flat-top · light tails, right-leaning'),
}
bsplines = {}
NKD = B['degree'] + 1  # interior knots = ncp - degree - 1
for key, (label, kind) in BSPLINE_META.items():
    t = B['targets'][key]
    sh = t.get('shape')  # wall/shape targets carry log-scale visual gates; Curve targets = None
    nk, sj = t['chosen_ncp'] - NKD, t['seamJ']
    if kind == 'curve':  # smooth Curve fit — error-vs-target is the honest quality metric
        sub = f"{nk} knots · err {t['maxErrPbps']:.2f} pbps · seam {sj:.2f} · C2 density"
    elif kind == 'plateau':  # E-CLP — ripple + lobe-free rolloff (core-err = unfittable vertical wall)
        sub = f"{nk} knots · flat plateau · ripple {sh['plateauRipplePct']:.2f}% · seam {sj:.2f} · C2 density"
    elif kind == 'bimodal':
        pk = sh['peakAbsOffBp'][0]
        sub = f"{nk} knots · 2 peaks @ ±{pk:g}bp · seam {sj:.2f} · C2 density"
    else:  # skew / kurtosis shapes — static descriptor
        sub = f"{nk} knots · {kind} · seam {sj:.2f} · C2 density"
    bsplines[key] = {
        'label': label, 'sub': sub, 'edgeBp': round(t['edgeBp'], 3),
        'rows': stride(t['series']['rows']),
        'density': stride(t['series']['density'], 1300),  # keep all 1201 uniform-offset pts — resolves knot-span bends
    }

DATA = {
    'L': S['L'],
    'profileKeys': PROFILE_KEYS,
    'profiles': {key: series_for(key) for key in PROFILE_KEYS},
    'curves': curves,
    'bsplines': bsplines,
    'bsplineFc': B['fc'],
}
html = open(os.path.join(HERE, 'spline_template.html')).read().replace('/*__DATA__*/', json.dumps(DATA))
open(os.path.join(HERE, 'out', 'spline_ui.html'), 'w').write(html)
print(f"wrote out/spline_ui.html  profiles={PROFILE_KEYS} pts={len(DATA['profiles']['default'][0]['rows'])} curves={list(curves.keys())}")
