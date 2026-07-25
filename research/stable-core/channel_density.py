#!/usr/bin/env python3
"""channel_density.py — OWNER-BASIS PROTOTYPE: channel-divergence density (slow fee kernel).

Estimator (formalization of owner proposal, 2026-07-22):
  center C_t   = winsorized flow-EMA (volume-weighted exponential VWAP), horizon tau.
                 Two-pass: pass1 raw -> h = q70(|d|) (70% containment = 30% cut band,
                 matches v3 cut target); pass2 center update uses clamp(P, C*e^{+-h}),
                 so one-sided excursions cannot drag the gravity center (median-like
                 robustness, O(1) causal).
  divergence   d_t = 1e4 * (ln P_t - ln C_t)  [bp], time-sampled every bar (occupation
                 measure, dt-weighted, holes capped).
  3 TFs        tau in {tau_inv/2, tau_inv, 2*tau_inv}; pi_inv = equal-weight mixture
                 (robustness ensemble over unknown coverage mean-reversion time).
  current mark = the FAST kernel g_theta: empirical offset-from-pushed-mark density at
                 theta_final (v3 basis, measured, incl. overshoot/heartbeat/quantization).
                 Composition is CONVOLUTION not mixture: quote offset = reset-bridge
                 offset (+mark-relative) + persistent skew offset -> density of sum.
  fee target   ell = g_theta (*) pi_inv  -> the density the spline core should match.
  LVR side unchanged from v3: push-instant exceedances, b99_6min, S_dep >= 2*theta.

Reads theta_final/cadence from out/fit_results.json (v3), tapes from data/nxr_ohlc.
Emits out/channel_density.json + stdout table. Research prototype — not wired to deploy.
"""
import json, math
from pathlib import Path
import numpy as np

HERE = Path(__file__).parent
OHLC = HERE / "data" / "nxr_ohlc"
FIT = json.load(open(HERE / "out" / "fit_results.json"))["assets"]
GRID = json.load(open(HERE / "out" / "spline_shared_grid.json"))
WALLKEY = {0.5: "W0_5", 1: "W1", 2: "W2", 5: "W5"}
REGIMES9 = ["hyper", "flat", "plateau", "meso", "lepto", "platy", "skew_L", "skew_R", "pin_M"]
NO_SHIP = {"skew_L", "skew_R", "pin_M"}
FROZEN_S = 900
CLASS = {"stable": dict(theta=0.25, hb=1800), "volatile": dict(theta=5.0, hb=300)}
TAU_INV = {"stable": 4 * 3600, "volatile": 1 * 3600, "fx": 2 * 3600}   # coverage MR time defaults; see report

A = [
 ("USDT", "stable", "USDT-USDC.json", False, None),
 ("USD1", "stable", "USD1-USDC.json", False, None),
 ("USDE", "stable", "USDE-USDC.json", False, None),
 ("FDUSD", "stable", "FDUSD-USDC.json", False, None),
 ("BTC", "volatile", "BTC-USDC.json", False, None),
 ("ETH", "volatile", "ETH-USDC.json", False, None),
 ("BNB", "volatile", "BNB-USDC.json", False, None),
 ("CAKE", "volatile", "CAKE-USDC.json", False, None),
 ("EURC", "volatile", "EURC-USDC.json", True, None),
 ("XAUT", "volatile", "XAUT-USDC.json", True, (3500, 4400)),
 ("PAXG", "volatile", "PAXG-USD.json", True, None),
]

def load_tape(fn, pxwin=None):
    rows = json.load(open(OHLC / fn))
    ts = np.array([r["ts"] for r in rows], dtype="int64") / 1000.0
    close = np.array([r["close"] for r in rows])
    vol = np.array([r.get("vbid", 0) + r.get("vask", 0) for r in rows], dtype=float)
    tick = np.array([r.get("tick_count", 1) for r in rows])
    ok = (close > 0) & (tick > 0)
    lo, hi = pxwin if pxwin else (np.median(close[ok]) * 0.5, np.median(close[ok]) * 2.0)
    ok &= (close > lo) & (close < hi)
    tf = float(np.median(np.diff(ts)))
    c = close[ok]
    r1 = 1e4 * np.log(c[1:] / c[:-1])
    clip = max(50.0, 10.0 * float(np.quantile(np.abs(r1), 0.999)))
    return ts, close, vol, ok, tf, clip

def session_mask(ts, close, ok):
    idx = np.flatnonzero(ok); c = close[idx]; t = ts[idx]; n = len(idx)
    frozen = np.zeros(n, bool); i = 0
    while i < n:
        j = i
        while j + 1 < n and c[j + 1] == c[i]: j += 1
        if t[j] - t[i] >= FROZEN_S: frozen[i:j + 1] = True
        i = j + 1
    rec = np.zeros(len(ts), bool); rec[idx[~frozen]] = True
    return rec

def push_offsets(ts, close, ok, theta, hb_s, clip, rec=None):
    """v3 basis + push-instant record: returns (time-sampled offsets, push-instant |G|, pushes, span_h)."""
    idx = np.flatnonzero(ok)
    mark = close[idx[0]]; last_ts = ts[idx[0]]
    off = np.empty(len(idx) - 1); n = 0; pushes = 0; G = []
    lg = np.log(close[idx[1:]]); t = ts[idx[1:]]
    rm = rec[idx[1:]] if rec is not None else None
    lm = math.log(mark)
    for i in range(len(lg)):
        o = 1e4 * (lg[i] - lm)
        if o > clip or o < -clip: continue
        if rm is None or rm[i]: off[n] = o; n += 1
        if o >= theta or -o >= theta or (t[i] - last_ts) >= hb_s:
            if o >= theta or -o >= theta: G.append(abs(o))
            lm = lg[i]; pushes += 1; last_ts = t[i]
    span_h = (ts[idx[-1]] - ts[idx[0]]) / 3600.0
    return off[:n], np.array(G), pushes, span_h

def channel_divergence(ts, close, vol, ok, tf, tau, rec=None, h_bp=None):
    """One pass of the winsorized flow-EMA channel. Returns (d bp, dt-weights)."""
    idx = np.flatnonzero(ok if rec is None else (ok & rec))
    t = ts[idx]; p = close[idx]; v = vol[idx]
    vfloor = 0.1 * (np.median(v[v > 0]) if (v > 0).any() else 1.0)
    w = np.maximum(v, vfloor)                       # flow weight; quiet bars update weakly
    dt = np.minimum(np.diff(t, prepend=t[0]), 3 * tf)  # capped elapsed moving-time (holes/weekends)
    N = w[0] * p[0]; D = w[0]; C = p[0]
    d = np.empty(len(idx)); hl = math.log(1 + (h_bp or 0) / 1e4)
    for i in range(len(idx)):
        pi = p[i]
        if h_bp is not None:                        # winsorize INPUT to the center at +-h
            lo, hi = C * math.exp(-hl), C * math.exp(hl)
            pi = lo if pi < lo else (hi if pi > hi else pi)
        a = math.exp(-dt[i] / tau)
        N = a * N + w[i] * pi; D = a * D + w[i]; C = N / D
        d[i] = 1e4 * (math.log(p[i]) - math.log(C))
    burn = t > t[0] + 3 * tau                       # drop center burn-in
    return d[burn], dt[burn]

def wq(x, w, q):
    i = np.argsort(x); cw = np.cumsum(w[i]); cw /= cw[-1]
    return np.interp(q, cw, x[i])

def preset_pdf(regime, W):
    dd = np.array(GRID["walls"][WALLKEY[W]]["presets"][regime]["series"]["density"], dtype=float)
    xs, ys = dd[:, 0], np.maximum(dd[:, 1], 0.0)
    f = ys / np.trapezoid(ys, xs)
    cdf = np.concatenate([[0], np.cumsum(0.5 * (f[1:] + f[:-1]) * np.diff(xs))]); cdf /= cdf[-1]
    return xs, f, cdf

PRESETS = {}
for _wn, _wk in WALLKEY.items():
    for _r in GRID["portableMatrix"][_wk]:
        if _r in REGIMES9 and _r not in NO_SHIP: PRESETS[(_wn, _r)] = preset_pdf(_r, _wn)

def kl_grid(grid, dens, xs, cdf, W, S, nb=81):
    """truncated-support KL(ell || preset) on |delta|<=S from a density on a grid."""
    edges = np.linspace(-S, S, nb + 1)
    cd = np.concatenate([[0], np.cumsum(dens)]); cd /= cd[-1]
    ge = np.concatenate([grid - 0.5 * (grid[1] - grid[0]), [grid[-1] + 0.5 * (grid[1] - grid[0])]])
    P = np.diff(np.interp(edges, ge, cd))
    if P.sum() <= 0: return 9e9
    P = np.maximum(P, 0); P /= P.sum()
    Q = np.diff(np.interp(edges * (W / S), xs, cdf)); Q = np.maximum(Q, 1e-12); Q /= Q.sum()
    m = P > 0
    return float(np.sum(P[m] * np.log(P[m] / Q[m])))

out = {}
print(f"{'sym':6} {'thF':>6} {'tent':>5} | offset q50/q70/q99      | chan q50/q70/q99 (blend)   | ell q50/q70/q99          | flat x | pick")
for sym, cls, tape, fx, pxwin in A:
    fr = FIT.get(sym) or {}
    th = fr.get("thetaFinal") or CLASS[cls]["theta"]
    hb = CLASS[cls]["hb"]
    ts, close, vol, ok, tf, clip = load_tape(tape, pxwin)
    rec = session_mask(ts, close, ok) if fx else None
    offs, G, pushes, span_h = push_offsets(ts, close, ok, th, hb, clip, rec)
    ovsht = float(np.mean(np.maximum(G - th, 0))) if len(G) else 0.0
    tent_a = th + ovsht
    oq = np.quantile(np.abs(offs), [0.5, 0.7, 0.99])
    tau0 = TAU_INV["fx" if fx else cls]
    taus = [tau0 / 2, tau0, 2 * tau0]
    per_tf = []; dall = []; wall_ = []
    for tau in taus:
        d1, w1 = channel_divergence(ts, close, vol, ok, tf, tau, rec, None)
        h = float(wq(np.abs(d1), w1, [0.70])[0])            # containment-70 channel half-width
        d2, w2 = channel_divergence(ts, close, vol, ok, tf, tau, rec, h)
        q = wq(np.abs(d2), w2, [0.5, 0.7, 0.99])
        per_tf.append(dict(tau_h=tau / 3600, h_bp=round(h, 3),
                           q50=round(float(q[0]), 3), q70=round(float(q[1]), 3), q99=round(float(q[2]), 3)))
        dall.append(d2); wall_.append(w2 / w2.sum())        # equal-weight TF blend
    d = np.concatenate(dall); wgt = np.concatenate(wall_)
    cq = wq(np.abs(d), wgt, [0.5, 0.7, 0.99])
    # --- fee target: ell = g_theta (*) pi_inv on a common grid ---
    X = float(max(np.quantile(np.abs(d), 0.999), np.quantile(np.abs(offs), 0.999), 4 * tent_a))
    dx = max(tent_a / 8, X / 4000)
    grid = np.arange(-X, X + dx, dx)
    edges = np.concatenate([grid - dx / 2, [grid[-1] + dx / 2]])
    Hp, _ = np.histogram(d, bins=edges, weights=wgt); Hp = Hp / Hp.sum()
    Hg, _ = np.histogram(offs, bins=edges); Hg = Hg / Hg.sum()
    ell = np.convolve(Hp, Hg, "same"); ell /= ell.sum()
    cdf = np.cumsum(ell)
    aell = np.abs(grid)
    o_ = np.argsort(aell); ca = np.cumsum(ell[o_]); ca /= ca[-1]
    lq = np.interp([0.5, 0.7, 0.99], ca, aell[o_])
    S_fee = float(lq[1]); S_dep = max(S_fee, 2 * th)
    # --- regime pick: truncated-KL of ell vs shippable presets at S_fee ---
    cands = sorted([dict(regime=r, W=W, kl=round(kl_grid(grid, ell, xs, cdfp, W, S_fee), 4))
                    for (W, r), (xs, f, cdfp) in PRESETS.items()
                    if not (r == "hyper" and cls != "stable")], key=lambda c: c["kl"])
    flat = float(cq[0] / oq[0])
    out[sym] = dict(cls=cls, thetaFinal=th, cadencePerH=fr.get("cadencePerH"), tent_bp=round(tent_a, 3),
                    overshoot_bp=round(ovsht, 4), tau_inv_h=tau0 / 3600, per_tf=per_tf,
                    off=dict(q50=round(float(oq[0]), 3), q70=round(float(oq[1]), 3), q99=round(float(oq[2]), 3)),
                    chan=dict(q50=round(float(cq[0]), 3), q70=round(float(cq[1]), 3), q99=round(float(cq[2]), 3)),
                    ell=dict(q50=round(float(lq[0]), 3), q70=round(float(lq[1]), 3), q99=round(float(lq[2]), 3)),
                    flatness=round(flat, 1), S_fee=round(S_fee, 3), S_dep=round(S_dep, 3),
                    S_dep_v3=fr.get("supportDeployBp"), b99_6min=fr.get("b99_6min"),
                    pick=cands[0], runners=cands[1:4])
    print(f"{sym:6} {th:>6.3g} {tent_a:>5.2f} | {oq[0]:>6.3f}/{oq[1]:>6.3f}/{oq[2]:>7.2f} | "
          f"{cq[0]:>7.2f}/{cq[1]:>7.2f}/{cq[2]:>8.2f} | {lq[0]:>7.2f}/{lq[1]:>7.2f}/{lq[2]:>8.2f} | "
          f"{flat:>5.1f}x | {cands[0]['regime']} W{cands[0]['W']} KL={cands[0]['kl']}", flush=True)

# --- A4 policy-invariance probe: double theta on USDT + BTC; offset basis scales, channel does not ---
inv = {}
for sym, tape, cls, fxf in [("USDT", "USDT-USDC.json", "stable", False), ("BTC", "BTC-USDC.json", "volatile", False)]:
    th = FIT[sym]["thetaFinal"]; hb = CLASS[cls]["hb"]
    ts, close, vol, ok, tf, clip = load_tape(tape)
    o1, *_ = push_offsets(ts, close, ok, th, hb, clip)
    o2, *_ = push_offsets(ts, close, ok, 2 * th, hb, clip)
    inv[sym] = dict(off_q50_theta=round(float(np.quantile(np.abs(o1), 0.5)), 3),
                    off_q50_2theta=round(float(np.quantile(np.abs(o2), 0.5)), 3),
                    ratio=round(float(np.quantile(np.abs(o2), 0.5) / np.quantile(np.abs(o1), 0.5)), 2))
    print(f"A4 {sym}: offset q50 theta={inv[sym]['off_q50_theta']} 2theta={inv[sym]['off_q50_2theta']} "
          f"(x{inv[sym]['ratio']}); channel q50 unchanged by construction (no theta dependence)")

(HERE / "out" / "channel_density.json").write_text(json.dumps(dict(
    gen="channel_density.py v0 (owner channel-divergence basis prototype, 2026-07-22)",
    estimator=dict(center="winsorized flow-EMA (exp-decayed VWAP), volume floor 0.1*med(v+)",
                   width="h = q70(|d|) per TF (70% containment = 30% cut band)",
                   divergence="1e4*(ln P - ln C) bp, dt-weighted occupation, holes capped 3*tf",
                   tfs="{tau/2, tau, 2tau}, equal-weight mixture", tau_inv_s=TAU_INV,
                   mark="fast kernel g_theta = empirical offset-from-mark density; ell = g (*) pi_inv (convolution)"),
    invariance=inv, assets=out), indent=1))
print("wrote out/channel_density.json")
