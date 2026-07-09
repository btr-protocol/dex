# make_spline_ui.py — Spline Shape Explorer: the REAL Hermite curve (ported 1:1 from Spline.sol).
# Primary view = liquidity DENSITY (the bell/spike the shape actually implies — the derivative of the
# cumulative offset-vs-size curve). Secondary view = that cumulative curve itself (impact vs size).
# Deployed default (collinear knots ⇒ cubic degenerates to a flat-topped BOX) vs an example non-collinear
# "concentrated" profile (genuine spike) — both real cubic Hermite, same knot ceiling, same weight budget.
import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
S = json.load(open(os.path.join(HERE, 'out', 'spline_shape.json')))
DISPS = [1000, 2000, 3000]

def stride(arr, target=380):
    n = len(arr)
    if n <= target: return arr
    k = max(1, n // target)
    return arr[::k]

def series_for(kind):
    out = []
    for disp in DISPS:
        p = S['profiles'][f'{kind}_{disp}']
        rows = stride([[round(r['volUsd']), round(r['offsetBps'], 4)] for r in p['rows']])
        dens = stride([[round(o, 4), round(d, 1)] for o, d in p['density']])
        out.append({'disp': disp, 'rows': rows, 'density': dens, 'knots': [round(k, 3) for k in p['knots']]})
    return out

DATA = {
    'L': S['L'],
    'default': series_for('default'),
    'conc': series_for('conc'),
    'curve': stride([[round(r['volUsd']), r['offsetBps']] for r in S['curveA1000'] if r['offsetBps'] is not None]),
    'curveDensity': stride([[round(o, 4), round(d, 1)] for o, d in S['curveA1000Density']]),
    'defaultMeta': {'weights': [50, 50, 50, 50], 'knots': [-50, -25, 0, 25, 50]},
    'concMeta': {'weights': [2, 3, 5, 10, 20, 60, 60, 20, 10, 5, 3, 2],
                 'knots': [-50, -25, -10, -4, -1.5, -0.4, 0, 0.4, 1.5, 4, 10, 25, 50]},
}
html = open(os.path.join(HERE, 'spline_template.html')).read().replace('/*__DATA__*/', json.dumps(DATA))
open(os.path.join(HERE, 'out', 'spline_ui.html'), 'w').write(html)
print(f"wrote out/spline_ui.html  default_pts={len(DATA['default'][0]['rows'])} conc_dens_pts={len(DATA['conc'][0]['density'])} curve_pts={len(DATA['curve'])}")
