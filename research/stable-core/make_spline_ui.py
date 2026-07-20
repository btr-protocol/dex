# make_spline_ui.py — Spline Shape Explorer.
# Default: hyper tip (W=1) + core W=5 pack + Curve A4000 + FC tip contrast.
import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
S = json.load(open(os.path.join(HERE, 'out', 'spline_shape.json')))
G = json.load(open(os.path.join(HERE, 'out', 'spline_shared_grid.json')))
B = json.load(open(os.path.join(HERE, 'out', 'spline_bspline.json')))  # FC bump ref only
DISPS = [1000, 2000, 3000]
PROFILE_KEYS = ['default', 'smooth_concentrated', 'smooth_flattop', 'flattop_gentle', 'cubic_5knot_low_bump', 'cubic_5knot_concentrated', 'prior_wide_flagged']

def stride(arr, target=380):
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
    'A4000': {'label': 'Curve 3pool', 'sub': 'A=4000 · mainnet flagship tip reference'},
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

# Explorer series: hyper from W=1 tip + W=0.5 hyper overlay + W=5 core + pin variants.
REGIME_META = {
    'hyper':   ('Hyper · W=±1bp tip', 'peak ≥$80M/bp floor'),
    'hyper05': ('Hyper · W=±0.5bp', '8.9x 3pool marginal peak'),
    'flat':    ('Flat (Uni range)', 'stables / pegged FX'),
    'plateau': ('Plateau (Gyro-like)', 'soft-peg / correlated'),
    'meso':    ('Meso (Gaussian)', 'FX majors / quiet equity'),
    'lepto':   ('Lepto (Student-t)', 'equity / crypto stress'),
    'platy':   ('Platy (broad dome)', 'wide FI / low conviction'),
    'skew_L':  ('Skew L', 'equity crash skew'),
    'skew_R':  ('Skew R', 'commodity / alt upside'),
    'pin_M':   ('Pin M (gamma)', 'options sticky-strike'),
    'pin_M_tight': ('Pin M tight', 'closer twin peaks'),
    'pin_M_wide':  ('Pin M wide', 'wider twin peaks'),
}

w5 = G['walls']['W5']
w1 = G['walls']['W1']
w05 = G['walls']['W0_5']
ncp, nk, h = w5['shared']['ncp'], w5['shared']['knots'], w5['shared']['hBp']
port = G.get('port', {})

def pack(key, src, label, use, wall_tag):
    t = src['presets'][key if key != 'hyper05' else 'hyper']
    sj = t['seamJ']
    sh = t.get('shape') or {}
    m = t.get('metrics') or {}
    portable = t.get('portable', False)
    port_tag = 'PORTABLE' if portable else 'NOT portable'
    if key.startswith('pin_M') and sh.get('peakAbsOffBp'):
        sub = f"{wall_tag} · peaks ±{sh['peakAbsOffBp'][0]:g}bp · trough {100*sh.get('troughDepth',0):.0f}% · seam {sj:.3f} · {port_tag}"
    elif key.startswith('hyper'):
        sub = f"{wall_tag} · peak {m.get('peakOverCurve',0):.1f}x 3pool(marginal) · w05 {100*m.get('within05Frac',0):.0f}% · seam {sj:.3f} · {port_tag}"
    elif key in ('flat', 'plateau') and sh.get('plateauRipplePct') is not None:
        sub = f"{wall_tag} · ripple {sh['plateauRipplePct']:.2f}% · seam {sj:.3f} · {port_tag}"
    else:
        sub = f"{wall_tag} · {use} · seam {sj:.3f} · {port_tag}"
    return {
        'label': label, 'sub': sub, 'edgeBp': round(t['edgeBp'], 3),
        'rows': stride(t['series']['rows']),
        'density': stride(t['series']['density'], 1300),
        'metrics': m, 'ok': t.get('ok', False), 'portable': portable,
    }

bsplines = {}
# Hyper tips (own walls)
bsplines['hyper'] = pack('hyper', w1, *REGIME_META['hyper'], 'W=±1 · ncp=' + str(w1['shared']['ncp']))
bsplines['hyper05'] = pack('hyper05', w05, *REGIME_META['hyper05'], 'W=±0.5 · ncp=' + str(w05['shared']['ncp']))
# Core + skew + pin on shared W=5
for key in ['flat', 'plateau', 'meso', 'lepto', 'platy', 'skew_L', 'skew_R', 'pin_M', 'pin_M_tight', 'pin_M_wide']:
    label, use = REGIME_META[key]
    bsplines[key] = pack(key, w5, label, use, f"W=±5 · ncp={ncp} · h={h}")

DATA = {
    'L': S['L'],
    'profileKeys': PROFILE_KEYS,
    'profiles': {key: series_for(key) for key in PROFILE_KEYS},
    'curves': curves,
    'bsplines': bsplines,
    'bsplineFc': B.get('fc', {}),
    'shared': {
        'ncp': ncp, 'knots': nk, 'hBp': h, 'allClear': w5['shared']['allNineClear'], 'W': 5,
        'hyperW1': {'ncp': w1['shared']['ncp'], 'peakX': port.get('hyperPeakW1'), 'ok': port.get('hyperClearW1')},
        'hyperW05': {'ncp': w05['shared']['ncp'], 'peakX': port.get('hyperPeakW05'), 'ok': port.get('hyperClearW05')},
        'solPort': port.get('solPort'), 'note': port.get('note'),
        'wallLadder': G.get('wallLadder'), 'portableMatrix': G.get('portableMatrix'),
        'curveBasis': (G.get('hyper') or {}).get('curveBasis'),
    },
}
html = open(os.path.join(HERE, 'spline_template.html')).read().replace('/*__DATA__*/', json.dumps(DATA))
open(os.path.join(HERE, 'out', 'spline_ui.html'), 'w').write(html)
print(f"wrote out/spline_ui.html  shared_ncp={ncp} regimes={list(bsplines)} port={port.get('solPort')}")
