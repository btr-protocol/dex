#!/usr/bin/env python3
"""referee_lognormal.py: referee_sim.py J-replay of the SPLIT-family minimal-knot presets
(out/lognormal_fit.json: stables plateau, volatiles peaked) vs the v4 presets as-deployed
(PROTOTYPE, unstaged).

Reuses referee_sim.py machinery VERBATIM (exec of everything above the run loop: tapes,
push_g, replay, seeds, h = minFee/2 = theta + excPrem/2). Same 3x3 robustness sweep
L{1,3,6} x T{0.25,1,4}, same crc32 seeds per cell -> J difference is purely the curve shape.
The only new code is the curve builder for the minimal-knot clamped-quartic spline
(quantile curve y(u) = S_dep * B(u).w, monotone by dw>=0).

3-WAY on volatiles: the chosen PEAKED preset AND the altFit PLATEAU preset (same S_dep, same
cell) are both replayed against the v4 baseline, so the J the plateau lost and the J the
peaked recovers are measured in one run with identical seeds/push paths.

v4 baseline J = the "v3"-tagged candidate in out/referee_results.json (same machinery, same
seeds, generated 2026-07-22). VALIDATE=1 re-replays the v4 USDT candidate first and asserts
it reproduces before trusting the baseline.

Writes out/referee_lognormal.json + merges refereeJ per asset back into out/lognormal_fit.json
(the unified emit). Does not touch referee_sim.py / referee_results.json.
Run: python3 referee_lognormal.py     (ONLY=USDT,BTC to subset; VALIDATE=1 for the harness check)
"""
import json, os, time, zlib
from pathlib import Path
import numpy as np
from scipy.interpolate import BSpline

HERE = Path(__file__).parent
_src = open(HERE / "referee_sim.py").read()
exec(compile(_src[:_src.index("# ── referee ──")], "referee_sim.py[defs]", "exec"))
# in scope: GRID, FIT, V2, PRESETS, SEGS, load_tape, push_g, build_curve, replay,
#           NB, LATS, TURNS, TVL, ASSETS, TAPE, wq

LN = json.load(open(HERE / "out" / "lognormal_fit.json"))["assets"]
BASE = json.load(open(HERE / "out" / "referee_results.json"))["assets"]
ONLYX = set(filter(None, os.environ.get("ONLY", "").split(",")))
# The gate runs over EVERY fitted asset, not just the 8 the v4 referee covered. theta/hb/tape come
# from the fit emit + roster (single source), so an asset needs no v4 history to be gated; assets
# with no v4 candidate simply report J with a null delta.
_ov = open(HERE / "make_density_overlay.py").read()
_ns = {"__name__": "overlay_defs", "__file__": str(HERE / "make_density_overlay.py")}
exec(compile(_ov[:_ov.index("# ── tape load + cleaning")], "make_density_overlay.py[roster]", "exec"),
     _ns)                                        # isolated namespace: must not shadow referee_sim defs
CFG = {c["sym"]: c for c in _ns["A"]}
HB = {k: v["hb"] for k, v in _ns["CLASS"].items()}
SYMS = [s for s in LN if not ONLYX or s in ONLYX]

def build_curve_ln(w, m, knots_u, S_bp):
    """referee curve dict from the minimal-knot preset: y(u) = S_dep * clamped-quartic(u)."""
    t = np.r_[[0.0] * 5, knots_u, [1.0] * 5]
    u = np.linspace(0.0, 1.0, 20001)
    y = np.clip(BSpline(t, np.asarray(w, float), 4)(u), -1, 1) * S_bp
    y = np.maximum.accumulate(y)                 # guard fp ties; dw>=0 => monotone
    xe = np.linspace(0, 1e4, NB + 1)
    ye = np.interp(xe / 1e4, u, y)
    ybar = 0.5 * (ye[:-1] + ye[1:])
    def x_of_y(ybp):
        return float(np.interp(ybp, y, u * 1e4))
    return dict(xe=xe, ye=ye, ybar=ybar, x_of_y=x_of_y, regime="LN", W=None, S=S_bp)

def sweep_J(sym, gmap, curve, h, span_d):
    ann = (365.0 / span_d) * 100.0 / TVL
    cells = {}; central = None
    for L in LATS:
        for T in TURNS:
            seed = zlib.crc32(f"{sym}|{L}|{T}".encode()) & 0xFFFFFFFF
            fee, loss, cross, pin = replay(gmap[L][0], curve, h, T, seed)
            cells[f"L{L}_T{T:g}"] = round((fee - loss) * ann, 1)
            if L == 1 and T == 1.0:
                central = (fee, loss, pin)
    fee, loss, pin = central
    nrec = int(np.sum(~np.isnan(gmap[1][0])))
    return (round(float(np.mean(list(cells.values()))), 1), cells,
            dict(feeAPR=round(fee * ann, 1), lossAPR=round(loss * ann, 1),
                 netAPR=round((fee - loss) * ann, 1),
                 pinnedPct=round(100 * pin / max(nrec, 1), 2)))

results = {}
for sym in SYMS:
    t0 = time.time()
    new = LN[sym]
    theta = new["theta"]; hb = HB[new["cls"]]
    t, lg, clip, span_d = load_tape(CFG[sym]["tape"], CFG[sym].get("pxwin"))
    gmap = {L: push_g(t, lg, theta, hb, clip, L) for L in LATS}
    prem = float(np.nanmean(np.maximum(np.abs(gmap[1][0]) - theta, 0.0)))
    h = theta + prem / 2
    if os.environ.get("VALIDATE") == "1" and sym in BASE:
        v4c = BASE[sym]["candidates"][0]
        Jv, _, _ = sweep_J(sym, gmap, build_curve(v4c["regime"], v4c["W"], v4c["S_dep"]), h, span_d)
        assert abs(Jv - v4c["J"]) < 0.05, f"{sym}: harness drift {Jv} vs {v4c['J']}"
        print(f"{sym}: VALIDATE ok (v4 J reproduces: {Jv})", flush=True)
    f = new["fit"]
    curve = build_curve_ln(f["w"], f["m"], f["knotsU"], new["ln"]["S_dep"])
    J_new, cells, central = sweep_J(sym, gmap, curve, h, span_d)
    alt = new.get("altFit")                              # volatiles: plateau diagnostic, same S_dep
    if alt:
        curveP = build_curve_ln(alt["w"], alt["m"], alt["knotsU"], new["ln"]["S_dep"])
        J_pl, _, centralP = sweep_J(sym, gmap, curveP, h, span_d)
        plateau = dict(preset=alt["presetId"], m=alt["m"], J=J_pl, central=centralP)
    else:
        plateau = None                                   # stables: the NEW preset IS the plateau
    # tag "v3" = fit_results.json as-deployed. Absent for every asset the v4 referee never covered
    # (the 2026-07-22 Sepolia adds + the 2026-07-24 tape landings) — J then stands on its own.
    v4c = BASE[sym]["candidates"][0] if sym in BASE else None
    J_pl_eff = plateau["J"] if plateau else J_new
    results[sym] = dict(
        cls=new["cls"], theta=theta, h_eff=round(h, 4), span_d=round(span_d, 1),
        tapeStatus=new["tapeStatus"],
        new=dict(preset=new["cell"]["presetId"], family=f.get("family"), m=f["m"],
                 S_dep=new["ln"]["S_dep"], J=J_new, cells=cells, central=central),
        plateau=plateau,
        v4=(dict(regime=v4c["regime"], W=v4c["W"], S_dep=v4c["S_dep"], J=v4c["J"],
                 central=v4c.get("central")) if v4c else None),
        J_delta=(round(J_new - v4c["J"], 1) if v4c else None),
        J_delta_rel_pct=(round(100 * (J_new - v4c["J"]) / abs(v4c["J"]), 1)
                         if v4c and v4c["J"] else None),
        J_recovered=(round(J_new - J_pl_eff, 1) if plateau else None),
        J_plateau_delta=(round(J_pl_eff - v4c["J"], 1) if plateau and v4c else None))
    msg = f"{sym}: NEW {new['cell']['presetId']} J={J_new}"
    if v4c:
        msg += (f" | v4 {v4c['regime']}/W{v4c['W']} J={v4c['J']} "
                f"| d {results[sym]['J_delta']:+} ({results[sym]['J_delta_rel_pct']:+}%)")
    else:
        msg += " | v4 baseline: none (never refereed)"
    if plateau:
        msg += f" | plateau {plateau['preset']} J={J_pl} (recovered {results[sym]['J_recovered']:+})"
    print(msg + f" [{time.time()-t0:.0f}s]", flush=True)

(HERE / "out" / "referee_lognormal.json").write_text(json.dumps(dict(
    gen="referee_lognormal.py (referee_sim machinery verbatim, SPLIT-family minimal-knot vs "
        "plateau-LN vs v4 as-deployed)",
    generated=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    protocol=dict(J="(fee - LVR)/TVL annualized %, mean over L{1,3,6} x T{0.25,1,4}, "
                    "identical seeds/h/push-paths across candidates -> shape-only delta",
                  baseline="out/referee_results.json candidates[0] (v4 as-deployed); volatiles "
                           "also replay the altFit plateau preset (same S_dep/cell) for the 3-way"),
    assets=results), indent=1))
print("wrote out/referee_lognormal.json")

# ── merge referee J into the unified emit (out/lognormal_fit.json) ──
LNJ = json.load(open(HERE / "out" / "lognormal_fit.json"))
for sym, r in results.items():
    LNJ["assets"][sym]["refereeJ"] = dict(
        v4=(r["v4"]["J"] if r["v4"] else None),
        plateau=(r["plateau"]["J"] if r["plateau"] else r["new"]["J"]),
        new=r["new"]["J"], family=r["new"]["family"],
        deltaVsV4=r["J_delta"], deltaVsV4RelPct=r["J_delta_rel_pct"], recovered=r["J_recovered"])
(HERE / "out" / "lognormal_fit.json").write_text(json.dumps(LNJ, indent=1))
print("merged refereeJ into out/lognormal_fit.json")
