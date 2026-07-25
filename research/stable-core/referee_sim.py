#!/usr/bin/env python3
"""referee_sim.py: consumption-sim REFEREE for the v2 density basis (final arbiter).

Density-match (KL) is a proxy; replayed fee-minus-LVR PnL J is the objective. Per
fittable asset, replays each candidate (v3 deployed + v2 pick + shippable runners)
through the consumption_sim mechanism on the 14d NXR 10s tapes:
  real push (theta-trigger + heartbeat, keeper latency L bars: mark value observed at
  crossing, lands L-1 bars later) + arb tether (pool mid kept within half-fee h of
  truth, fee h on swept depth, loss = edge beyond h) + two-sided uninformed noise flow.

Scoring:  J = (fee_captured - LVR) / TVL, annualized %, averaged over the robustness
sweep L in {1,3,6} bars x turnover {0.25,1,4} x TVL/day (fixed noise seeds per cell,
identical across candidates).

DAMPED fixed-point (central cell L=1, T=1, lambda = 0.4, 4 rounds; DAMPING MANDATORY,
undamped projection flips netAPR wildly): replay -> measured consumption density
(slab-crossing mass per curve level = fee$ per unit depth) -> blend (1-l)*deployed +
l*measured -> v3 KL preset projection -> redeploy. Reports pick + netAPR trajectory
(self-consistency check; NOT the primary score: on-chain we deploy presets, so J is
scored on the candidate as-deployed).

Fee: h = minFee/2 = theta + E[(|G|-theta)+]/2 (protocol minFee = 2*theta + exceedance
premium; measured per asset from the L=1 mark-offset law). Dynamic vol-scaled fees NOT
modeled: J is the minFee-floor lower bound.

Gates per asset: J>0 · FITTED q50 (projected preset S * shape-q50) scales with theta
under theta x2 within 10% (policy-covariance not artifact) · traded-volume dwell within
S_dep improves vs v3 (estimator-level) · wall span >= push-exceedance q99.

Run: python3 referee_sim.py            (ONLY=USDT,BTC to subset;
     MERGE_ONLY=1 re-merges an existing out/referee_results.json without replays)
Writes out/referee_results.json + merges referee fields into out/density_basis_v2.json.
"""
import json, math, os, time, zlib
from pathlib import Path
import numpy as np

HERE = Path(__file__).parent
GRID = json.load(open(HERE / "out" / "spline_shared_grid.json"))
FIT = json.load(open(HERE / "out" / "fit_results.json"))["assets"]
V2PATH = HERE / "out" / "density_basis_v2.json"
V2 = json.load(open(V2PATH))
WALLKEY = {0.5: "W0_5", 1: "W1", 2: "W2", 5: "W5"}
REGIMES9 = ["hyper", "flat", "plateau", "meso", "lepto", "platy", "skew_L", "skew_R", "pin_M"]
NO_SHIP = {"skew_L", "skew_R", "pin_M"}
DISP_REF = {"hyper": 50, "flat": 100, "plateau": 100, "meso": 200, "lepto": 500,
            "platy": 500, "skew_L": 500, "skew_R": 500, "pin_M": 500}
NBINS = (61, 81, 101)
CUT_LO, CUT_HI = 0.25, 0.35
TVL = 1e6
NOISE_P = 0.05
NB = 2000
BARS_DAY = 8640
LATS = (1, 3, 6)
TURNS = (0.25, 1.0, 4.0)
LAMBDA = 0.4
FP_ROUNDS = 4
MAX_CANDS = 5
TIE_TOL_APR = 2.0            # J within max(2 APR pts, 5%) -> segment/W tie-break (v3 rule)
ASSETS = ["USDT", "USD1", "USDE", "FDUSD", "BTC", "ETH", "BNB", "CAKE"]
PROVISIONAL = {"EURC": "fx feed QC pending (session gaps, indicative pricing)",
               "XAUT": "metal feed QC pending (held per wizard review)",
               "PAXG": "indicative-feed noise (q99.9 |r1| ~286bp), KL mismatch tier"}
FALLBACK = ["U", "USDG", "USDF", "USDTB"]
TAPE = {"USDT": "USDT-USDC.json", "USD1": "USD1-USDC.json", "USDE": "USDE-USDC.json",
        "FDUSD": "FDUSD-USDC.json", "BTC": "BTC-USDC.json", "ETH": "ETH-USDC.json",
        "BNB": "BNB-USDC.json", "CAKE": "CAKE-USDC.json"}
ONLY = set(filter(None, os.environ.get("ONLY", "").split(",")))

# ── preset + truncated-KL machinery (v3-identical, mirrors make_density_overlay.py) ──
def preset_pdf(regime, W):
    dd = np.array(GRID["walls"][WALLKEY[W]]["presets"][regime]["series"]["density"], dtype=float)
    xs, ys = dd[:, 0], np.maximum(dd[:, 1], 0.0)
    f = ys / np.trapezoid(ys, xs)
    cdf = np.concatenate([[0], np.cumsum(0.5 * (f[1:] + f[:-1]) * np.diff(xs))]); cdf /= cdf[-1]
    return xs, f, cdf

PRESETS = {}
for _wn, _wk in WALLKEY.items():
    for _r in GRID["portableMatrix"][_wk]:
        if _r in REGIMES9: PRESETS[(_wn, _r)] = preset_pdf(_r, _wn)
SEGS = {(w, r): GRID["walls"][WALLKEY[w]]["presets"][r]["segments"] for (w, r) in PRESETS}

def wq(x, w, q):
    i = np.argsort(x); cw = np.cumsum(w[i]); cw /= cw[-1]
    return np.interp(q, cw, x[i])

def trunc_kl(samples, weights, xs, cdf, W, S, nb):
    edges = np.linspace(-S, S, nb + 1)
    P, _ = np.histogram(samples, bins=edges, weights=weights)
    if P.sum() <= 0: return 9e9
    P = P / P.sum()
    Q = np.diff(np.interp(edges * (W / S), xs, cdf)); Q = np.maximum(Q, 1e-12); Q /= Q.sum()
    m = P > 0
    return float(np.sum(P[m] * np.log(P[m] / Q[m])))

def fit_target(samples, weights, klass):
    aq = wq(np.abs(samples), weights, [1 - CUT_HI, 1 - CUT_LO])
    S_grid = np.linspace(float(aq[0]), float(aq[1]), 15)
    wsum = weights.sum()
    cuts = np.array([float(weights[np.abs(samples) > S].sum() / wsum) for S in S_grid])
    pen = 0.01 * ((cuts - 0.30) / 0.05) ** 2
    cands = []
    for (W, reg), (xs, f, cdf) in PRESETS.items():
        if reg in NO_SHIP: continue
        if reg == "hyper" and klass != "stable": continue
        best = None
        for j, S in enumerate(S_grid):
            score = float(np.mean([trunc_kl(samples, weights, xs, cdf, W, S, nb) for nb in NBINS])) + pen[j]
            if best is None or score < best[0]: best = (score, float(S))
        cands.append(dict(regime=reg, W=W, loss=best[0], S=best[1]))
    cands.sort(key=lambda c: c["loss"])
    top = cands[0]["loss"]
    return sorted([c for c in cands if c["loss"] <= top * 1.03],
                  key=lambda c: (SEGS[(c["W"], c["regime"])], c["W"]))[0]

def shape_q50(regime, W):
    """q50 of |x| under the preset pdf, in W-normalized units (symmetric density)."""
    xs, f, cdf = PRESETS[(W, regime)]
    return abs(float(np.interp(0.75, cdf, xs))) / W

# ── tape + push precompute ──
def load_tape(fn, pxwin=None):
    rows = json.load(open(HERE / "data" / "nxr_ohlc" / fn))
    ts = np.array([r["ts"] for r in rows], dtype="int64") / 1000.0
    close = np.array([r["close"] for r in rows])
    tick = np.array([r.get("tick_count", 1) for r in rows])
    ok = (close > 0) & (tick > 0)
    # pxwin mirrors make_density_overlay.load_tape: the referee MUST replay the same cleaned tape
    # the params were fit on, or a contaminated-feed asset (USDG, XAUT) is gated on different data.
    med = np.median(close[ok])
    lo, hi = pxwin if pxwin else (med * 0.5, med * 2.0)
    ok &= (close > lo) & (close < hi)
    idx = np.flatnonzero(ok)
    t = ts[idx]; lg = np.log(close[idx])
    r1 = 1e4 * np.diff(lg)
    clip = max(50.0, 10.0 * float(np.quantile(np.abs(r1), 0.999)))
    return t, lg, clip, (t[-1] - t[0]) / 86400.0

def push_g(t, lg, theta, hb, clip, L):
    """per-bar offset vs pre-landing mark (NaN = glitch skip). L=1 reproduces the
    consumption_sim arb-then-push ordering; L>1 lands the CROSSING-time value L-1
    bars later (stale mark value = keeper latency LVR window)."""
    n = len(lg); g_pre = np.full(n, np.nan)
    M = lg[0]; last = t[0]; pi = -1; pv = 0.0; pushes = 0
    for i in range(1, n):
        g = 1e4 * (lg[i] - M)
        if g < -clip or g > clip: continue
        g_pre[i] = g
        if 0 <= pi <= i:
            M = pv; last = t[i]; pi = -1; pushes += 1
        g2 = 1e4 * (lg[i] - M)
        if pi < 0 and (abs(g2) >= theta or (t[i] - last) >= hb):
            if L == 1: M = lg[i]; last = t[i]; pushes += 1
            else: pi = i + L - 1; pv = lg[i]
    return g_pre, pushes

def build_curve(regime, W, S_bp):
    xs, f, cdf = PRESETS[(W, regime)]
    xe = np.linspace(0, 1e4, NB + 1)
    ynat = np.interp(xe / 1e4, cdf, xs)
    ye = ynat * (S_bp / W)
    ybar = 0.5 * (ye[:-1] + ye[1:])
    def x_of_y(ybp):
        yn = np.clip(ybp * W / S_bp, xs[0], xs[-1])
        return float(np.interp(yn, xs, cdf) * 1e4)
    return dict(xe=xe, ye=ye, ybar=ybar, x_of_y=x_of_y, regime=regime, W=W, S=S_bp)

def replay(g_pre, curve, h, T, seed):
    """arb + noise consumption loop on a precomputed mark-offset path."""
    rng = np.random.default_rng(seed)
    xe, ye, ybar, x_of_y = curve["xe"], curve["ye"], curve["ybar"], curve["x_of_y"]
    binw = 1e4 / NB
    n = len(g_pre); noise_mean = T * TVL / (BARS_DAY * NOISE_P)
    fee_tot = 0.0; loss_tot = 0.0; cross = np.zeros(NB); pinned = 0
    x = 5000.0
    for i in range(1, n):
        g = g_pre[i]
        if g != g: continue
        ycur = np.interp(x, xe, ye)
        if ycur < g - h or ycur > g + h:
            up = ycur < g - h
            ystar = (g - h) if up else (g + h)
            xstar = x_of_y(ystar)
            a, b = (x, xstar) if up else (xstar, x)
            i0, i1 = int(a / binw), min(int(b / binw) + 1, NB)
            if i1 > i0:
                sl = slice(i0, i1)
                dx = np.full(i1 - i0, binw)
                dx[0] -= (a - i0 * binw); dx[-1] -= (i1 * binw - b)
                dx = np.maximum(dx, 0.0)
                vol = TVL * dx / 1e4
                edge = (g - ybar[sl] - h) if up else (ybar[sl] - g - h)
                fee_tot += float(vol.sum()) * h * 1e-4
                loss_tot += float((np.maximum(edge, 0.0) * vol).sum()) * 1e-4
                cross[sl] += dx / binw
            x = xstar
        if rng.random() < NOISE_P:
            v = noise_mean * rng.lognormal(-0.5, 1.0)
            dxn = v / TVL * 1e4 * (1 if rng.random() < 0.5 else -1)
            x2 = min(max(x + dxn, 0.0), 1e4)
            a, b = (x, x2) if x2 > x else (x2, x)
            i0, i1 = int(a / binw), min(int(b / binw) + 1, NB)
            if i1 > i0:
                dx = np.full(i1 - i0, binw)
                dx[0] -= (a - i0 * binw); dx[-1] -= (i1 * binw - b)
                dx = np.maximum(dx, 0.0)
                fee_tot += float(dx.sum()) * TVL / 1e4 * h * 1e-4
                cross[slice(i0, i1)] += dx / binw
            x = x2
        if x <= binw or x >= 1e4 - binw: pinned += 1
    return fee_tot, loss_tot, cross, pinned

def q50_abs(ybar, w):
    if w.sum() <= 0: return 0.0
    return float(wq(np.abs(ybar), w, [0.5])[0])

# ── merge into density_basis_v2.json (final decision fields) ──
def merge(res):
    V2["refereed"] = True
    V2["referee"] = dict(
        gen="referee_sim.py (damped consumption replay, 2026-07-22)",
        J="(fee - LVR)/TVL annualized %, mean over L{1,3,6} x T{0.25,1,4} sweep at "
          "minFee = 2*theta + E[(|G|-theta)+] (fee floor; dynamic vol fees not modeled)",
        damping=LAMBDA, fp_rounds=FP_ROUNDS,
        fallback_stables="U/USDG/USDF/USDTB keep stable-class defaults, provisional "
                         "(no referee tape)")
    for sym, r in res.items():
        w = r["winner"]
        V2["assets"][sym]["referee"] = dict(
            decision=w["tag"], regime=w["regime"], W=w["W"], S_dep=w["S_dep"],
            minDisp=w["minDisp"], maxDispB99=w["maxDispB99"],
            J=w["J"], J_v3=r["J_v3"], J_vs_v3=r["J_vs_v3"],
            minFee_eff=r["minFee_eff"], gates=r["gates"], gates_pass=r["gates_pass"],
            runner_up=r["runner_up"])
    for sym, why in PROVISIONAL.items():
        if sym in V2["assets"]:
            V2["assets"][sym]["referee"] = dict(decision="keep-v3", provisional=True, reason=why)
    V2PATH.write_text(json.dumps(V2, indent=1))
    print("merged referee fields into out/density_basis_v2.json")

if os.environ.get("MERGE_ONLY") == "1":
    merge(json.load(open(HERE / "out" / "referee_results.json"))["assets"])
    raise SystemExit(0)

# ── referee ──
results = {}
for sym in ASSETS:
    if ONLY and sym not in ONLY: continue
    t0 = time.time()
    r3 = FIT[sym]; r2 = V2["assets"][sym]
    theta = r3["thetaFinal"]; hb = r3["hb_s"]; klass = r3["cls"]
    t, lg, clip, span_d = load_tape(TAPE[sym])
    ann = (365.0 / span_d) * 100.0 / TVL
    gmap = {L: push_g(t, lg, theta, hb, clip, L) for L in LATS}
    g2x, _ = push_g(t, lg, 2 * theta, hb, clip, 1)
    # protocol fee floor: minFee = 2*theta + E[(|G|-theta)+]  ->  h = minFee/2
    prem = float(np.nanmean(np.maximum(np.abs(gmap[1][0]) - theta, 0.0)))
    prem2 = float(np.nanmean(np.maximum(np.abs(g2x) - 2 * theta, 0.0)))
    h = theta + prem / 2
    h2x = 2 * theta + prem2 / 2
    seed_c = zlib.crc32(f"{sym}|1|1.0".encode()) & 0xFFFFFFFF

    cands = []; seen = set()
    def addc(tag, reg, W, S):
        # dedupe ignores W for the flat family: scaling [-W,W] -> [-S,S] makes the
        # same regime at equal S an identical bp-space curve across W tiers
        key = (reg, round(S, 2))
        if key in seen or len(cands) >= MAX_CANDS: return
        seen.add(key); cands.append(dict(tag=tag, regime=reg, W=W, S_dep=round(float(S), 3)))
    addc("v3", r3["regime"], r3["W"], r3["supportDeployBp"])
    addc("v2pick", r2["v2"]["regime"], r2["v2"]["W"], r2["v2"]["S_dep"])
    for j, c in enumerate(r2["runners"]):
        if c["regime"] in NO_SHIP: continue
        addc(f"runner{j}", c["regime"], c["W"], max(c["S"], 2 * theta))

    for c in cands:
        curve = build_curve(c["regime"], c["W"], c["S_dep"])
        cells = {}; central = None
        for L in LATS:
            for T in TURNS:
                seed = zlib.crc32(f"{sym}|{L}|{T}".encode()) & 0xFFFFFFFF
                fee, loss, cross, pin = replay(gmap[L][0], curve, h, T, seed)
                cells[f"L{L}_T{T:g}"] = round((fee - loss) * ann, 1)
                if L == 1 and T == 1.0:
                    central = (fee, loss, cross, pin)
        c["J"] = round(float(np.mean(list(cells.values()))), 1)
        c["cells"] = cells
        fee, loss, cross, pin = central
        nrec = int(np.sum(~np.isnan(gmap[1][0])))
        c["central"] = dict(feeAPR=round(fee * ann, 1), lossAPR=round(loss * ann, 1),
                            netAPR=round((fee - loss) * ann, 1),
                            pinnedPct=round(100 * pin / max(nrec, 1), 2))
        # damped fixed-point, central cell (round 0 = candidate as-deployed, reused)
        cur = curve; traj = []
        for k in range(FP_ROUNDS):
            if k == 0: f_k, l_k, cr_k = fee, loss, cross
            else: f_k, l_k, cr_k, _ = replay(gmap[1][0], cur, h, 1.0, seed_c)
            csym = cr_k + cr_k[::-1]
            tot = csym.sum()
            wbl = (1 - LAMBDA) / NB + (LAMBDA * csym / tot if tot > 0 else 0.0)
            pick = fit_target(cur["ybar"], wbl, klass)
            S2 = max(pick["S"], 2 * theta)
            traj.append(dict(net=round((f_k - l_k) * ann, 1),
                             proj=[pick["regime"], pick["W"], round(S2, 2)]))
            cur = build_curve(pick["regime"], pick["W"], S2)
        c["fp"] = traj
        c["fp_stable"] = traj[-1]["proj"][:2] == traj[-2]["proj"][:2]
        c["fp_dnet"] = round(traj[-1]["net"] - traj[0]["net"], 1)
        # theta x2 policy-covariance gate on the FITTED q50: replay at 2*theta
        # (h, S_dep, rail all scale), project consumption, compare fitted-density q50
        # (= S_proj * shape_q50) against the x2 lever; <10% deviation = covariant.
        p1 = traj[0]["proj"]                                   # theta-side projection
        q50f_1 = p1[2] * shape_q50(p1[0], p1[1])               # S_proj * shape-q50
        curve2 = build_curve(c["regime"], c["W"], 2 * c["S_dep"])
        fee2, loss2, cross2, _ = replay(g2x, curve2, h2x, 1.0, seed_c)
        cs2 = cross2 + cross2[::-1]; tot2 = cs2.sum()
        wbl2 = (1 - LAMBDA) / NB + (LAMBDA * cs2 / tot2 if tot2 > 0 else 0.0)
        pick2 = fit_target(curve2["ybar"], wbl2, klass)
        S2x = max(pick2["S"], 4 * theta)
        q50f_2 = S2x * shape_q50(pick2["regime"], pick2["W"])
        c["q50_fit"] = round(q50f_1, 3)
        c["q50_fit_x2"] = round(q50f_2, 3)
        c["q50_shift_pct"] = round(100 * abs(q50f_2 / (2 * q50f_1) - 1), 1) if q50f_1 > 0 else 999.0

    # winner: max J within tolerance; ties broken by density-match KL on the v2
    # target (J is decisive, KL is the proxy fallback), then segments/W
    kl_of = {("v3",): r2["v3"]["KL_on_newTarget"], ("v2pick",): r2["v2"]["KL"]}
    for j, rc in enumerate(r2["runners"]): kl_of[(f"runner{j}",)] = rc["kl"]
    Jbest = max(c["J"] for c in cands)
    tol = max(TIE_TOL_APR, 0.05 * abs(Jbest))
    finalists = [c for c in cands if c["J"] >= Jbest - tol]
    win = sorted(finalists, key=lambda c: (kl_of.get((c["tag"],), 9e9),
                                           SEGS[(c["W"], c["regime"])], c["W"]))[0]
    ru = sorted([c for c in cands if c is not win], key=lambda c: -c["J"])[0]
    v3c = cands[0]
    dref = DISP_REF[win["regime"]]
    minDisp = int(round(win["S_dep"] * dref / win["W"]))
    b99_6 = r3["b99_6min"]
    wall_floor = r2["lvr"]["wall_floor"]
    pexc = r2["lvr"]["pushExcQ99"]
    maxDisp = max(int(math.ceil(wall_floor * dref / win["W"])), minDisp)
    wall_bp = maxDisp * win["W"] / dref
    cov = r2["dwell_coverage"]
    gates = dict(
        J_pos=bool(win["J"] > 0),
        q50_theta_cov=bool(win["q50_shift_pct"] < 10),
        dwell_improves=bool(cov["actvol_within_Sdep_new"] >= cov["actvol_within_Sdep_old"]),
        wall_ge_exc=bool(wall_floor + 1e-9 >= pexc and wall_bp + 1e-9 >= pexc))
    results[sym] = dict(
        theta=theta, h_eff=round(h, 4), minFee_eff=round(2 * h, 4),
        exc_prem=round(prem, 4), span_d=round(span_d, 1),
        pushes_h=round(gmap[1][1] / (span_d * 24), 1),
        wall_floor=wall_floor, pushExcQ99=pexc, wall_bp=round(wall_bp, 2),
        candidates=cands,
        winner=dict(tag=win["tag"], regime=win["regime"], W=win["W"], S_dep=win["S_dep"],
                    minDisp=minDisp, maxDispB99=maxDisp, J=win["J"]),
        J_v3=v3c["J"], J_vs_v3=round(win["J"] - v3c["J"], 1),
        runner_up=dict(tag=ru["tag"], regime=ru["regime"], W=ru["W"], J=ru["J"]),
        gates=gates, gates_pass=bool(all(gates.values())))
    w = results[sym]["winner"]
    print(f"{sym}: winner {w['tag']} {w['regime']} W{w['W']} S_dep {w['S_dep']} "
          f"J {w['J']} (v3 {v3c['J']}, d {results[sym]['J_vs_v3']:+}) "
          f"gates {gates} [{time.time()-t0:.0f}s]", flush=True)

(HERE / "out" / "referee_results.json").write_text(json.dumps(dict(
    gen="referee_sim.py v0 (damped consumption replay referee, 2026-07-22)",
    generated=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    protocol=dict(TVL=TVL, noise_p=NOISE_P, lats=list(LATS), turns=list(TURNS),
                  damping=LAMBDA, fp_rounds=FP_ROUNDS,
                  J="(fee - LVR)/TVL annualized %, mean over 3x3 latency-turnover sweep"),
    assets=results), indent=1))
print("wrote out/referee_results.json")
if not ONLY: merge(results)
