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
import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
S = json.load(open(os.path.join(HERE, 'out', 'spline_shape.json')))
DISPS = [1000, 2000, 3000]
PROFILE_KEYS = ['default', 'smooth_concentrated', 'smooth_flattop', 'flattop_gentle', 'cubic_5knot_low_bump', 'cubic_5knot_concentrated', 'prior_wide_flagged']

def stride(arr, target=380):
    n = len(arr)
    if n <= target: return arr
    k = max(1, n // target)
    return arr[::k]

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

DATA = {
    'L': S['L'],
    'profileKeys': PROFILE_KEYS,
    'profiles': {key: series_for(key) for key in PROFILE_KEYS},
    'curves': curves,
}
html = open(os.path.join(HERE, 'spline_template.html')).read().replace('/*__DATA__*/', json.dumps(DATA))
open(os.path.join(HERE, 'out', 'spline_ui.html'), 'w').write(html)
print(f"wrote out/spline_ui.html  profiles={PROFILE_KEYS} pts={len(DATA['profiles']['default'][0]['rows'])} curves={list(curves.keys())}")
