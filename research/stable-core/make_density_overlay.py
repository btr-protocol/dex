#!/usr/bin/env python3
"""make_density_overlay.py — OBSERVED return density vs FITTED I-spline preset
density, per testnet asset, for operator fit-vs-observed validation.

OBSERVED  = histogram of 2-week per-bar log-returns (bp) from the REAL tape
            (NXR /v1/ohlc JSON or local nxr-sdk .bars), cleaned of synthetic-cross
            glitches.
FITTED    = the assigned preset's marginal liquidity density (dy/dx of the offset
            I-spline) from out/spline_shared_grid.json, rescaled to the observed
            characteristic width (std-match) so the SHAPE archetype is comparable
            on one bp axis. Presets bracket observed density, not overfit tails.

Reproducible: `python3 make_density_overlay.py` -> out/density_overlay.html
Embeds only precomputed bins (no raw tapes).
"""
import json, os, struct, math
from pathlib import Path

HERE = Path(__file__).parent
GRID = json.load(open(HERE / "out" / "spline_shared_grid.json"))
OHLC = HERE / "data" / "nxr_ohlc"
BARS = HERE.parent.parent / "research" / "data" / "fine"   # dex/research/data/fine

WALLKEY = {0.5: "W0_5", 1: "W1", 2: "W2", 5: "W5"}

# ── per-asset config: (regime, W, dispRef, minDisp, minFee, clip_bp, tape spec) ──
# tape: ("json", filename) reads NXR OHLC dicts; ("bars", filename) reads mitch::Bar
# 96B records (close f64 @off36, tick_count u32 @off52). pxlo/pxhi = clean price window.
# Stats (rvol/kurt/tailA/b95/b99/skew/pegMaxDev) = canonical measured values from
# RISK_PARAMS_TESTNET.md §3/§4 (density-of-record), shown alongside the recomputed hist.
A = [
 dict(sym="USDC", regime="plateau", W=1, dispRef=100, minDisp=200, minFee=50, pool="stable",
      clip=100, tape=None,
      st=dict(bars="0 (identity)", rvol=0, kurt=None, tailA=None, b95=0, b99=0, skew=None, peg=0)),
 dict(sym="USDT", regime="hyper", W=0.5, dispRef=50, minDisp=600, minFee=50, pool="stable",
      clip=100, tape=("json", "USDT-USDC.json"),
      st=dict(bars="16345x60s", rvol=19.08, kurt=4.42, tailA=3.45, b95=3.02, b99=4.58, skew=-0.037, peg=13.35)),
 dict(sym="USD1", regime="plateau", W=1, dispRef=100, minDisp=500, minFee=50, pool="stable",
      clip=100, tape=("json", "USD1-USDC.json"),
      st=dict(bars="3939x300s", rvol=16.33, kurt=39.94, tailA=1.877, b95=1.502, b99=3.422, skew=0.111, peg=15.87)),
 dict(sym="USDE", regime="plateau", W=2, dispRef=200, minDisp=800, minFee=75, pool="stable",
      clip=100, tape=("json", "USDE-USDC.json"),
      st=dict(bars="19443x60s", rvol=49.29, kurt=50.29, tailA=3.21, b95=1.9, b99=6.65, skew=-0.027, peg=25.2)),
 dict(sym="FDUSD", regime="plateau", W=1, dispRef=100, minDisp=1000, minFee=100, pool="stable",
      clip=100, tape=("json", "FDUSD-USDC.json"),
      st=dict(bars="19749x60s", rvol=19.02, kurt=12.93, tailA=3.18, b95=1.05, b99=1.75, skew=-0.042, peg=34.36)),
 dict(sym="BTC", regime="lepto", W=5, dispRef=500, minDisp=50000, minFee=1000, pool="volatile",
      clip=150, tape=("bars", "BTC-USDT.bars"),
      st=dict(bars="120960x10s", rvol=227.03, kurt=252.2, tailA=2.71, b95=5.8, b99=10.62, skew=0.13, peg=None)),
 dict(sym="ETH", regime="lepto", W=5, dispRef=500, minDisp=50000, minFee=1000, pool="volatile",
      clip=150, tape=("bars", "ETH-USDT.bars"),
      st=dict(bars="18644x60s / 120960x10s", rvol=237, kurt=43, tailA=2.75, b95=12.5, b99=22.1, skew=1.43, peg=0)),
 dict(sym="BNB", regime="lepto", W=5, dispRef=500, minDisp=50000, minFee=1000, pool="volatile",
      clip=150, tape=("bars", "BNB-USDT.bars"),
      st=dict(bars="120960x10s", rvol=290.1, kurt=17.4, tailA=3.1, b95=5.6, b99=9.4, skew=-0.02, peg=0)),
 dict(sym="CAKE", regime="platy", W=5, dispRef=500, minDisp=50000, minFee=1000, pool="volatile",
      clip=500, tape=("json", "CAKE-USDC.json"),
      st=dict(bars="3614x300s", rvol=514.5, kurt=36.2, tailA=2.96, b95=37.8, b99=61.7, skew=-0.44, peg=None)),
 dict(sym="XAUT", regime="meso", W=2, dispRef=200, minDisp=50000, minFee=1000, pool="volatile",
      clip=500, tape=("json", "XAUT-USDC.json"), pxlo=3500, pxhi=4400,
      st=dict(bars="15102x60s (clean subset)", rvol=118, kurt=34.6, tailA=2.0, b95=17.5, b99=41.3, skew=0.15, peg=0)),
]

def read_closes(spec, pxlo=None, pxhi=None):
    kind, fn = spec
    closes, tcs = [], []
    if kind == "json":
        for r in json.load(open(OHLC / fn)):
            closes.append(r["close"]); tcs.append(r.get("tick_count", 1))
    else:
        buf = open(BARS / fn, "rb").read()
        for o in range(0, len(buf) - 95, 96):
            closes.append(struct.unpack_from("<d", buf, o + 36)[0])
            tcs.append(struct.unpack_from("<I", buf, o + 52)[0])
    return closes, tcs

def log_returns_bp(closes, tcs, clip, pxlo=None, pxhi=None):
    """per-bar log-returns in bp, real-print endpoints only, glitch-clipped."""
    out = []
    for i in range(1, len(closes)):
        c0, c1 = closes[i - 1], closes[i]
        t0, t1 = tcs[i - 1], tcs[i]
        if c0 <= 0 or c1 <= 0: continue
        if t0 == 0 or t1 == 0: continue              # skip carried-forward (no real print)
        if pxlo is not None and not (pxlo < c0 < pxhi and pxlo < c1 < pxhi): continue
        r = 1e4 * math.log(c1 / c0)
        if abs(r) > clip: continue                    # drop synthetic-cross wick
        out.append(r)
    return out

def quantile(sorted_x, q):
    if not sorted_x: return 0.0
    i = q * (len(sorted_x) - 1); lo = int(i); frac = i - lo
    return sorted_x[lo] if lo + 1 >= len(sorted_x) else sorted_x[lo] * (1 - frac) + sorted_x[lo + 1] * frac

def moments(x):
    n = len(x)
    if n < 2: return 0.0, 0.0
    m = sum(x) / n
    v = sum((t - m) ** 2 for t in x) / n
    s = math.sqrt(v) or 1e-9
    k = sum((t - m) ** 4 for t in x) / n / v ** 2 - 3.0
    return s, k

def hist(x, xr, nb=81):
    """density-normalized histogram over [-xr,xr]; returns polyline + tail frac."""
    if not x: return [], 0.0
    bw = 2 * xr / nb; n = len(x); cnt = [0] * nb; outside = 0
    for t in x:
        if -xr <= t <= xr:
            b = min(nb - 1, int((t + xr) / bw)); cnt[b] += 1
        else: outside += 1
    return ([[round(-xr + (b + 0.5) * bw, 4), cnt[b] / (n * bw)] for b in range(nb)],
            outside / n)

def template(regime, W):
    """assigned preset density -> pdf f(o), std_fit, excess kurt."""
    dens = GRID["walls"][WALLKEY[W]]["presets"][regime]["series"]["density"]
    xs = [d[0] for d in dens]; ys = [max(d[1], 0.0) for d in dens]
    area = 0.0
    for i in range(1, len(xs)):
        area += 0.5 * (ys[i] + ys[i - 1]) * (xs[i] - xs[i - 1])
    f = [y / area for y in ys]                          # pdf over offset
    mean = sum(0.5 * (xs[i] * f[i] + xs[i - 1] * f[i - 1]) * (xs[i] - xs[i - 1]) for i in range(1, len(xs)))
    var = sum(0.5 * ((xs[i] - mean) ** 2 * f[i] + (xs[i - 1] - mean) ** 2 * f[i - 1]) * (xs[i] - xs[i - 1]) for i in range(1, len(xs)))
    m4 = sum(0.5 * ((xs[i] - mean) ** 4 * f[i] + (xs[i - 1] - mean) ** 4 * f[i - 1]) * (xs[i] - xs[i - 1]) for i in range(1, len(xs)))
    std = math.sqrt(var) or 1e-9
    return xs, f, std, m4 / var ** 2 - 3.0

def stride(a, tgt=180):
    n = len(a)
    return a if n <= tgt else [a[round(i * (n - 1) / (tgt - 1))] for i in range(tgt)]

# archetype tail class for verdict (thin=box/gaussian, fat=peaked heavy tail)
THIN = {"plateau", "meso", "platy", "flat"}

def verdict(cfg, obs_kurt, obs_b99, wphys):
    """archetype fit + wall containment -> (tag, caption)."""
    ok = cfg["st"]["kurt"]
    if ok is None:  # USDC
        return "n/a", "Degenerate identity spike at 0 (price=1 by construction). Plateau W1 is the tightest legal un-walled peg shape; no tape to match."
    obs_fat = ok >= 6.0
    thin_preset = cfg["regime"] in THIN
    contain = obs_b99 <= wphys
    cmargin = wphys / obs_b99 if obs_b99 else 99
    # peaked presets (hyper) intentionally tighter than data; box presets (plateau)
    # intentionally thinner-tailed -> "bracket not fit". Mismatch only when a THIN
    # bell/dome preset (meso/platy) sits on a clearly FAT tape.
    if cfg["regime"] in ("meso", "platy") and obs_fat and ok >= 20:
        tag = "mismatch"
        cap = f"Observed density is strongly leptokurtic (excess kurt {ok}, tail-alpha {cfg['st']['tailA']}); the {cfg['regime']} archetype is a thin-tailed {'bell' if cfg['regime']=='meso' else 'broad dome'}. Shape DIVERGES: a lepto W5 preset fits the observed tail. "
    elif cfg["regime"] == "lepto" and obs_fat:
        tag = "good"
        cap = f"Observed fat-tailed core (excess kurt {ok}, tail-alpha {cfg['st']['tailA']}) TRACKS the lepto Student-t archetype. Wall W{cfg['W']} brackets b99 {obs_b99:.1f}bp with {cmargin:.0f}x margin. "
    elif cfg["regime"] == "hyper":
        tag = "good"
        cap = f"Mildly super-Gaussian core (excess kurt {ok}, tail-alpha {cfg['st']['tailA']}, finite variance) suits the needle-at-mark hyper archetype; the template concentrates tighter than the tape by design (liquidity at mark, wall behind it). Wall {wphys:.0f}bp brackets b99 {obs_b99:.1f}bp. "
    else:  # plateau on stables
        if obs_fat:
            tag = "loose"
            cap = f"Observed core is peaked/fat (excess kurt {ok}, tail-alpha {cfg['st']['tailA']}) while the plateau archetype is a box+soft-rolloff. Deliberate bracket-not-fit: the soft rolloff absorbs the rare jump the tail vetoed hyper from pricing. Wall {wphys:.0f}bp contains b99 {obs_b99:.1f}bp. "
        else:
            tag = "good"
            cap = f"Plateau box+rolloff sits over the observed core; wall {wphys:.0f}bp brackets b99 {obs_b99:.1f}bp. "
    if not contain:
        tag = "mismatch"
        cap += f"WALL TOO TIGHT: observed b99 {obs_b99:.1f}bp exceeds the min-disp wall {wphys:.0f}bp. "
    elif cmargin < 1.3 and tag == "good":
        cap += f"Containment margin thin ({cmargin:.1f}x): watch. "
    return tag, cap

# ── build per-asset payload ──
panels = []; summary = []
for cfg in A:
    reg, W = cfg["regime"], cfg["W"]
    wphys = W * cfg["minDisp"] / cfg["dispRef"]                 # tightest deployed wall, bp
    fxs, ff, fstd, fkurt = template(reg, W)
    if cfg["tape"] is None:                                     # USDC identity
        xr = max(2.0, wphys)
        obs = [[-0.02, 0], [0, 60], [0.02, 0]]                  # visual delta spike
        obs_std, obs_kurt, obs_b99, tail = 0.0, 0.0, 0.0, 0.0
    else:
        closes, tcs = read_closes(cfg["tape"], cfg.get("pxlo"), cfg.get("pxhi"))
        rets = log_returns_bp(closes, tcs, cfg["clip"], cfg.get("pxlo"), cfg.get("pxhi"))
        ar = sorted(abs(t) for t in rets)
        obs_std, obs_kurt = moments(rets)
        obs_b99 = quantile(ar, 0.99)
        xr = round(max(1.25 * obs_b99, 3 * obs_std, 1.0), 2)
        obs, tail = hist(rets, xr)
    # fitted: rescale template std -> observed std (or template's own if obs degenerate)
    sc = (obs_std / fstd) if obs_std > 1e-6 else (xr / (fxs[-1] or 1))
    fit = [[round(x * sc, 4), y] for x, y in zip(fxs, ff)]
    fit = [p for p in fit if -xr * 1.02 <= p[0] <= xr * 1.02]
    # renormalize fitted to unit area on the display window so peaks compare
    fa = 0.0
    for i in range(1, len(fit)):
        fa += 0.5 * (fit[i][1] + fit[i - 1][1]) * (fit[i][0] - fit[i - 1][0])
    if fa > 0: fit = [[x, round(y / fa, 5)] for x, y in fit]
    obs = [[x, round(y, 5)] for x, y in obs]
    tag, cap = verdict(cfg, obs_kurt, obs_b99 if cfg["tape"] else 0, wphys)
    panels.append(dict(sym=cfg["sym"], regime=reg, W=W, dispRef=cfg["dispRef"],
                       minFee=cfg["minFee"], pool=cfg["pool"], wphys=round(wphys, 1),
                       st=cfg["st"], obsKurtTape=round(obs_kurt, 1), obsB99Tape=round(obs_b99, 2),
                       tmplKurt=round(fkurt, 1), xr=xr, tailFrac=round(tail, 4),
                       obs=stride(obs, 90), fit=stride(fit, 160), tag=tag, cap=cap))
    summary.append((cfg["sym"], reg, f"W{W}", cfg["st"]["kurt"], round(fkurt, 1),
                    obs_b99 if cfg["tape"] else 0, round(wphys, 1), tag))

DATA = {"panels": panels, "gen": "make_density_overlay.py"}

# ── palette lifted from spline_template.html ──
CSS = """
:root{--bg:#f4f7f8;--panel:#fff;--panel2:#eef2f4;--ink:#0d1218;--mut:#5a6672;
--line:rgba(12,26,36,.11);--hair:rgba(12,26,36,.06);--acc:#0f8d7a;
--obs:#3ea6c2;--fit:#d68a2e;--wall:#d43f5c;--good:#1f9e5a;--loose:#c98a1e;--miss:#d43f5c;
--shadow:0 1px 0 rgba(12,26,36,.04),0 12px 30px -18px rgba(12,26,36,.30);}
@media(prefers-color-scheme:dark){:root{--bg:#080b10;--panel:#0f151e;--panel2:#0c1119;--ink:#e7eef4;--mut:#7a8797;
--line:rgba(255,255,255,.11);--hair:rgba(255,255,255,.06);--acc:#35d0b6;
--obs:#6cc9e6;--fit:#eba851;--wall:#ee6a83;--good:#5cd88f;--loose:#e2ab3d;--miss:#ee6a83;
--shadow:0 1px 0 rgba(0,0,0,.4),0 18px 40px -20px rgba(0,0,0,.7);}}
:root[data-theme="dark"]{--bg:#080b10;--panel:#0f151e;--panel2:#0c1119;--ink:#e7eef4;--mut:#7a8797;
--line:rgba(255,255,255,.11);--hair:rgba(255,255,255,.06);--acc:#35d0b6;
--obs:#6cc9e6;--fit:#eba851;--wall:#ee6a83;--good:#5cd88f;--loose:#e2ab3d;--miss:#ee6a83;}
:root[data-theme="light"]{--bg:#f4f7f8;--panel:#fff;--panel2:#eef2f4;--ink:#0d1218;--mut:#5a6672;
--line:rgba(12,26,36,.11);--hair:rgba(12,26,36,.06);--acc:#0f8d7a;
--obs:#3ea6c2;--fit:#d68a2e;--wall:#d43f5c;--good:#1f9e5a;--loose:#c98a1e;--miss:#d43f5c;}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
-webkit-font-smoothing:antialiased;padding:clamp(14px,3vw,40px);}
.wrap{max-width:1180px;margin:0 auto;display:flex;flex-direction:column;gap:18px;}
.mono{font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace;font-variant-numeric:tabular-nums;}
.eyebrow{font-family:ui-monospace,monospace;font-size:11px;letter-spacing:.16em;text-transform:uppercase;color:var(--acc);}
h1{font-size:clamp(21px,3.3vw,30px);line-height:1.12;margin:.24em 0 0;font-weight:650;letter-spacing:-.01em;}
.lede{color:var(--mut);max-width:80ch;margin:8px 0 0;font-size:14.5px;}
.lede b{color:var(--ink);}
.legend-top{display:flex;gap:18px;flex-wrap:wrap;margin-top:10px;font-family:ui-monospace,monospace;font-size:12px;color:var(--mut);}
.legend-top span{display:inline-flex;align-items:center;gap:7px;}
.sw{width:20px;height:0;border-top-width:3px;border-top-style:solid;border-radius:2px;}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:16px;}
@media(max-width:860px){.grid2{grid-template-columns:1fr;}}
.card{background:var(--panel);border:1px solid var(--line);border-radius:14px;box-shadow:var(--shadow);padding:14px 16px 12px;}
.ch-head{display:flex;justify-content:space-between;align-items:baseline;gap:10px;flex-wrap:wrap;margin:0 2px 6px;}
.ch-head h2{font-size:15px;margin:0;font-weight:650;letter-spacing:-.01em;}
.ch-head h2 .reg{color:var(--acc);font-family:ui-monospace,monospace;font-size:12px;font-weight:600;margin-left:6px;}
.badge{font-family:ui-monospace,monospace;font-size:10.5px;font-weight:700;letter-spacing:.05em;text-transform:uppercase;
padding:3px 9px;border-radius:999px;}
.badge.good{color:#fff;background:var(--good);} .badge.loose{color:#1a1200;background:var(--loose);}
.badge.mismatch{color:#fff;background:var(--miss);} .badge.na{color:var(--mut);background:var(--panel2);}
.canvas-box{position:relative;width:100%;aspect-ratio:16/9;min-height:190px;}
canvas{position:absolute;inset:0;width:100%;height:100%;}
.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:2px 12px;margin:8px 2px 0;
font-family:ui-monospace,monospace;font-size:11.5px;}
.stats div{display:flex;justify-content:space-between;gap:8px;border-bottom:1px solid var(--hair);padding:2px 0;}
.stats .k{color:var(--mut);} .stats .v{font-weight:650;}
.cap{color:var(--mut);font-size:12px;line-height:1.5;margin:9px 2px 0;max-width:60ch;}
.cap b{color:var(--ink);}
.notes{color:var(--mut);font-size:13px;line-height:1.6;padding:4px 4px 0;}
.notes b{color:var(--ink);}
table.sum{width:100%;border-collapse:collapse;font-family:ui-monospace,monospace;font-size:12px;margin-top:6px;}
table.sum th,table.sum td{text-align:right;padding:6px 8px;border-bottom:1px solid var(--hair);white-space:nowrap;}
table.sum th{color:var(--mut);font-weight:500;font-size:10px;letter-spacing:.05em;text-transform:uppercase;}
table.sum td:first-child,table.sum th:first-child{text-align:left;}
.pill{font-weight:700;padding:1px 7px;border-radius:6px;font-size:11px;}
.pill.good{color:var(--good);} .pill.loose{color:var(--loose);} .pill.mismatch{color:var(--miss);} .pill.na{color:var(--mut);}
.foot{color:var(--mut);font-family:ui-monospace,monospace;font-size:11px;text-align:center;padding:6px 0;}
"""

def fmt(v):
    return "n/a" if v is None else (f"{v:g}" if isinstance(v, (int, float)) else str(v))

sum_rows = "".join(
    f"<tr><td>{s}</td><td>{r}</td><td>{w}</td><td>{fmt(ok)}</td><td>{tk}</td>"
    f"<td>{b99:g}</td><td>{wp:g}</td><td><span class='pill {tg}'>{tg}</span></td></tr>"
    for s, r, w, ok, tk, b99, wp, tg in summary)

HTML = f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>BTR AIMM — Observed vs Fitted density per asset</title>
<style>{CSS}</style></head><body>
<div class="wrap">
 <header>
  <div class="eyebrow">BTR AIMM · testnet preset validation · observed tape vs fitted I-spline</div>
  <h1>Observed price density vs fitted bonding-curve density</h1>
  <p class="lede">Per asset: the <b>observed</b> 2-week per-bar log-return density (real NXR /v1/ohlc + local nxr-sdk tapes,
  glitch-cleaned) overlaid on the <b>fitted</b> liquidity density of the asset's assigned quartic-I-spline preset
  (<span class="mono">out/spline_shared_grid.json</span>). The fitted template is std-matched to the observed core so the
  <b>shape archetype</b> is comparable on one bp axis. Presets are chosen to <b>bracket</b> observed density and place the
  wall above the observed 99% move: this is a shape/archetype check, <b>not a pdf fit</b> (a preset is deliberately
  thinner-tailed than the tape, so liquidity is not parked in the fat tail).</p>
  <div class="legend-top">
   <span><span class="sw" style="border-color:var(--obs)"></span>observed return density (real tape)</span>
   <span><span class="sw" style="border-color:var(--fit)"></span>fitted preset density (std-matched)</span>
   <span><span class="sw" style="border-color:var(--wall)"></span>min-disp wall (bp)</span>
  </div>
 </header>

 <div class="grid2" id="panels"></div>

 <section class="card">
  <div class="notes"><b>Fit-vs-observed summary.</b> <span class="mono">kurt</span> = observed excess kurtosis
  (density-of-record, RISK_PARAMS §3/§4); <span class="mono">tmpl κ</span> = fitted preset's own excess kurtosis;
  <span class="mono">b99</span> = observed 99% single-bar move (bp); <span class="mono">wall</span> = tightest deployed
  wall W·minDisp/dispRef (bp). Verdict: <b>good</b> = archetype tracks + wall brackets; <b>loose</b> = deliberate
  bracket-not-fit (thinner preset over a fat but walled stable core); <b>mismatch</b> = thin bell/dome preset on a
  clearly fat tape, or wall fails to contain b99.</div>
  <table class="sum"><thead><tr><th>asset</th><th>regime</th><th>W</th><th>obs kurt</th><th>tmpl κ</th>
  <th>b99 bp</th><th>wall bp</th><th>verdict</th></tr></thead><tbody>{sum_rows}</tbody></table>
 </section>
 <div class="foot">generated by make_density_overlay.py · data: NXR /v1/ohlc (USDT/USD1/USDE/FDUSD/CAKE/XAUT) + nxr-sdk .bars (BTC/ETH/BNB) · presets: out/spline_shared_grid.json</div>
</div>
<script>
const DATA={json.dumps(DATA)};
const css=k=>getComputedStyle(document.documentElement).getPropertyValue(k).trim();
function draw(cv,p){{
 const dpr=Math.max(1,window.devicePixelRatio||1),W=cv.clientWidth,H=cv.clientHeight;
 cv.width=W*dpr;cv.height=H*dpr;const g=cv.getContext('2d');g.setTransform(dpr,0,0,dpr,0,0);g.clearRect(0,0,W,H);
 const mL=8,mR=8,mT=10,mB=22,pw=W-mL-mR,ph=H-mT-mB,xr=p.xr;
 let ymax=0;for(const a of[p.obs,p.fit])for(const d of a)if(d[1]>ymax)ymax=d[1];ymax*=1.12||1;
 const X=x=>mL+(x+xr)/(2*xr)*pw, Y=y=>mT+ph-(y/ymax)*ph;
 // grid: zero line + x ticks
 g.strokeStyle=css('--hair');g.lineWidth=1;
 g.beginPath();g.moveTo(X(0),mT);g.lineTo(X(0),mT+ph);g.stroke();
 g.fillStyle=css('--mut');g.font='10px ui-monospace,monospace';g.textAlign='center';
 for(const t of[-xr,-xr/2,0,xr/2,xr]){{g.fillText((t>0?'+':'')+ (Math.abs(xr)<3?t.toFixed(2):t.toFixed(0)),X(t),H-7);}}
 g.textAlign='left';g.fillText('offset bp',mL+2,H-7);
 // min-disp wall markers (if on-scale)
 for(const s of[-1,1]){{const wx=s*p.wphys;if(Math.abs(wx)<=xr){{g.strokeStyle=css('--wall');g.setLineDash([4,3]);
  g.beginPath();g.moveTo(X(wx),mT);g.lineTo(X(wx),mT+ph);g.stroke();g.setLineDash([]);}}}}
 // filled area helper
 function area(arr,col,fillA){{if(!arr.length)return;g.beginPath();g.moveTo(X(arr[0][0]),Y(0));
  for(const d of arr)g.lineTo(X(d[0]),Y(d[1]));g.lineTo(X(arr[arr.length-1][0]),Y(0));g.closePath();
  g.globalAlpha=fillA;g.fillStyle=col;g.fill();g.globalAlpha=1;
  g.beginPath();arr.forEach((d,i)=>i?g.lineTo(X(d[0]),Y(d[1])):g.moveTo(X(d[0]),Y(d[1])));
  g.strokeStyle=col;g.lineWidth=2;g.stroke();}}
 area(p.fit,css('--fit'),.10);
 area(p.obs,css('--obs'),.20);
}}
const box=document.getElementById('panels');
for(const p of DATA.panels){{
 const c=document.createElement('div');c.className='card';
 const st=p.st, tail=p.tailFrac>0?`<div><span class="k">tail&gt;win</span><span class="v">${{(p.tailFrac*100).toFixed(1)}}%</span></div>`:'';
 c.innerHTML=`<div class="ch-head"><h2>${{p.sym}}<span class="reg">${{p.regime}} · W${{p.W}} · dispRef ${{p.dispRef}}</span></h2>
   <span class="badge ${{p.tag}}">${{p.tag}}</span></div>
  <div class="canvas-box"><canvas></canvas></div>
  <div class="stats">
   <div><span class="k">rvol bp/d</span><span class="v">${{st.rvol}}</span></div>
   <div><span class="k">kurt</span><span class="v">${{st.kurt==null?'n/a':st.kurt}}</span></div>
   <div><span class="k">tail-a</span><span class="v">${{st.tailA==null?'n/a':st.tailA}}</span></div>
   <div><span class="k">skew</span><span class="v">${{st.skew==null?'n/a':st.skew}}</span></div>
   <div><span class="k">b95 bp</span><span class="v">${{st.b95}}</span></div>
   <div><span class="k">b99 bp</span><span class="v">${{st.b99}}</span></div>
   <div><span class="k">minFee</span><span class="v">${{p.minFee}}p</span></div>
   <div><span class="k">wall bp</span><span class="v">${{p.wphys}}</span></div>
   <div><span class="k">tmpl κ</span><span class="v">${{p.tmplKurt}}</span></div>
   <div><span class="k">bars</span><span class="v" style="font-size:10px">${{st.bars}}</span></div>
   <div><span class="k">pegMaxDev</span><span class="v">${{st.peg==null?'n/a':st.peg}}</span></div>
   ${{tail}}
  </div>
  <div class="cap">${{p.cap}}</div>`;
 box.appendChild(c);
 const cv=c.querySelector('canvas');
 requestAnimationFrame(()=>draw(cv,p));
 new ResizeObserver(()=>draw(cv,p)).observe(cv.parentElement);
}}
new MutationObserver(()=>document.querySelectorAll('canvas').forEach((cv,i)=>draw(cv,DATA.panels[i])))
 .observe(document.documentElement,{{attributes:true,attributeFilter:['data-theme']}});
</script>
</body></html>"""

out = HERE / "out" / "density_overlay.html"
out.write_text(HTML)
print(f"wrote {out}  ({len(HTML)} bytes)")
print("verdicts:", [(s[0], s[-1]) for s in summary])
