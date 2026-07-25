#!/usr/bin/env python3
"""proto_lognormal_plateau.py — PROTOTYPE (unstaged; owner review + referee_sim gate before adoption).

Formalizes the owner 2026-07-22 log-normal-plateau minimal-knot spec. LOCKED decisions
(measured on USDT/FDUSD/BTC 14d 10s tapes, out/lognormal_plateau.json):

 1. DECOMPOSITION VERDICT (ell = G + U + Y): G+U alone is UNIMODAL at 0 on all assets;
    the channel term Y owns the bimodal (M-shape) structure. The hard clip(d,±2θ) puts a
    literal Dirac ATOM at the rail (fine-bin mass 57.9/74.9/80.8%); LOCKED SOFT-SAT
        Y = R·tanh(d/R),  R = 2θ_final     (odd, slope 1 at 0, |Y|<R strict, C-inf)
    kills the atom (12.8/30.9/63.0% in the same fine bin, no Dirac) + improves
    LN-representability on stables (KL data||LN 0.943->0.842 USDT, 1.013->0.970 FDUSD)
    at minimal quantile distortion vs hard (q50 -6.6/-4.5/-2.7%, q99 <2%).
    HONEST LIMIT: the signed M-shape (crater at 0, shoulders near the rail) survives ANY
    bounded saturation (58-81% of channel mass sits beyond the rail); it is intrinsic and
    is exactly what the truncated-LN unfold models. Single-mode holds in the FOLDED law
    (the law the optimizer fits) under both hard and soft.
 2. TARGET (closed form, zero search, keeper-deterministic): folded |ell_soft| ~ LogNormal
    (mu, sigma) truncated at S. Quantile-matched: mu = ln q50, sigma = ln(q90/q50)/z90,
    S_fit = exp(mu + sigma·z70) (EXACT 30% tail cut by construction), S_dep = max(S_fit, 2θ).
    Signed target = symmetric unfold on [-S,S]. KEY IDENTITY: the S-normalized quantile
    curve is exp(sigma·(PPF(0.7·v) - z70)) — depends on sigma ONLY (mu is pure scale,
    absorbed by S_dep/dispRef). Whitelist = a sigma-ladder (0.30..0.65 step 0.05) × fixed m:
    keeper SELECTS a pre-certified cell, never emits novel knots (UPKEEP §2.2 preserved).
    Measured: USDT σ=0.601, FDUSD σ=0.536, BTC σ=0.385.
 3. MINIMAL-KNOT: m segments (= m-1 interior knots, 1+2m slots). Layout LOCKED pow2.0
    (center-clustered); weights via one BVLS solve (dw>=0, Σdw=2) on the quantile curve.
    TOLERANCE: truncated-KL(LN target || spline) <= 0.25 nats on 81 signed bins (max-density
    -err is the WRONG metric here: the minimal-m spline deliberately rounds the LN crater,
    36-97% center err BY DESIGN, and beats the exact LN against the DATA: KL data||spline
    0.032-0.087 at m=2-3 vs data||LN 0.84-1.36; over-fit worsens it to 0.23-0.26 at m=10).
    RECOMMENDED: m=3 stables / m=4 volatiles (gate-picked), fixed per asset class, never >5.
    Gas (NUQuarticSetGas.t.sol): update path m=3 289.8k / m=4 384.2k / m=5 478.6k vs
    m=10 presets 951.3k (-70% at m=3); ~94.5k gas per extra segment.

Reuses make_density_overlay.py machinery verbatim (exec of the defs section — single
source, no parallel estimator). Reads tapes read-only; writes ONLY out/lognormal_plateau.json.
Run: python3 proto_lognormal_plateau.py
"""
import json, math
from pathlib import Path
import numpy as np
from scipy.interpolate import BSpline
from scipy.optimize import lsq_linear
from scipy.signal import find_peaks
from scipy.stats import norm

HERE = Path(__file__).parent
_src = open(HERE / "make_density_overlay.py").read()
exec(compile(_src[:_src.index("# ── per-asset pipeline ──")], "make_density_overlay.py[defs]", "exec"))
# in scope now: load_tape, push_offsets, theta_for_rate, session_mask, wq, flow_ema_div,
# ewma_var, trunc_kl_js, PRESETS, GRID, V2, CLASS, TAU_INV, CAP_RATE_H, N_DRAWS

ASSETS = [  # sym, cls, tape (2 stables + 1 volatile per owner ask)
    ("USDT",  "stable",   "USDT-USDC.json"),
    ("FDUSD", "stable",   "FDUSD-USDC.json"),
    ("BTC",   "volatile", "BTC-USDC.json"),
]
Q_TRUNC = 0.70            # truncation quantile: 30% tail cut (owner spec, = existing cut-band target)
Z70 = float(norm.ppf(Q_TRUNC))
NB_KL = 81                # headline binning (same as trunc_kl_js NBINS[1])
BPS = 10_000

# ── 1. components (mirror of fit_asset lines 297-351, minus fitting) ──────────────────────
def components(sym, cls, tape):
    cl = CLASS[cls]
    ts, close, vol, ok, tf, clip = load_tape(tape)
    th = theta_for_rate(ts, close, ok, CAP_RATE_H, cl["hb"], clip, cl["theta"])
    G, pushes, span_h, _ = push_offsets(ts, close, ok, th, cl["hb"], clip)
    idx = np.flatnonzero(ok)
    t, p, v = ts[idx], close[idx], vol[idx]
    r1 = np.concatenate([[0.0], 1e4 * np.diff(np.log(p))])
    r1sq = np.where(np.abs(r1) > clip, 0.0, r1 ** 2)
    dt = np.minimum(np.diff(t, prepend=t[0]), 3 * tf)
    sig2 = ewma_var(r1sq, t, 30 * tf)
    sig2 = np.maximum(sig2, np.quantile(sig2[sig2 > 0], 0.10))
    tau0 = TAU_INV[cls]
    taus = (tau0 / 2, tau0, 2 * tau0)
    burn = t > t[0] + 3 * max(taus)
    d3_s, d3_w = [], []
    for tau in taus:
        d1 = flow_ema_div(t, p, v, tf, tau)
        b1 = t > t[0] + 3 * tau
        h_w = float(wq(np.abs(d1[b1]), dt[b1], 0.70))
        d2 = flow_ema_div(t, p, v, tf, tau, h_w)
        m = burn & (np.abs(d2) <= clip)
        d3_s.append(d2[m]); d3_w.append(dt[m] * sig2[m] / 3.0)
    d3 = np.concatenate(d3_s); w = np.concatenate(d3_w); w = w / w.sum()
    return dict(sym=sym, th=th, G=G, d3=d3, d3w=w, cad=pushes / span_h)

# ── saturation candidates (R = 2θ rail; odd, slope 1 at 0, |y| <= R) ──────────────────────
SATS = {
    "hard": lambda d, R: np.clip(d, -R, R),
    "tanh": lambda d, R: R * np.tanh(d / R),
    "alg":  lambda d, R: d / np.sqrt(1.0 + (d / R) ** 2),
    "rat":  lambda d, R: d / (1.0 + np.abs(d) / R),
}

def draws(c):
    rng = np.random.default_rng(7)
    Gd = rng.choice(c["G"], N_DRAWS)
    Ud = rng.uniform(-c["th"], c["th"], N_DRAWS)
    Dd = rng.choice(c["d3"], N_DRAWS, p=c["d3w"])   # SAME channel draws for every sat: paired test
    return Gd, Ud, Dd

def fold_modes(x, prom=0.02, nb=201, smooth=3):
    """modes of the folded |x| density, reflection-padded at 0 so the boundary mode is
    detectable: (pos, height/max, prominence/max). prom = 2% of peak."""
    a = np.abs(x); xmax = float(np.quantile(a, 0.999))
    h, e = np.histogram(a, bins=nb, range=(0, xmax), density=True)
    hs = np.convolve(h, np.ones(smooth) / smooth, "same")
    pad = np.r_[hs[::-1], hs]                          # even reflection across 0
    pk, pr = find_peaks(pad, prominence=prom * hs.max())
    ctr = 0.5 * (e[:-1] + e[1:])
    out = []
    for j, i in enumerate(pk):
        if i < nb - 1: continue                        # mirror-side duplicate
        k = i - nb
        out.append((round(float(ctr[k]), 3), round(float(hs[k] / hs.max()), 3),
                    round(float(pr["prominences"][j] / hs.max()), 3)))
    return out

def signed_stats(x, prom=0.02, nb=321):
    """SIGNED-density structure (this is where the bimodal artifact lives; the folded law
    hides it): modes (pos, height/max), trough = f(0)/f_peak, and peak sharpness."""
    S = float(np.quantile(np.abs(x), 0.995))
    h, e = np.histogram(x, bins=nb, range=(-S, S), density=True)
    hs = np.convolve(h, np.ones(5) / 5, "same")
    pk, _ = find_peaks(hs, prominence=prom * hs.max())
    ctr = 0.5 * (e[:-1] + e[1:])
    return dict(modes=[(round(float(ctr[i]), 3), round(float(hs[i] / hs.max()), 3)) for i in pk],
                nmodes=len(pk), trough=round(float(hs[nb // 2] / hs.max()), 3))

def chan_atom(Y, R, nfine=400):
    """channel-law rail atom: mass in the outermost fine bin [R(1-1/nfine), R] of |Y|.
    hard clip -> literal Dirac atom (this IS the degenerate 2nd mode); soft sat -> ~0."""
    return float(np.mean(np.abs(Y) >= R * (1.0 - 1.0 / nfine)))

# ── 2. truncated-LN target (closed form, zero search) ─────────────────────────────────────
Z90 = float(norm.ppf(0.90))

def ln_fit(ell):
    """quantile-matched LN: mu = ln q50, sigma = ln(q90/q50)/z90. Robust to the near-zero
    mass that wrecks log-moments (log-moment sigma ~1.0 vs quantile ~0.6 on USDT); pins the
    BODY the fee kernel earns on. Deterministic, closed form."""
    q50, q90 = np.quantile(np.abs(ell), [0.5, 0.90])
    mu = float(np.log(q50)); sg = float(np.log(q90 / q50) / Z90)
    return mu, sg, float(np.exp(mu + sg * Z70))

def ln_fit_logmom(ell):
    a = np.abs(ell); a = a[a > 1e-12]
    mu = float(np.mean(np.log(a))); sg = float(np.std(np.log(a)))
    return mu, sg, float(np.exp(mu + sg * Z70))

def ln_folded_cdf(rho, mu, sg, S):
    """CDF of |x| under LN(mu,sg) truncated at S (mass 1 on [0,S])."""
    z = norm.cdf((np.log(np.maximum(rho, 1e-300)) - mu) / sg)
    return np.clip(z / norm.cdf((math.log(S) - mu) / sg), 0, 1)

def ln_bin_mass(edges, mu, sg, S):
    """target mass per signed bin on [-S,S] (symmetric unfold of the folded law)."""
    F = lambda x: 0.5 * (1.0 + np.sign(x) * ln_folded_cdf(np.abs(x), mu, sg, S))
    m = np.diff(F(np.asarray(edges, float)))
    return np.maximum(m, 0)

def kl_bins(P, Q):
    P = np.maximum(P, 0); Q = np.maximum(Q, 1e-12)
    P = P / P.sum(); Q = Q / Q.sum()
    m = P > 0
    return float(np.sum(P[m] * np.log(P[m] / Q[m])))

def kl_data_vs_ln(ell, mu, sg, S, Sd, nb=NB_KL):
    """truncated-support KL, SAME convention as trunc_kl_js: obs restricted to [-Sd,Sd]
    and renormalized (outside mass DROPPED, never clipped into the edge bins)."""
    edges = np.linspace(-Sd, Sd, nb + 1)
    P, _ = np.histogram(ell[np.abs(ell) <= Sd], bins=edges)
    P = P.astype(float)
    Q = ln_bin_mass(edges, mu, sg, max(S, Sd))
    return kl_bins(P, Q)

# ── 3. minimal-knot NUQuartic fit (clamped quartic, m segs, dw>=0, C2 density) ────────────
def bspline_cols(t, n, x, deriv=0):
    cols = []
    for i in range(n):
        c = np.zeros(n); c[i] = 1.0
        s = BSpline(t, c, 4)
        cols.append((s.derivative(deriv) if deriv else s)(x))
    return np.column_stack(cols)

def target_quantile(u, mu, sg, S):
    """signed quantile (units of S, y in [-1,1]) of the symmetric truncated-LN at depth u in [0,1]."""
    v = 2.0 * np.abs(u - 0.5)                        # folded prob
    FS = norm.cdf((math.log(S) - mu) / sg)
    rho = np.exp(mu + sg * norm.ppf(np.clip(v * FS, 1e-12, 1 - 1e-12)))
    return np.sign(u - 0.5) * np.minimum(rho / S, 1.0)

def knot_layouts(m):
    """deterministic symmetric interior-knot candidates (normalized u in (0,1)), m segments."""
    base = np.arange(1, m) / m
    outs = {"uniform": base, "cheb": (1 - np.cos(np.pi * base)) / 2}
    for b in (0.5, 0.7, 1.4, 2.0):                   # power-symmetric: b>1 center-cluster, b<1 edge-cluster
        outs[f"pow{b}"] = 0.5 * (1 + np.sign(2 * base - 1) * np.abs(2 * base - 1) ** b)
    return outs

def fit_spline(m, interior_u, mu, sg, S, ngrid=2001):
    """LSQ fit of clamped quartic weights to the truncated-LN quantile curve, dw>=0.
    Returns (w, knot vector t, curve rmse)."""
    t = np.r_[[0.0] * 5, interior_u, [1.0] * 5]
    n = m + 4
    u = np.linspace(0, 1, ngrid)
    y = target_quantile(u, mu, sg, S)
    B = bspline_cols(t, n, u)
    # w = -1 + L dw (L = lower-tri ones incl diag from index 1); w0 = -1; sum dw = 2 (y(1)=+1)
    L = np.tril(np.ones((n, n)))[:, 1:]              # w_i = w0 + sum_{j<=i} dw_j
    A = B @ L; b = y - (-1.0) * B.sum(1)
    Aeq = np.full((1, n - 1), 1e3); beq = np.array([2e3])   # heavy equality row: sum dw = 2
    res = lsq_linear(np.vstack([A, Aeq]), np.r_[b, beq], bounds=(0, np.inf), method="bvls")
    dw = res.x
    w = np.r_[-1.0, -1.0 + np.cumsum(dw)]
    return w, t, float(np.sqrt(np.mean((B @ w - y) ** 2)))

def spline_metrics(w, t, mu, sg, S, nb=NB_KL, ngrid=4001):
    """offset-space density of the fitted curve vs the LN target: KL + max density err."""
    n = len(w)
    u = np.linspace(0, 1, ngrid)
    y = bspline_cols(t, n, u) @ w                    # monotone in [-1,1]
    y = np.clip(y, -1, 1)
    edges = np.linspace(-1, 1, nb + 1)
    uu = np.interp(edges, y, u)                      # depth measure of each offset bin
    Qm = np.maximum(np.diff(uu), 0)
    Pm = ln_bin_mass(edges * S, mu, sg, S)
    kl = kl_bins(Pm, Qm)
    bw = np.diff(edges)
    fT = Pm / bw / Pm.sum(); fS = Qm / bw / max(Qm.sum(), 1e-12)
    maxerr = float(np.max(np.abs(fS - fT)) / np.max(fT))
    # shape diagnostics of the fitted density (folded): modes + plateau stats
    dens = fS[nb // 2:]                               # right half (symmetric)
    pk, pr = find_peaks(np.r_[dens[0], dens, 0], prominence=0.03 * dens.max())
    trough = float(fS[nb // 2] / fS.max())            # center density / peak
    return kl, maxerr, len(pk), trough

def spline_bins(w, t, S, Sd, nb=NB_KL, ngrid=4001):
    """spline bin masses on [-Sd,Sd] (bp units), for end-to-end data KL."""
    n = len(w)
    u = np.linspace(0, 1, ngrid)
    y = np.clip(bspline_cols(t, n, u) @ w, -1, 1) * S
    edges = np.linspace(-Sd, Sd, nb + 1)
    uu = np.interp(edges, y, u, left=0.0, right=1.0)
    return np.maximum(np.diff(uu), 0)

# ── gas (measured: evm/test/gas/NUQuarticSetGas.t.sol, forge 2026-07-22) ──────────────────
# coldFirstSet = in-test first write (only m=2 has truly virgin slots; later probes reuse).
# prod paths reconstructed: update (nonzero->nonzero, cold acct) = warmCompute + 5000/slot;
# firstSet (zero->nonzero) = warmCompute + 22100/slot. warmCompute = warm re-set - 100/slot.
GAS_WARM = {2: 171_085, 3: 255_531, 4: 340_071, 5: 424_728, 6: 509_529, 10: 848_421, 14: 1_188_432}
def gas_table():
    out = {}
    for m, warm in GAS_WARM.items():
        slots = 1 + 2 * m
        compute = warm - 100 * slots
        out[m] = dict(slots=slots, compute=compute, update=compute + 5000 * slots,
                      firstSet=compute + 22_100 * slots)
    return out

# ── run ───────────────────────────────────────────────────────────────────────────────────
TOL_KL_REP = 0.25        # good-enough gate: truncated-KL(LN target || spline), 81 bins, nats
M_CAND = (2, 3, 4, 5, 6, 8, 10)
OUT = {"gen": "proto_lognormal_plateau.py (owner spec 2026-07-22)", "q_trunc": Q_TRUNC,
       "tolKlRep": TOL_KL_REP, "gas": gas_table(), "assets": {}}
for sym, cls, tape in ASSETS:
    c = components(sym, cls, tape)
    th = c["th"]; R = 2 * th
    Gd, Ud, Dd = draws(c)
    atom = float(np.mean(np.abs(Dd) >= R))           # rail-atom mass of the clipped channel draw
    row = dict(theta=round(th, 3), rail=round(R, 3), cadencePerH=round(c["cad"], 1),
               railAtomPct=round(100 * atom, 1),
               baselineNoY=signed_stats(Gd + Ud),    # G+U alone: unimodal at 0 -> Y owns the artifact
               sats={})
    for name, f in SATS.items():
        Y = f(Dd, R)
        ell = Gd + Ud + Y
        mu_s, sg_s, S_s = ln_fit(ell)                # per-sat LN fit: which sat is most LN-representable
        Sd_s = max(S_s, R)
        q = wq(np.abs(ell), np.full(N_DRAWS, 1 / N_DRAWS), [0.5, 0.70, 0.90, 0.99])
        row["sats"][name] = dict(
            chanAtomPct=round(100 * chan_atom(Y, R), 1),   # fine-bin mass AT the rail (Dirac evidence)
            signed=signed_stats(ell), foldModes=fold_modes(ell),
            klDataVsLN=round(kl_data_vs_ln(ell, mu_s, sg_s, S_s, Sd_s), 4),
            q50=round(float(q[0]), 3), q70=round(float(q[1]), 3),
            q90=round(float(q[2]), 3), q99=round(float(q[3]), 3))
    ell_soft = Gd + Ud + SATS["tanh"](Dd, R)         # LOCKED soft-sat
    mu, sg, S = ln_fit(ell_soft)
    Sd = max(S, R)                                   # deployed floor (S_dep >= 2θ, unchanged rule)
    modeBp = math.exp(mu - sg * sg)
    row["ln"] = dict(mu=round(mu, 4), sigma=round(sg, 4), S_fit=round(S, 3), S_dep=round(Sd, 3),
                     cutPct=30.0, modeBp=round(modeBp, 3), modeOverS=round(modeBp / S, 3),
                     klDataVsLN=row["sats"]["tanh"]["klDataVsLN"],
                     dataTrough=row["sats"]["tanh"]["signed"]["trough"])
    # minimal-knot curve (Pdata truncated-renorm, same convention as the optimizer)
    edgesD = np.linspace(-Sd, Sd, NB_KL + 1)
    Pdata, _ = np.histogram(ell_soft[np.abs(ell_soft) <= Sd], bins=edgesD)
    Pdata = Pdata.astype(float)
    row["knots"] = []
    for m in M_CAND:
        best = None
        for lay, ku in knot_layouts(m).items():
            w, t, rmse = fit_spline(m, ku, mu, sg, S)
            kl, maxerr, nmod, trough = spline_metrics(w, t, mu, sg, S)
            if best is None or kl < best["klRep"]:
                Qd = spline_bins(w, t, S, Sd)
                best = dict(m=m, interiorKnots=m - 1, slots=1 + 2 * m, layout=lay,
                            klRep=round(kl, 5), maxDensErrPct=round(100 * maxerr, 2),
                            klDataVsSpline=round(kl_bins(Pdata, Qd), 4),
                            modesFolded=nmod, troughDepth=round(trough, 4),
                            curveRmsePct=round(100 * rmse, 3),
                            gasUpdate=OUT["gas"].get(m, {}).get("update"),
                            w=[round(float(x), 4) for x in w],
                            knotsU=[round(float(x), 4) for x in t[5:-5]])
        row["knots"].append(best)
    rec = next((k for k in row["knots"] if k["m"] >= 3 and k["klRep"] <= TOL_KL_REP
                and k["modesFolded"] == 1), row["knots"][-1])
    row["recommendedM"] = rec["m"]
    OUT["assets"][sym] = row
    print(f"{sym}: θ={th:.3f} rail=±{R:.3f} chanAtom hard={row['sats']['hard']['chanAtomPct']}% "
          f"tanh={row['sats']['tanh']['chanAtomPct']}% | signed modes hard={row['sats']['hard']['signed']['nmodes']}"
          f"(trough {row['sats']['hard']['signed']['trough']}) tanh={row['sats']['tanh']['signed']['nmodes']}"
          f"(trough {row['sats']['tanh']['signed']['trough']}) noY={row['baselineNoY']['nmodes']} | "
          f"KL(data,LN) hard={row['sats']['hard']['klDataVsLN']} tanh={row['sats']['tanh']['klDataVsLN']} | "
          f"LN μ={mu:.3f} σ={sg:.3f} S={S:.3f} -> rec m={rec['m']}", flush=True)
    for k in row["knots"]:
        print(f"   m={k['m']} ({k['interiorKnots']} knots, {k['slots']} slots, {k['layout']}): "
              f"KLrep={k['klRep']:.5f} maxErr={k['maxDensErrPct']}% KLdata={k['klDataVsSpline']:.4f} "
              f"trough={k['troughDepth']} gasUpd={k['gasUpdate']}", flush=True)

json.dump(OUT, open(HERE / "out" / "lognormal_plateau.json", "w"), indent=1)
print("wrote out/lognormal_plateau.json")
