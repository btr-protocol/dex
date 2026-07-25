#!/usr/bin/env python3
"""consumption_sim.py — mechanism-derived density basis (formalist proposal prototype).

Simulates the ACTUAL AIMM consumption loop on real NXR 10s tapes:
  truth P_t (tape close) · mark M frozen between θ-pushes (mark := crossing close,
  + heartbeat) · operating point x_t ∈ [0,10000] on the deployed spline (persists
  across pushes — Pricing.sol:208 _skewToDepth; volume moves x by Δx = v·BPS/depth,
  Pricing.sol:182 volumeFraction) · pool mid offset y(x_t) (pbps→bp, mark-relative)
  · arb trades whenever |truth − pool mid| > half-fee h (= minFee/2 = θ), sweeping
  the curve until marginal quote = truth ∓ h · two-sided noise flow pays fee h.

RANDOM VARIABLE measured: curve-offset level y swept by EXECUTED volume — i.e. price
relative to the POOL MID path, weighted by realized fee flow (crossN = slab crossing
count = fee$ per unit depth per level). Plus per-level adverse loss Λ1(y) from arb
sweeps (informed) → marginal value v(y) = h·crossN(y) − Λ1(y) per unit depth.
Compares numerically vs (D1) time-sampled offset-from-mark (current basis) and
(D2) channel-divergence from rolling centers (owner proposal).
Run: python3 consumption_sim.py [SYM=USDT] [THETA_MULT=1]
"""
import json, math, os, sys
from pathlib import Path
import numpy as np

HERE = Path(__file__).parent
GRID = json.load(open(HERE / "out" / "spline_shared_grid.json"))
FIT = json.load(open(HERE / "out" / "fit_results.json"))["assets"]
WALLKEY = {0.5: "W0_5", 1: "W1", 2: "W2", 5: "W5"}

SYM = os.environ.get("SYM", "USDT")
THETA_MULT = float(os.environ.get("THETA_MULT", "1"))
TVL = 1e6                      # $ depth D (calculateDepth, amp=1)
TURNOVER = 1.0                 # noise volume / depth / day (two-sided, uninformed)
NOISE_P = 0.05                 # per-10s-bar trade prob → mean size from turnover
NB = 2000                      # x-bins on [0, 10000]
SEED = 7

R = FIT[SYM]
TAPE = {"USDT": "USDT-USDC.json", "USDE": "USDE-USDC.json", "BTC": "BTC-USDC.json",
        "ETH": "ETH-USDC.json", "USD1": "USD1-USDC.json", "FDUSD": "FDUSD-USDC.json"}[SYM]
theta = R["thetaFinal"] * THETA_MULT
hb = R["hb_s"]
h = theta                       # half-fee = minFee/2 = θ (minFee = 2θ policy)
S_dep = R["supportDeployBp"] * THETA_MULT   # 2θ floor scales with θ
regime, W = R["regime"], R["W"]

# ── tape (same cleaning as make_density_overlay.load_tape) ──
rows = json.load(open(HERE / "data" / "nxr_ohlc" / TAPE))
ts = np.array([r["ts"] for r in rows], dtype="int64") / 1000.0
close = np.array([r["close"] for r in rows])
tick = np.array([r.get("tick_count", 1) for r in rows])
ok = (close > 0) & (tick > 0)
med = np.median(close[ok]); ok &= (close > med * 0.5) & (close < med * 2.0)
idx = np.flatnonzero(ok)
t = ts[idx]; lg = np.log(close[idx])
r1 = 1e4 * np.diff(lg)
clip = max(50.0, 10.0 * float(np.quantile(np.abs(r1), 0.999)))
span_d = (t[-1] - t[0]) / 86400.0

# ── curve y(x): deployed preset, or PROBE=1 → uniform density over wide support
#    (unconstrained consumption measurement: depth everywhere volume could execute) ──
PROBE = os.environ.get("PROBE", "") == "1"
if PROBE:
    S_dep = max(4 * S_dep, 1.2 * R["b99_6min"] * THETA_MULT)
    xs_nat = np.linspace(-W, W, 201); f = np.ones(201)
    regime = "PROBE-uniform"
else:
    d = np.array(GRID["walls"][WALLKEY[W]]["presets"][regime]["series"]["density"], float)
    xs_nat, f = d[:, 0], np.maximum(d[:, 1], 0.0)
cdf = np.concatenate([[0], np.cumsum(0.5 * (f[1:] + f[:-1]) * np.diff(xs_nat))]); cdf /= cdf[-1]
def build_curve(scale_bp):
    """y(x) tables: ybar per x-bin (bp), and inverse x(y)."""
    xe = np.linspace(0, 1e4, NB + 1)
    ynat = np.interp(xe / 1e4, cdf, xs_nat)          # native offset in [-W, W]
    ye = ynat * (scale_bp / W)                       # bp
    ybar = 0.5 * (ye[:-1] + ye[1:])
    def x_of_y(ybp):
        yn = np.clip(ybp * W / scale_bp, xs_nat[0], xs_nat[-1])
        return float(np.interp(yn, xs_nat, cdf) * 1e4)
    return xe, ye, ybar, x_of_y
xe, ye, ybar, x_of_y = build_curve(S_dep)
binw_x = 1e4 / NB

def run_sim(seed=SEED):
    rng = np.random.default_rng(seed)
    n = len(lg)
    noise_mean = TURNOVER * TVL / (8640 * NOISE_P)   # mean $ size given per-bar prob
    fee_b = np.zeros(NB); loss_b = np.zeros(NB); cross_b = np.zeros(NB); dwell_b = np.zeros(NB)
    x = 5000.0; M = lg[0]; last_push = t[0]
    pushes = 0; pinned = 0; fee_tot = 0.0; loss_tot = 0.0
    y_path = np.empty(n); g_path = np.empty(n)
    for i in range(1, n):
        g = 1e4 * (lg[i] - M)
        if abs(g) > clip:                            # glitch wick: skip (same as push_offsets)
            y_path[i] = y_path[i - 1]; g_path[i] = g_path[i - 1]; continue
        g_path[i] = g
        # arb FIRST (keeper latency >= 1 bar: arb hits the stale quote before the push lands),
        # THEN push. arb: keep pool mid within [g-h, g+h]; fee h per unit, loss = edge beyond h
        ycur = np.interp(x, xe, ye)
        if ycur < g - h or ycur > g + h:
            up = ycur < g - h
            ystar = (g - h) if up else (g + h)
            xstar = x_of_y(ystar)
            a, b = (x, xstar) if up else (xstar, x)
            i0, i1 = int(a / binw_x), min(int(b / binw_x) + 1, NB)
            if i1 > i0:
                sl = slice(i0, i1)
                dx = np.full(i1 - i0, binw_x)
                dx[0] -= (a - i0 * binw_x); dx[-1] -= ((i1) * binw_x - b)
                dx = np.maximum(dx, 0.0)
                vol = TVL * dx / 1e4
                edge = (g - ybar[sl] - h) if up else (ybar[sl] - g - h)
                fee = vol * h * 1e-4
                loss = np.maximum(edge, 0.0) * vol * 1e-4
                fee_b[sl] += fee; loss_b[sl] += loss; cross_b[sl] += dx / binw_x
                fee_tot += fee.sum(); loss_tot += loss.sum()
            x = xstar
        if abs(g) >= theta or (t[i] - last_push) >= hb:   # keeper push: mark := crossing close
            M = lg[i]; last_push = t[i]; pushes += 1
        # noise: two-sided uninformed flow at current quote, pays fee h
        if rng.random() < NOISE_P:
            v = noise_mean * rng.lognormal(-0.5, 1.0)
            dxn = v / TVL * 1e4 * (1 if rng.random() < 0.5 else -1)
            x2 = min(max(x + dxn, 0.0), 1e4)
            a, b = (x, x2) if x2 > x else (x2, x)
            i0, i1 = int(a / binw_x), min(int(b / binw_x) + 1, NB)
            if i1 > i0:
                sl = slice(i0, i1)
                dx = np.full(i1 - i0, binw_x)
                dx[0] -= (a - i0 * binw_x); dx[-1] -= (i1 * binw_x - b)
                dx = np.maximum(dx, 0.0)
                vol = TVL * dx / 1e4
                fee = vol * h * 1e-4
                fee_b[sl] += fee; cross_b[sl] += dx / binw_x
                fee_tot += fee.sum()
            x = x2
        if x <= binw_x or x >= 1e4 - binw_x: pinned += 1
        dwell_b[int(min(x, 1e4 - 1e-9) / binw_x)] += 1
        y_path[i] = np.interp(x, xe, ye)
    return dict(fee_b=fee_b, loss_b=loss_b, cross_b=cross_b, dwell_b=dwell_b,
                y_path=y_path[1:], g_path=g_path[1:], pushes=pushes, pinned=pinned,
                fee_tot=fee_tot, loss_tot=loss_tot, n=n - 1)

def wq_abs(vals, w, qs=(0.5, 0.7, 0.99)):
    a = np.abs(vals); i = np.argsort(a); cw = np.cumsum(w[i]); cw = cw / cw[-1]
    return [round(float(np.interp(q, cw, a[i])), 3) for q in qs]

res = run_sim()
ay = np.abs(ybar)
# consumption density (fee-flow-weighted curve-offset level) + dwell + value profile
q_fee = wq_abs(ybar, res["fee_b"])
q_cross = wq_abs(ybar, res["cross_b"])
q_dwell = wq_abs(res["y_path"], np.ones(res["n"]))
# per-unit-depth annualized net value by |y| decile of curve offset
depth_bin = TVL * binw_x / 1e4
# marginal value per unit depth by |y| band (12 bands over support): fee/loss/net %APR
bands = np.linspace(0, S_dep, 13)
prof = []
for a, b in zip(bands[:-1], bands[1:]):
    m = (ay >= a) & (ay < b)
    if not m.any(): continue
    dsum = depth_bin * m.sum()
    fe = res["fee_b"][m].sum() / dsum * (365 / span_d) * 100
    lo = res["loss_b"][m].sum() / dsum * (365 / span_d) * 100
    prof.append([round(float(0.5 * (a + b)), 3), round(fe, 1), round(lo, 1), round(fe - lo, 1)])
# outermost |y| where the band net value is still positive
y_support = 0.0
for p in prof:
    if p[3] > 0: y_support = p[0]

# D1 current basis: time-sampled offset-from-mark (truth vs frozen mark)
q_d1 = wq_abs(res["g_path"], np.ones(res["n"]))
# D2 channel-divergence: EMA gravity centers over 3 TFs (1h/4h/24h)
def ema(x, nbar):
    a = 2.0 / (nbar + 1); out = np.empty_like(x); out[0] = x[0]
    for i in range(1, len(x)): out[i] = a * x[i] + (1 - a) * out[i - 1]
    return out
div = []
for nbar in (360, 1440, 8640):
    c = ema(lg, nbar); div.append(1e4 * (lg[nbar:] - c[nbar:]))
div = np.concatenate(div)
div = div[np.abs(div) <= clip]
q_d2 = wq_abs(div, np.ones(len(div)))

# endogeneity fixed-point (ITER=1, PROBE runs): redeploy curve shaped to measured
# crossing density, re-run, report drift of the normalized consumption density
iter_out = None
if PROBE and os.environ.get("ITER", "") == "1":
    c0 = res["cross_b"] + res["cross_b"][::-1]           # symmetrize
    c0 = np.maximum(c0, 0.01 * c0.max())                 # floor (monotone-C2 proxy)
    xs_nat = np.linspace(-W, W, NB); f = c0
    cdf = np.concatenate([[0], np.cumsum(0.5 * (f[1:] + f[:-1]) * np.diff(xs_nat))]); cdf /= cdf[-1]
    xe, ye, ybar, x_of_y = build_curve(S_dep)
    res2 = run_sim(seed=SEED + 1)
    c1 = res2["cross_b"] + res2["cross_b"][::-1]
    # compare normalized densities in y-space (map both onto common |y| quantiles)
    q1 = wq_abs(ybar, res2["cross_b"])
    n0 = c0 / c0.sum(); n1 = c1 / max(c1.sum(), 1e-12)
    iter_out = dict(q_crossings_iter2=q1, drift_L1=round(float(np.abs(n0 - n1).sum()), 3),
                    netAPR_iter2=round((res2["fee_tot"] - res2["loss_tot"]) / TVL * (365 / span_d) * 100, 2))

apr_fee = res["fee_tot"] / TVL * (365 / span_d) * 100
apr_loss = res["loss_tot"] / TVL * (365 / span_d) * 100
out = dict(sym=SYM, theta_mult=THETA_MULT, theta=round(theta, 3), h=round(h, 3),
           S_dep=round(S_dep, 3), regime=f"{regime} W{W}", span_d=round(span_d, 1),
           pushes_h=round(res["pushes"] / (span_d * 24), 1),
           pinned_pct=round(100 * res["pinned"] / res["n"], 2),
           feeAPR=round(apr_fee, 2), lossAPR=round(apr_loss, 2), netAPR=round(apr_fee - apr_loss, 2),
           q_consumption_fee=q_fee, q_crossings=q_cross, q_middwell=q_dwell,
           q_D1_offmark=q_d1, q_D2_channel=q_d2, y_support_pos=round(y_support, 3),
           v_profile=prof, iter2=iter_out)
print(json.dumps(out))
