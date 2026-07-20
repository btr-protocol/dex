#!/usr/bin/env python3
"""Render per-regime liquidity-concentration charts (density = $depth per bp of offset) for the
default (regime, wall) presets, straight from the fitted objects in out/spline_shared_grid.json.
Emits self-contained SVGs into ../../../docs/assets/dex/spline/ for the Liquidity Shaping page.

Concentration = d(cumulative depth $)/d(price offset bp): tall near mark = tightly concentrated.
Each panel is normalized to its own peak (shape disclosure); hyper carries the absolute $/bp + xCurve.
"""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
GRID = json.load(open(os.path.join(HERE, "out/spline_shared_grid.json")))
OUT = os.path.abspath(os.path.join(HERE, "../../../docs/assets/dex/spline"))
os.makedirs(OUT, exist_ok=True)

# Panel-verified defaults: regime -> (wall key, wall bp, dispRef pbps, one-line class)
DEFAULTS = [
    ("hyper",   "W0_5", 0.5,  50,  "Tier-1 stables / pegged FX"),
    ("flat",    "W1",   1.0,  100, "Uni-v3 single-range / T-bill band"),
    ("plateau", "W1",   1.0,  100, "Soft-pegs / LST accrual band"),
    ("meso",    "W2",   2.0,  200, "FX crosses / quiet majors"),
    ("lepto",   "W5",   5.0,  500, "Majors + crypto under stress"),
    ("platy",   "W5",   5.0,  500, "Wide FI / low-conviction listings"),
    ("skew_L",  "W5",   5.0,  500, "Downside-fragile (crash skew)"),
    ("skew_R",  "W5",   5.0,  500, "Upside-skew commodity / alt"),
    ("pin_M",   "W5",   5.0,  500, "Options gamma pin (research only)"),
]
ACCENT = {"hyper": "#0b7285", "flat": "#1864ab", "plateau": "#0c8599", "meso": "#2b8a3e",
          "lepto": "#e8590c", "platy": "#5c7cfa", "skew_L": "#9c36b5", "skew_R": "#c2255c",
          "pin_M": "#868e96"}


def density(rows):
    """rows = [[depth_usd_signed, offset_bp], ...] monotone. Returns (offsets_bp, dens_usd_per_bp)."""
    xs, ds = [], []
    for i in range(len(rows) - 1):
        dx = rows[i + 1][0] - rows[i][0]        # depth $ (signed)
        dy = rows[i + 1][1] - rows[i][1]        # offset bp
        if dy == 0:
            continue
        xs.append((rows[i][1] + rows[i + 1][1]) / 2.0)
        ds.append(abs(dx / dy))                  # $ per bp
    return xs, ds


def panel(regime, wallkey, wallbp, cls, W=360, H=240, standalone=True):
    fit = GRID["walls"][wallkey]["presets"][regime]
    xs, ds = density(fit["series"]["rows"])
    peak = max(ds) if ds else 1.0
    pad_l, pad_r, pad_t, pad_b = 44, 14, 34, 40
    pw, ph = W - pad_l - pad_r, H - pad_t - pad_b
    xmax = wallbp
    ac = ACCENT[regime]

    def px(o): return pad_l + (o + xmax) / (2 * xmax) * pw
    def py(v): return pad_t + ph - (v / peak) * ph

    # area path under the density curve
    pts = [(px(o), py(d)) for o, d in zip(xs, ds) if -xmax <= o <= xmax]
    if not pts:
        pts = [(pad_l, pad_t + ph), (pad_l + pw, pad_t + ph)]
    area = f"M{pts[0][0]:.1f},{pad_t+ph:.1f} " + " ".join(f"L{x:.1f},{y:.1f}" for x, y in pts) + \
           f" L{pts[-1][0]:.1f},{pad_t+ph:.1f} Z"
    line = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts)

    # mark line at offset 0
    mx = px(0)
    metrics = fit.get("metrics", {})
    peakusd = metrics.get("peakUsdPerBp")
    over = metrics.get("peakOverCurve")
    subt = f"peak {peakusd/1e6:.0f} $M/bp" + (f"  ({over:.1f}x Curve A4000)" if over else "") \
        if peakusd else ""

    svg = []
    if standalone:
        svg.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" '
                   f'font-family="ui-sans-serif,system-ui,sans-serif">')
    svg.append(f'<rect x="0" y="0" width="{W}" height="{H}" fill="#ffffff"/>')
    # axes
    svg.append(f'<line x1="{pad_l}" y1="{pad_t+ph}" x2="{pad_l+pw}" y2="{pad_t+ph}" stroke="#adb5bd" stroke-width="1"/>')
    svg.append(f'<line x1="{pad_l}" y1="{pad_t}" x2="{pad_l}" y2="{pad_t+ph}" stroke="#adb5bd" stroke-width="1"/>')
    # mark reference
    svg.append(f'<line x1="{mx:.1f}" y1="{pad_t}" x2="{mx:.1f}" y2="{pad_t+ph}" stroke="#ced4da" stroke-width="1" stroke-dasharray="3 3"/>')
    # density fill + line
    svg.append(f'<path d="{area}" fill="{ac}" fill-opacity="0.18"/>')
    svg.append(f'<path d="{line}" fill="none" stroke="{ac}" stroke-width="2"/>')
    # title + subtitle
    svg.append(f'<text x="{pad_l}" y="18" font-size="14" font-weight="600" fill="#212529">{regime}  '
               f'<tspan font-weight="400" fill="#868e96">W={wallbp:g}bp</tspan></text>')
    if subt:
        svg.append(f'<text x="{pad_l}" y="{H-6}" font-size="10.5" fill="#868e96">{subt}</text>')
    # axis labels
    svg.append(f'<text x="{pad_l+pw}" y="{pad_t+ph+14}" font-size="10" text-anchor="end" fill="#868e96">+{wallbp:g}</text>')
    svg.append(f'<text x="{pad_l}" y="{pad_t+ph+14}" font-size="10" text-anchor="start" fill="#868e96">-{wallbp:g}</text>')
    svg.append(f'<text x="{mx:.1f}" y="{pad_t+ph+14}" font-size="10" text-anchor="middle" fill="#868e96">mark (bp)</text>')
    svg.append(f'<text x="6" y="{pad_t+10}" font-size="9.5" fill="#868e96" transform="rotate(0)">$/bp</text>')
    if standalone:
        svg.append('</svg>')
    return "\n".join(svg), (subt or cls)


# individual panels
for regime, wk, wbp, disp, cls in DEFAULTS:
    body, _ = panel(regime, wk, wbp, cls, standalone=True)
    open(os.path.join(OUT, f"regime-{regime}.svg"), "w").write(body)

# combined 3x3 hero
CW, CH = 360, 240
cols, rows_n = 3, 3
GW, GH = CW * cols, CH * rows_n + 30
parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {GW} {GH}" '
         f'font-family="ui-sans-serif,system-ui,sans-serif">',
         f'<rect x="0" y="0" width="{GW}" height="{GH}" fill="#ffffff"/>',
         f'<text x="12" y="20" font-size="15" font-weight="700" fill="#212529">'
         f'Default liquidity concentration by regime '
         f'<tspan font-weight="400" fill="#868e96">(density = $ depth per bp of offset from mark, normalized per panel)</tspan></text>']
for i, (regime, wk, wbp, disp, cls) in enumerate(DEFAULTS):
    r, c = divmod(i, cols)
    x0, y0 = c * CW, 30 + r * CH
    body, _ = panel(regime, wk, wbp, cls, standalone=False)
    parts.append(f'<g transform="translate({x0},{y0})">{body}</g>')
parts.append('</svg>')
open(os.path.join(OUT, "regimes-overview.svg"), "w").write("\n".join(parts))

print("wrote", len(DEFAULTS) + 1, "SVGs to", OUT)
for regime, wk, wbp, disp, cls in DEFAULTS:
    m = GRID["walls"][wk]["presets"][regime].get("metrics", {})
    print(f"  {regime:8s} W{wbp:<4g} dispRef={disp:<4d} peak={m.get('peakUsdPerBp',0)/1e6:7.1f}$M/bp "
          f"over={m.get('peakOverCurve','-')}")
