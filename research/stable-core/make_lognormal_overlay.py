#!/usr/bin/env python3
"""make_lognormal_overlay.py: central-normal PLATEAU density overlay for the full Sepolia roster
-> out/density_overlay_lognormal.html (overwrite, unstaged).

ONE final shape for BOTH pool classes: signed offset ~ N(0, sigma_g) truncated at the empirical
q70 (30% cut), rendered by the m=3 NUQuartic preset (2 interior knots at u={0.1314,0.8686} = +-0.7
sigma). Density is flat/max at the mark, rolls to zero at the walls. Classes differ ONLY by width
S_dep. Per asset: observed fee density (faint) vs the fitted plateau (bold) + knot verticals.

Refits each asset inline from its NXR tape (route legs use their underlying: WETH->ETH, WBTC/cbBTC
->BTC). Assets with no usable tape render a no-data panel and are listed at the top. Reuses the
lognormal_fit.py / make_density_overlay.py estimator defs verbatim (single source).
Run: python3 make_lognormal_overlay.py
"""
import json, os
from pathlib import Path
import numpy as np

HERE = Path(__file__).parent
_src = open(HERE / "lognormal_fit.py").read()
exec(compile(_src[:_src.index("# ── run ──")], "lognormal_fit.py[defs]", "exec"))
# in scope: A, components, load_tape, nm_fit, ln_fit, N_DRAWS, SIGMA_CELLS, MINFEE_HARD_PBPS,
#           WHITELIST, FAM_KNOTS, bspline_cols  (+ everything from make_density_overlay defs)

# ── Sepolia display roster: (display sym, A-roster key), stables then volatiles ──────────────
STABLES = [("USDT", "USDT"), ("USDC", "USDC"), ("USDe", "USDE"), ("USDS", "USDS"), ("DAI", "DAI"),
           ("USD1", "USD1"), ("USDG", "USDG"), ("PYUSD", "PYUSD"), ("RLUSD", "RLUSD"),
           ("syrupUSDC", "syrupUSDC"), ("USDf", "USDF"), ("U", "U"), ("GHO", "GHO"),
           ("TUSD", "TUSD"), ("USDtb", "USDTB"), ("FDUSD", "FDUSD"), ("AUSD", "AUSD")]
VOLATILES = [("WETH", "WETH"), ("WBTC", "WBTC"), ("cbBTC", "cbBTC"), ("BNB", "BNB"),
             ("XAUT", "XAUT"), ("PAXG", "PAXG"), ("EURC", "EURC")]
CFG = {c["sym"]: c for c in A}
M = 3                                                # final shape: m=3, 2 interior knots
KNOTS_U_FINAL = FAM_KNOTS["cnplateau"][M]            # [0.1314, 0.8686]

def new_pdf(cell, S):
    """signed density of the m=3 cnplateau preset in bp: f(y)=(du/dy)/S on y=S*B(u).w; knot xs."""
    wl = WHITELIST[("cnplateau", cell, M)]
    u = np.linspace(0.0, 1.0, 4001)
    y = np.clip(bspline_cols(wl["t"], len(wl["w"]), u) @ wl["w"], -1, 1)
    dy = np.gradient(y, u)
    f = np.where(dy > 1e-9, 1.0 / np.maximum(dy, 1e-9), 0.0)
    kx = [float(np.interp(uk, u, y) * S) for uk in KNOTS_U_FINAL]
    return y * S, f / S, kx

def resolve(a_key):
    """effective fit cfg for a display asset: route legs inherit the underlying tape.
    returns (cfg_or_None, reason_if_nodata)."""
    cfg = CFG[a_key]
    if cfg.get("route"):                            # WETH->ETH, WBTC/cbBTC->BTC
        src = CFG[cfg["route"]]
        return dict(sym=a_key, cls=cfg["cls"], tape=src["tape"],
                    fx=src.get("fx"), pxwin=src.get("pxwin")), None
    if cfg.get("defer"):
        return None, {"bad_feed": "NXR feed unusable (corrupt/collision)",
                      "no_data": "no NXR tape history"}.get(cfg["defer"], cfg["defer"])
    if cfg.get("tape") is None:
        return None, "numeraire (identity peg, no offset tape)"
    return cfg, None

_comp = {}
def fit(cfg):
    """cached components -> (th, ell, sig_g, S_dep, cell, minFeePbps)."""
    key = cfg["tape"]
    if key not in _comp:
        _comp[key] = components(cfg)
    c = _comp[key]
    th = c["th"]; R = 2 * th
    rng = np.random.default_rng(7)
    ell = (rng.choice(c["G"], N_DRAWS) + rng.uniform(-th, th, N_DRAWS)
           + R * np.tanh(rng.choice(c["d3"], N_DRAWS, p=c["d3w"]) / R))
    sig_g, S_fit = nm_fit(ell)
    S_dep = max(S_fit, R)
    _, sg, _ = ln_fit(ell)
    cell = float(SIGMA_CELLS[int(np.argmin(np.abs(SIGMA_CELLS - sg)))])
    minFeePbps = max(int(round((2 * th + c["excPrem"]) * 100)), MINFEE_HARD_PBPS[cfg["cls"]])
    return th, ell, sig_g, S_dep, cell, minFeePbps

def panel(disp, a_key, cls):
    cfg, reason = resolve(a_key)
    if cfg is None:
        print(f"{disp:10} NO DATA: {reason}", flush=True)
        return dict(sym=disp, cls=cls, nodata=True, reason=reason)
    th, ell, sig_g, S_dep, cell, minFee = fit(cfg)
    lt = max(0.05, round(float(np.quantile(np.abs(ell), 0.5)), 3))
    xr = float(max(1.2 * S_dep, np.quantile(np.abs(ell), 0.9995)))
    slog = lambda x: np.sign(x) * np.log1p(np.abs(x) / lt)
    sexp = lambda u: np.sign(u) * lt * np.expm1(np.abs(u))
    nb = 121; edges = sexp(np.linspace(-float(slog(xr)), float(slog(xr)), nb + 1))
    H, _ = np.histogram(ell, bins=edges); bwv = np.diff(edges)
    obs = [[round(float(0.5 * (edges[i] + edges[i + 1])), 4),
            round(float(H[i] / (len(ell) * bwv[i])), 5)] for i in range(nb)]
    keep = float(np.mean(np.abs(ell) <= S_dep))
    yb, fb, kx = new_pdf(cell, S_dep)
    new = [[round(float(x), 4), round(float(f * keep), 5)] for x, f in zip(yb, fb)]
    new = new[::max(1, len(new) // 200)]
    cap = (f"&sigma;_g={sig_g:.3f}bp &middot; S_dep={S_dep:.3f}bp &middot; minFee={minFee}pbps "
           f"&middot; knots u={{{KNOTS_U_FINAL[0]:.4f},{KNOTS_U_FINAL[1]:.4f}}}")
    print(f"{disp:10} sig_g={sig_g:.3f} S_dep={S_dep:.3f} minFee={minFee} cell={cell:.2f}", flush=True)
    return dict(sym=disp, cls=cls, nodata=False, obs=obs, new=new, xr=round(xr, 3), lt=lt,
                S=round(S_dep, 4), kx=[round(k, 4) for k in kx], cap=cap)

panels = ([panel(d, k, "stable") for d, k in STABLES]
          + [panel(d, k, "volatile") for d, k in VOLATILES])
nodata = [p["sym"] for p in panels if p["nodata"]]

CSS = open(HERE / "make_density_overlay.py").read()
CSS = CSS[CSS.index('CSS = """') + 9: CSS.index('"""\n\ndef tag_of')]           # reuse v4 palette
CSS += """
.grouphdr{grid-column:1/-1;margin:14px 0 2px;font:600 13px/1.3 ui-sans-serif,system-ui;
 letter-spacing:.04em;text-transform:uppercase;color:var(--mut);}
.nodata{display:flex;align-items:center;justify-content:center;color:var(--mut);
 font:12px ui-monospace,monospace;text-align:center;padding:0 12px;}
"""

DATA = dict(panels=panels)
NDTXT = ("no usable NXR tape: <b>" + ", ".join(nodata) + "</b> (panels shown empty below)"
         if nodata else "")
HTML = f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>BTR AIMM - central-normal plateau density (Sepolia roster)</title>
<style>{CSS}</style></head><body>
<div class="wrap">
 <header>
  <h1>Central-normal plateau: fee density per asset</h1>
  <p class="lede">Signed offset ~ N(0,&sigma;_g) truncated at the empirical q70 (30% cut): density is
  flat/max at the mark, rolls to zero at the walls. Rendered by the m=3 NUQuartic preset (2 interior
  knots at u={{{KNOTS_U_FINAL[0]:.4f},{KNOTS_U_FINAL[1]:.4f}}} = &plusmn;0.7&sigma;, 7 slots: cheapest
  ladder preset, gas-cheap setCurve). Both pool classes share this shape; they differ only by width S_dep.</p>
  {f'<p class="lede">{NDTXT}</p>' if NDTXT else ''}
  <div class="legend-top">
   <span><span class="sw" style="border-color:var(--obs)"></span>observed fee density (seed-7 composite)</span>
   <span><span class="sw" style="border-color:var(--fit)"></span>fitted plateau (m=3 preset)</span>
   <span><span class="sw" style="border-color:var(--fit);opacity:.6"></span>interior knot ticks</span>
   <span><span class="sw" style="border-color:var(--wall)"></span>&plusmn;S_dep walls</span>
  </div>
 </header>
 <div class="grid2" id="panels"></div>
 <div class="foot">generated by make_lognormal_overlay.py &middot; refit inline from NXR tapes (data/nxr_ohlc)</div>
</div>
<script>
const DATA={json.dumps(DATA)};
const css=k=>getComputedStyle(document.documentElement).getPropertyValue(k).trim();
function draw(cv,p){{
 const dpr=Math.max(1,window.devicePixelRatio||1),W=cv.clientWidth,H=cv.clientHeight;
 cv.width=W*dpr;cv.height=H*dpr;const g=cv.getContext('2d');g.setTransform(dpr,0,0,dpr,0,0);g.clearRect(0,0,W,H);
 const mL=8,mR=8,mT=10,mB=22,pw=W-mL-mR,ph=H-mT-mB,xr=p.xr;
 let ymax=0;for(const a of[p.obs,p.new])for(const d of a)if(d[1]>ymax)ymax=d[1];ymax*=1.12||1;
 const lt=p.lt||0.05,T=x=>Math.sign(x)*Math.log1p(Math.abs(x)/lt),tx=T(xr);
 const X=x=>mL+(T(x)+tx)/(2*tx)*pw, Y=y=>mT+ph-(y/ymax)*ph;
 if(p.S>0&&p.S<xr){{g.globalAlpha=.06;g.fillStyle=css('--wall');
  g.fillRect(mL,mT,X(-p.S)-mL,ph);g.fillRect(X(p.S),mT,mL+pw-X(p.S),ph);g.globalAlpha=1;}}
 g.strokeStyle=css('--hair');g.lineWidth=1;
 g.beginPath();g.moveTo(X(0),mT);g.lineTo(X(0),mT+ph);g.stroke();
 const ticks=[0];for(let d=-2;;d++){{const v=Math.pow(10,d);if(v>xr)break;if(v>=lt*1.4)ticks.push(v,-v);}}
 g.fillStyle=css('--mut');g.font='10px ui-monospace,monospace';g.textAlign='center';
 for(const t of ticks){{const a=Math.abs(t);
  g.fillText((t>0?'+':'')+(a>=1||a===0?t.toFixed(0):String(t)),X(t),H-7);
  if(t!==0){{g.strokeStyle=css('--hair');g.beginPath();g.moveTo(X(t),mT+ph-4);g.lineTo(X(t),mT+ph);g.stroke();}}}}
 g.textAlign='right';g.fillText('offset bp · symlog, linear ±'+lt,W-mR-2,mT+10);g.textAlign='left';
 for(const s of[-1,1]){{const wx=s*p.S;if(Math.abs(wx)<=xr){{g.strokeStyle=css('--wall');g.setLineDash([4,3]);
  g.beginPath();g.moveTo(X(wx),mT);g.lineTo(X(wx),mT+ph);g.stroke();g.setLineDash([]);}}}}
 g.font='9px ui-monospace,monospace';g.fillStyle=css('--wall');
 g.fillText('S_dep',Math.min(X(p.S)+3,W-mR-40),mT+20);
 function line(arr,col,fillA,lw){{if(!arr.length)return;
  if(fillA>0){{g.beginPath();g.moveTo(X(arr[0][0]),Y(0));
   for(const d of arr)g.lineTo(X(d[0]),Y(d[1]));g.lineTo(X(arr[arr.length-1][0]),Y(0));g.closePath();
   g.globalAlpha=fillA;g.fillStyle=col;g.fill();g.globalAlpha=1;}}
  g.beginPath();arr.forEach((d,i)=>i?g.lineTo(X(d[0]),Y(d[1])):g.moveTo(X(d[0]),Y(d[1])));
  g.strokeStyle=col;g.lineWidth=lw;g.stroke();}}
 line(p.obs,css('--obs'),.14,1);
 line(p.new,css('--fit'),.12,2.6);
 g.strokeStyle=css('--fit');g.lineWidth=2;
 for(const k of p.kx)for(const s of[1,-1]){{const wx=s*k;if(Math.abs(wx)<=xr){{
  g.beginPath();g.moveTo(X(wx),mT+ph);g.lineTo(X(wx),mT+ph-9);g.stroke();
  g.beginPath();g.arc(X(wx),mT+ph-12,2.1,0,6.29);g.fillStyle=css('--fit');g.fill();}}}}
}}
const box=document.getElementById('panels');
let curCls=null;
for(const p of DATA.panels){{
 if(p.cls!==curCls){{curCls=p.cls;const h=document.createElement('div');h.className='grouphdr';
  h.textContent=curCls==='stable'?'Stables':'Volatiles';box.appendChild(h);}}
 const c=document.createElement('div');c.className='card';
 if(p.nodata){{c.innerHTML=`<div class="ch-head"><h2>${{p.sym}}</h2></div>
  <div class="canvas-box"><div class="nodata">no data<br>${{p.reason}}</div></div>`;
  box.appendChild(c);continue;}}
 c.innerHTML=`<div class="ch-head"><h2>${{p.sym}}</h2></div>
  <div class="canvas-box"><canvas></canvas></div>
  <div class="cap">${{p.cap||''}}</div>`;
 box.appendChild(c);
 const cv=c.querySelector('canvas');
 requestAnimationFrame(()=>draw(cv,p));
 new ResizeObserver(()=>draw(cv,p)).observe(cv.parentElement);
}}
new MutationObserver(()=>{{const cvs=document.querySelectorAll('canvas');let i=0;
 for(const p of DATA.panels)if(!p.nodata)draw(cvs[i++],p);}})
 .observe(document.documentElement,{{attributes:true,attributeFilter:['data-theme']}});
</script>
</body></html>"""

out = HERE / "out" / "density_overlay_lognormal.html"
HTML = HTML.replace("—", "-")     # no em-dash in emitted HTML (voice rule)
out.write_text(HTML)
print(f"wrote {out}  ({len(HTML)} bytes)  panels={len(panels)} nodata={nodata}")
