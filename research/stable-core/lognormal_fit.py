#!/usr/bin/env python3
"""lognormal_fit.py - production density optimizer, CENTRAL-NORMAL PLATEAU (owner-FINAL 2026-07-24).

Shape is FROZEN and owner-approved; this script no longer searches over it. ONE table-top family
for BOTH classes: signed quote offset ~ N(0, sigma_g) truncated at the empirical q70 (30% folded
tail cut), m=3 (2 interior knots bracketing the mark at +-0.7 sigma, u = {0.1314, 0.8686}), density
FLAT/max at the mark rolling off symmetrically to the walls. A_WALL is pinned by the exact 30% cut,
so the S-normalized curve is CELL-INVARIANT: stables and volatiles share one preset shape and
differ ONLY by width S_dep. 7 slots = the cheapest preset in the ladder (~289k gas setCurve, -70%).
The prior SPLIT (stables plateau / volatiles peaked Student-t) is RETIRED - both craters/spikes at
the mark; the peaked/plateau machinery is retained only as the referee's diagnostic baselines.

Retained machinery: closed-form truncated-LN quantile fit (mu, sigma) for the sigma-cell snap +
reporting, central-normal fit for the DEPLOYED scale, soft-sat tanh composite, minimal-knot BVLS
certified OFFLINE per (family, cell, m), monotone dw>=0 C2 NUQuartic, and the risk-param leg
(S_dep -> W/minDisp/maxDisp, minFee = 2theta + E[(|G|-theta)+], vetoes, bounded-delta dispatch).
Keeper path stays deterministic + search-free: streaming quantiles -> closed-form (mu, sigma, S) ->
ladder snap -> table lookup; BVLS runs OFFLINE only.

Reuses make_density_overlay.py machinery verbatim (exec of the defs section - single estimator
source) + the locked decisions measured in proto_lognormal_plateau.py (soft-sat tanh R=2theta,
Q_TRUNC=0.70, pow2.0 knot layouts, KLrep tolerance 0.25). Reads tapes read-only; writes ONLY
out/lognormal_fit.json. Does NOT touch make_density_overlay.py / fit_results.json / referee_sim.py
(v4 candidates pending owner + referee).

Run: python3 lognormal_fit.py            (full Sepolia roster; flow-EMA loops dominate)
     ONLY=USDT,BTC python3 lognormal_fit.py
Then: referee_lognormal.py (damped lambda=0.4 J gate) -> emit_prod_params.py (fit_results.json).
"""
import json, math, os
from pathlib import Path
import numpy as np
from scipy.interpolate import BSpline
from scipy.optimize import lsq_linear
from scipy.signal import find_peaks
from scipy.stats import norm, t as tdist

HERE = Path(__file__).parent
_src = open(HERE / "make_density_overlay.py").read()
exec(compile(_src[:_src.index("# ── per-asset pipeline ──")], "make_density_overlay.py[defs]", "exec"))
# in scope: A (asset roster), load_tape, push_offsets, theta_for_rate, session_mask, wq,
# flow_ema_div, ewma_var, SEGS, CLASS, TAU_INV, CAP_RATE_H, N_DRAWS, FROZEN_S

# ── locked constants (unified spec section 6) ─────────────────────────────────────────────
# Full Sepolia fittable roster (every asset with a tape). WETH/WBTC/cbBTC are NOT here: they are
# wrapper legs that route the ETH/BTC fit verbatim (emit_prod_params.py expands them). USDC is the
# base numeraire (mark identity 1.0, never pushed) and carries the class-default row, not a fit.
TARGETS = ["USDT", "USDE", "USDS", "DAI", "USD1", "USDG", "PYUSD", "RLUSD", "syrupUSDC", "USDF",
           "U", "GHO", "TUSD", "USDTB", "FDUSD", "AUSD",
           "EURC", "BTC", "ETH", "BNB", "CAKE", "XAUT", "PAXG"]
ONLY = set(filter(None, os.environ.get("ONLY", "").split(",")))
Q_TRUNC = 0.70                                  # 30% tail cut, exact by construction
Z70 = float(norm.ppf(Q_TRUNC)); Z90 = float(norm.ppf(0.90))
NB_KL = 81
TOL_KL_REP = 0.25                               # good-enough gate (nats, LN target || spline)
SIGMA_CELLS = np.round(np.arange(0.30, 0.651, 0.05), 2)         # 8-cell ladder
SIGMA_BAND = (0.275, 0.675)                     # outside -> FREEZE at last-good + alert
KNOTS_U = {3: [0.4444, 0.5556],                 # pow2.0 layouts, LOCKED (proto verdict) - plateau
           4: [0.375, 0.5, 0.625],
           5: [0.32, 0.48, 0.52, 0.68]}
KNOTS_U_PK = {4: [0.1464, 0.5, 0.8536],         # pow0.5 EDGE-clustered, LOCKED for the peaked family
              5: [0.1127, 0.2764, 0.7236, 0.8873]}
# ── central-normal plateau (owner 2026-07-24): ONE table-top shape for BOTH classes ──────
# Owner DROPPED the split (the LN plateau craters at the mark -> reads as an M/dome not a
# table; the peaked t-core spikes). New target: signed offset ~ N(0, sigma_g) truncated at
# S = A_WALL*sigma_g. Density is FLAT/max at the mark, rolls off symmetrically to the walls
# -> a genuine rounded table. A_WALL is FIXED by the exact 30% folded tail cut, so the
# S-normalized curve is CELL-INVARIANT: stables and volatiles differ ONLY by width (S_dep),
# never by shape. Two interior knots BRACKET the center at +-BRACKET_SIGMA (owner sketch):
# the middle segment carries the near-flat top (~zero curvature), the two outer segments the
# shoulder roll-off. m=3 = 2 interior knots = 7 slots = cheapest preset in the ladder.
A_WALL = float(norm.ppf(0.85))                  # 1.0364: wall in sigmas at the exact 30% folded cut
F_NM = 2.0 * float(norm.cdf(A_WALL)) - 1.0      # = 0.70 by construction
BRACKET_SIGMA = 0.7                             # owner sketch: knots bracket the center at +-0.7 sigma
_VK = (2.0 * float(norm.cdf(BRACKET_SIGMA)) - 1.0) / F_NM       # folded-prob of the +-0.7 sigma bracket
KNOTS_U_CN = {3: [round(0.5 - _VK / 2, 4), round(0.5 + _VK / 2, 4)],        # 2 interior knots @ +-0.7 sigma
              4: [round(0.5 - _VK / 2, 4), 0.5, round(0.5 + _VK / 2, 4)],   # +center pin (flatter top)
              5: [round(0.5 - _VK / 2, 4), 0.31, 0.69, round(0.5 + _VK / 2, 4)]}
FAMILY = {"stable": "cnplateau", "volatile": "cnplateau"}  # owner 2026-07-24: plateau EVERYWHERE
NU_PK = 1.5                                     # peaked = truncated Student-t core (v4 lepto kernel)
C_OF_SIGMA = 0.55                               # peak-width ratio c = 0.55*sigma_cell; anchored so
                                                # cell 0.40 -> c = 0.22 = v4 lepto sFat/W exactly
FAM_M = {"cnplateau": (3, 4, 5), "plateau": (3, 4, 5), "peaked": (4, 5)}
FAM_KNOTS = {"cnplateau": KNOTS_U_CN, "plateau": KNOTS_U, "peaked": KNOTS_U_PK}
M_GATE = {"stable": (3, 4, 5), "volatile": (3, 4, 5)}          # class default first, escalate only
W_LADDER = (0.5, 1, 2, 5)                       # bp, ceil, cap 5 (excess -> minDisp scaling)
DISP_REF = {"stable": 100, "volatile": 500}     # pbps; hyper-50 tier RETIRED
MINFEE_HARD_PBPS = {"stable": 50, "volatile": 100}
FENCE_REL = 0.25                                # AdminRiskSteward +-25% per update (risk-up)
DEADBANDS = dict(sigma=0.05, scaleTight=0.22, scaleLoose=0.41, feeTight=0.18, feeLoose=0.41,
                 note="SEED values; calibrate tau_*/halflives on faithful_sim.ts before arming")
HILL_K = 4000                                   # top 1% of N_DRAWS for the tail-alpha veto
N_DIP = 5000; N_DIP_NULL = 200                  # dip test: subsample + MC null size
Q = 10 ** 9                                     # NUQuartic pbps fixed point
FLAG_REQUIRES_WALL = 1

# ── Hartigan-Hartigan dip test (self-contained; validated vs published critical values:
#    null q95 = 0.0082 @ n=5000 vs table 0.0082; clean unimodal/bimodal discrimination) ────
def _gcm(cdf, x):
    wc, wx = cdf, x
    out = [wc[0]]; touch = [0]
    while len(wc) > 1:
        dist = wx[1:] - wx[0]
        slopes = (wc[1:] - wc[0]) / dist
        j = int(np.argmin(slopes)) + 1
        out.extend(wc[0] + dist[:j] * slopes[j - 1])
        touch.append(touch[-1] + j)
        wc = wc[j:]; wx = wx[j:]
    return np.asarray(out), np.asarray(touch)

def _lcm(cdf, x):
    g, t = _gcm(1.0 - cdf[::-1], x[-1] - x[::-1])
    return 1.0 - g[::-1], (len(cdf) - 1 - t)[::-1]

def dip_stat(x):
    vals, cnts = np.unique(np.asarray(x, float), return_counts=True)
    p = cnts.astype(float) / cnts.sum()
    cdf = np.cumsum(p)
    wx, wp, wc = vals, p, cdf
    D = 0.0; left = [0.0]; right = [1.0]
    while True:
        lp, lt = _gcm(wc - wp, wx)
        rp, rt = _lcm(wc, wx)
        dl = np.abs(rp[lt] - lp[lt]); d_left = dl.max()
        dr = np.abs(rp[rt] - lp[rt]); d_right = dr.max()
        if d_right > d_left:
            xr = rt[dr == d_right][-1]; xl = lt[lt <= xr][-1]; d = d_right
        else:
            xl = lt[dl == d_left][0]; xr = rt[rt >= xl][0]; d = d_left
        if d <= D or xr == 0 or xl == len(wc) - 1:
            return max(np.abs(cdf[:len(left)] - np.asarray(left)).max(),
                       np.abs(cdf[-len(right):] - np.asarray(right)).max()) / 2.0
        D = max(D, float(np.abs(lp[:xl + 1] - wc[:xl + 1] + wp[:xl + 1]).max()),
                   float(np.abs(rp[xr:] - wc[xr:]).max()))
        left.extend(lp[1:xl + 1]); right[:0] = rp[xr:-1]
        wc = wc[xl:xr + 1]; wp = wp[xl:xr + 1]; wx = wx[xl:xr + 1]

_rngN = np.random.default_rng(13)
DIP_NULL = np.sort([dip_stat(_rngN.uniform(size=N_DIP)) for _ in range(N_DIP_NULL)])

def dip_test(a):
    """dip + MC p vs uniform null (least-favorable unimodal). a = folded support sample."""
    sub = np.random.default_rng(11).choice(a, min(N_DIP, len(a)), replace=False)
    d = dip_stat(sub)
    p = float(np.mean(DIP_NULL >= d))
    return dict(stat=round(float(d), 5), p=round(p, 3), n=int(len(sub)), unimodal=bool(p > 0.05))

# ── shape diagnostics (proto_lognormal_plateau.py, verbatim) ──────────────────────────────
def fold_modes(x, prom=0.02, nb=201, smooth=3):
    a = np.abs(x); xmax = float(np.quantile(a, 0.999))
    h, e = np.histogram(a, bins=nb, range=(0, xmax), density=True)
    hs = np.convolve(h, np.ones(smooth) / smooth, "same")
    pad = np.r_[hs[::-1], hs]
    pk, pr = find_peaks(pad, prominence=prom * hs.max())
    return sum(1 for i in pk if i >= nb - 1)

def signed_stats(x, prom=0.02, nb=321):
    S = float(np.quantile(np.abs(x), 0.995))
    h, e = np.histogram(x, bins=nb, range=(-S, S), density=True)
    hs = np.convolve(h, np.ones(5) / 5, "same")
    pk, _ = find_peaks(hs, prominence=prom * hs.max())
    return dict(nmodes=len(pk), trough=round(float(hs[nb // 2] / hs.max()), 3))

# ── truncated-LN target + minimal-knot NUQuartic fit (proto, verbatim) ────────────────────
def ln_fit(ell):
    q50, q90 = np.quantile(np.abs(ell), [0.5, 0.90])
    mu = float(np.log(q50)); sg = float(np.log(q90 / q50) / Z90)
    return mu, sg, float(np.exp(mu + sg * Z70))

def ln_folded_cdf(rho, mu, sg, S):
    z = norm.cdf((np.log(np.maximum(rho, 1e-300)) - mu) / sg)
    return np.clip(z / norm.cdf((math.log(S) - mu) / sg), 0, 1)

def ln_bin_mass(edges, mu, sg, S):
    F = lambda x: 0.5 * (1.0 + np.sign(x) * ln_folded_cdf(np.abs(x), mu, sg, S))
    return np.maximum(np.diff(F(np.asarray(edges, float))), 0)

def kl_bins(P, Qm):
    P = np.maximum(P, 0); Qm = np.maximum(Qm, 1e-12)
    P = P / P.sum(); Qm = Qm / Qm.sum()
    m = P > 0
    return float(np.sum(P[m] * np.log(P[m] / Qm[m])))

#: KL above which the fitted density no longer describes the tape. Clean 24/7
#: majors sit at 0.10; every asset that produced an implausible breadth sat >1.0.
KL_TRUST_MAX = 1.0

def tape_status(span_d, klData, sess, feeQ99):
    """Is this tape trustworthy enough to deploy its breadth unattended?

    Span alone is not the question. PAXG carried 14 clean-looking days and was
    labelled `ok` while its feeQ99 came out at 167 bp against a 13.4 bp q70 shape
    (8x WETH's ratio, klData 1.65) -- the tail was the session-gap open, not
    tradable dispersion, and it would have deployed a 1.7% flat quiet band on
    gold. Meanwhile EURC, the best-fitting non-major at klData 0.15, was
    PROVISIONAL purely for having 4.5 days.

    So: enough span, a density the fit actually reproduces, and -- for assets
    with a session calendar -- a gap-open tail that does not dominate the
    breadth it feeds.
    """
    if span_d < 10 or klData > KL_TRUST_MAX:
        return "PROVISIONAL"
    if sess and feeQ99 and sess.get("b99OpenBp", 0.0) > feeQ99:
        return "PROVISIONAL"
    return "ok"

def kl_data_vs_ln(ell, mu, sg, S, Sd, nb=NB_KL):
    edges = np.linspace(-Sd, Sd, nb + 1)
    P, _ = np.histogram(ell[np.abs(ell) <= Sd], bins=edges)
    return kl_bins(P.astype(float), ln_bin_mass(edges, mu, sg, max(S, Sd)))

# ── peaked (volatile) target: truncated Student-t core, S-normalized, cell-only shape ─────
def pk_folded_cdf(rho, c):
    """CDF of |x|/S under the S-normalized truncated-t(NU_PK, scale c) law (mass 1 on [0,1])."""
    F1 = 2.0 * tdist.cdf(1.0 / c, NU_PK) - 1.0
    return np.clip((2.0 * tdist.cdf(np.minimum(np.abs(rho), 1.0) / c, NU_PK) - 1.0) / F1, 0, 1)

def pk_bin_mass(edges, c):
    """target mass per signed bin on normalized [-1,1] (symmetric truncated-t unfold)."""
    F = lambda x: 0.5 * (1.0 + np.sign(x) * pk_folded_cdf(np.abs(x), c))
    return np.maximum(np.diff(F(np.asarray(edges, float))), 0)

def target_quantile_pk(u, c):
    """signed quantile (y in [-1,1]) of the peaked law at depth u in [0,1]. Depends on c ONLY:
    scale is absorbed by S_dep exactly as mu is for the plateau family."""
    v = 2.0 * np.abs(u - 0.5)
    F1 = 2.0 * tdist.cdf(1.0 / c, NU_PK) - 1.0
    rho = c * tdist.ppf(0.5 * (1.0 + np.clip(v, 0, 1) * F1), NU_PK)
    return np.sign(u - 0.5) * np.minimum(rho, 1.0)

# ── central-normal plateau target: N(0,sigma_g) truncated at S = A_WALL*sigma_g. The
#    S-normalized law depends on A_WALL ALONE (fixed by the 30% cut) -> ONE cell-invariant
#    table shape; sigma_g/S is pure scale, absorbed by S_dep exactly as mu is for the LN. ──
def nm_folded_cdf(rho):
    """CDF of |x|/S under the S-normalized truncated-N law (mass 1 on [0,1])."""
    return np.clip((2.0 * norm.cdf(A_WALL * np.minimum(np.abs(rho), 1.0)) - 1.0) / F_NM, 0, 1)

def nm_bin_mass(edges):
    F = lambda x: 0.5 * (1.0 + np.sign(x) * nm_folded_cdf(np.abs(x)))
    return np.maximum(np.diff(F(np.asarray(edges, float))), 0)

def target_quantile_nm(u):
    """signed quantile (y in [-1,1]) of the central-normal plateau at depth u. Scale-free."""
    v = 2.0 * np.abs(u - 0.5)
    rho = norm.ppf(0.5 * (1.0 + np.clip(v, 0, 1) * F_NM)) / A_WALL
    return np.sign(u - 0.5) * np.minimum(rho, 1.0)

def nm_fit(ell):
    """central-normal plateau scale. Wall = the LITERAL empirical q70 (exact 30% folded tail
    cut on the DATA, not the normal-model 1.5366*q50 which is too wide for heavy tails and
    dilutes near-mark density on volatiles). sigma_g = S_fit/A_WALL is the implied Gaussian
    of the FIXED table shape (A_WALL truncation); the normalized plateau is unchanged, only
    the support width tightens. Closed form, deterministic, no search."""
    S_fit = float(np.quantile(np.abs(ell), Q_TRUNC))   # q70 = exact 30% cut, all assets
    return S_fit / A_WALL, S_fit

def fam_targets(fam, mu, sg, S):
    """(quantile curve, normalized signed bin mass) for a family target. cnplateau is
    scale-free (A_WALL fixed); plateau keys on (mu, sg, S); peaked keys on c = C_OF_SIGMA*sg."""
    if fam == "cnplateau":
        return (target_quantile_nm, nm_bin_mass)
    if fam == "plateau":
        return (lambda u: target_quantile(u, mu, sg, S),
                lambda e: ln_bin_mass(np.asarray(e, float) * S, mu, sg, S))
    c = C_OF_SIGMA * sg
    return (lambda u: target_quantile_pk(u, c), lambda e: pk_bin_mass(e, c))

def bspline_cols(t, n, x):
    cols = []
    for i in range(n):
        c = np.zeros(n); c[i] = 1.0
        cols.append(BSpline(t, c, 4)(x))
    return np.column_stack(cols)

def target_quantile(u, mu, sg, S):
    v = 2.0 * np.abs(u - 0.5)
    FS = norm.cdf((math.log(S) - mu) / sg)
    rho = np.exp(mu + sg * norm.ppf(np.clip(v * FS, 1e-12, 1 - 1e-12)))
    return np.sign(u - 0.5) * np.minimum(rho / S, 1.0)

def fit_spline(m, interior_u, yfun, ngrid=2001):
    """one offline BVLS: clamped-quartic weights on a family quantile curve, dw>=0, sum dw=2."""
    t = np.r_[[0.0] * 5, interior_u, [1.0] * 5]
    n = m + 4
    u = np.linspace(0, 1, ngrid)
    y = yfun(u)
    B = bspline_cols(t, n, u)
    L = np.tril(np.ones((n, n)))[:, 1:]
    Am = B @ L; b = y - (-1.0) * B.sum(1)
    Aeq = np.full((1, n - 1), 1e3); beq = np.array([2e3])
    res = lsq_linear(np.vstack([Am, Aeq]), np.r_[b, beq], bounds=(0, np.inf), method="bvls")
    w = np.r_[-1.0, -1.0 + np.cumsum(res.x)]
    w = (w - w[::-1]) / 2.0                      # symmetrize (target + layout symmetric; BVLS
    w = w / w[-1]                                # noise ~1e-6) + pin endpoints at exactly +-1:
    return w, t                                  # dw>=0 preserved, wQ ints land clean

def spline_metrics(w, t, binmass, nb=NB_KL, ngrid=4001):
    """fitted-density vs family target (normalized support): KL, max density err, folded mode
    count, center trough. Mode count is family-agnostic: even reflection at 0 + zero sentinels
    at the walls, so a CENTER mode (peaked family) and a wall-edge pile both count."""
    n = len(w)
    u = np.linspace(0, 1, ngrid)
    y = np.clip(bspline_cols(t, n, u) @ w, -1, 1)
    edges = np.linspace(-1, 1, nb + 1)
    Qm = np.maximum(np.diff(np.interp(edges, y, u)), 0)
    Pm = binmass(edges)
    kl = kl_bins(Pm, Qm)
    bw = np.diff(edges)
    fT = Pm / bw / Pm.sum(); fS = Qm / bw / max(Qm.sum(), 1e-12)
    maxerr = float(np.max(np.abs(fS - fT)) / np.max(fT))
    dens = fS[nb // 2:]
    pad = np.r_[0.0, dens[::-1], dens, 0.0]
    pk, _ = find_peaks(pad, prominence=0.03 * dens.max())
    nmod = sum(1 for i in pk if i >= len(dens))
    return kl, maxerr, nmod, float(fS[nb // 2] / fS.max())

def spline_bins(w, t, S, Sd, nb=NB_KL, ngrid=4001):
    n = len(w)
    u = np.linspace(0, 1, ngrid)
    y = np.clip(bspline_cols(t, n, u) @ w, -1, 1) * S
    edges = np.linspace(-Sd, Sd, nb + 1)
    return np.maximum(np.diff(np.interp(edges, y, u, left=0.0, right=1.0)), 0)

# ── gas (measured, evm NUQuarticSetGas.t.sol via proto; see out/lognormal_plateau.json) ───
GAS_WARM = {2: 171_085, 3: 255_531, 4: 340_071, 5: 424_728, 6: 509_529, 10: 848_421, 14: 1_188_432}
def gas_row(m):
    slots = 1 + 2 * m
    compute = GAS_WARM[m] - 100 * slots
    return dict(slots=slots, update=compute + 5000 * slots, firstSet=compute + 22_100 * slots)
GAS = {m: gas_row(m) for m in GAS_WARM}

# ── whitelist: ONE BVLS per (family, sigma-cell, m) at CELL-CENTER sigma (mu=0 wlog:
#    both families' S-normalized quantile curves are sigma-only - scale absorbed by S_dep).
#    24 plateau cells + 16 peaked cells. ─────────────────────────────────────────────────────
WHITELIST = {}
for fam, ms in FAM_M.items():
    for sc in SIGMA_CELLS:
        scf = float(sc)
        yfun, bm = fam_targets(fam, 0.0, scf, math.exp(scf * Z70))
        for m in ms:
            w, t = fit_spline(m, FAM_KNOTS[fam][m], yfun)
            kl, maxerr, nmod, trough = spline_metrics(w, t, bm)
            WHITELIST[(fam, scf, m)] = dict(
                w=w, t=t, klRepCell=round(kl, 5), modesFolded=nmod, troughDepth=round(trough, 4),
                knotsB=[int(round(u * 1e4)) for u in FAM_KNOTS[fam][m]])

# ── components: mirror of make_density_overlay.fit_asset lines 297-351 (fee + LVR kernels,
#    incl fx session basis + pxwin), minus the v4 argmin ──────────────────────────────────
def components(cfg):
    cl = CLASS[cfg["cls"]]
    ts, close, vol, ok, tf, clip = load_tape(cfg["tape"], cfg.get("pxwin"))
    span_d = (ts[ok][-1] - ts[ok][0]) / 86400.0
    rec = opn = sess = None
    if cfg.get("fx"):
        rec, opn, frozen_pct, holes = session_mask(ts, close, ok)
    th = theta_for_rate(ts, close, ok, CAP_RATE_H, cl["hb"], clip, cl["theta"])
    G, pushes, span_h, pexc = push_offsets(ts, close, ok, th, cl["hb"], clip, rec)
    if cfg.get("fx"):
        offo, _, _, _ = push_offsets(ts, close, ok, th, cl["hb"], clip, opn)
        b99_open = float(np.quantile(np.abs(offo), 0.99)) if len(offo) > 200 else 0.0
        sess = dict(frozenPct=round(frozen_pct, 1), holes=holes, b99OpenBp=round(b99_open, 2))
    pushExcQ99 = float(np.quantile(pexc, 0.99)) if len(pexc) else 0.0
    excPrem = float(np.mean(np.maximum(np.abs(G) - th, 0.0)))
    k = max(1, round(360 / tf))
    idx6 = np.flatnonzero(rec) if rec is not None else np.flatnonzero(ok)
    c6 = close[idx6]; t6 = ts[idx6]
    r6 = 1e4 * np.log(c6[k:] / c6[:-k]); dt6 = t6[k:] - t6[:-k]
    r6 = r6[(np.abs(r6) <= clip) & (dt6 <= 2 * 360)]
    b99_6 = float(np.quantile(np.abs(r6), 0.99))
    if sess: b99_6 = max(b99_6, sess["b99OpenBp"])
    idx = np.flatnonzero(ok)
    t = ts[idx]; p = close[idx]; v = vol[idx]
    recm = rec[idx] if rec is not None else np.ones(len(idx), bool)
    r1 = np.concatenate([[0.0], 1e4 * np.diff(np.log(p))])
    r1sq = np.where(np.abs(r1) > clip, 0.0, r1 ** 2)
    dt = np.minimum(np.diff(t, prepend=t[0]), 3 * tf)
    sig2 = ewma_var(r1sq, t, 30 * tf)
    sig2 = np.maximum(sig2, np.quantile(sig2[sig2 > 0], 0.10))
    sub = np.flatnonzero(recm)
    tsub, psub, vsub = t[sub], p[sub], v[sub]
    dtsub = np.minimum(np.diff(tsub, prepend=tsub[0]), 3 * tf)
    tau0 = TAU_INV["fx" if cfg.get("fx") else cfg["cls"]]
    taus = (tau0 / 2, tau0, 2 * tau0)
    burn = t > t[0] + 3 * max(taus)
    d3_s, d3_w = [], []
    for tau in taus:
        d1 = flow_ema_div(tsub, psub, vsub, tf, tau)
        b1 = tsub > tsub[0] + 3 * tau
        h_w = float(wq(np.abs(d1[b1]), dtsub[b1], 0.70))
        d2 = flow_ema_div(tsub, psub, vsub, tf, tau, h_w)
        full = np.full(len(idx), np.nan); full[sub] = d2
        msk = burn & recm & ~np.isnan(full) & (np.abs(full) <= clip)
        d3_s.append(full[msk]); d3_w.append(dt[msk] * sig2[msk] / 3.0)
    d3 = np.concatenate(d3_s); w = np.concatenate(d3_w); w = w / w.sum()
    return dict(th=th, G=G, d3=d3, d3w=w, cad=pushes / span_h, span_d=span_d, bars=int(ok.sum()),
                pushExcQ99=pushExcQ99, excPrem=excPrem, b99_6=b99_6,
                wall_floor=max(pushExcQ99, b99_6), sess=sess)

# ── risk-param leg (unified spec sections 1+3): pure scalar derivation + dispatch ─────────
def ceil_ladder(S_dep):
    for w in W_LADDER:
        if w >= S_dep: return w
    return W_LADDER[-1]

def hill_tail(a_raw, k=HILL_K):
    """Hill tail index on the UNSATURATED composite (physical LVR tail); veto W<=1 if loCI<2."""
    a = np.sort(np.abs(a_raw))
    xk = a[-k - 1]
    if xk <= 0: return dict(alphaHat=None, loCI=None, k=k, veto=False)
    ah = k / float(np.sum(np.log(a[-k:] / xk)))
    lo = ah * (1.0 - 1.96 / math.sqrt(k))
    return dict(alphaHat=round(ah, 2), loCI=round(lo, 2), k=k, veto=bool(lo < 2.0))

def steps25(new, old):
    """updates needed under the +-25% AdminRiskSteward fence (tighten is fence-exempt but
    still counted here as 1; direction reported by the caller)."""
    if old is None or old <= 0 or new <= 0: return None
    return max(1, math.ceil(abs(math.log(new / old)) / math.log(1 + FENCE_REL) - 1e-9))

# ── run ───────────────────────────────────────────────────────────────────────────────────
# v4 as-deployed, FROZEN snapshot: emit_prod_params.py now overwrites out/fit_results.json with
# this script's own output, so reading it back for the `old`/`delta` legs would compare the fit to
# itself. out/fit_results.v4.json is the 2026-07-22 make_density_overlay emit, kept immutable.
_v4_path = HERE / "out" / "fit_results.v4.json"
V4 = json.load(open(_v4_path))["assets"] if _v4_path.exists() else {}
CFG = {c["sym"]: c for c in A}
OUT = {"gen": "lognormal_fit.py (central-normal plateau, m=3, q70 shape / feeQ99 breadth)",
       "spec": dict(qTrunc=Q_TRUNC, tolKlRep=TOL_KL_REP, sigmaCells=[float(x) for x in SIGMA_CELLS],
                    sigmaBand=list(SIGMA_BAND), knotsU=KNOTS_U, knotsUPk=KNOTS_U_PK,
                    familyGate=FAMILY, nuPk=NU_PK, cOfSigma=C_OF_SIGMA,
                    peaked="truncated Student-t(nu=1.5) core, c = cOfSigma*sigma_cell "
                           "(cell 0.40 -> c = 0.22 = v4 lepto sFat/W)",
                    mGate={k: list(v) for k, v in M_GATE.items()},
                    wLadder=list(W_LADDER), dispRef=DISP_REF, minFeeHardPbps=MINFEE_HARD_PBPS,
                    fenceRel=FENCE_REL, deadbands=DEADBANDS, softSat="Y = 2theta*tanh(d/2theta)",
                    minFee="2theta + E[(|G|-theta)+]", nDraws=N_DRAWS, seed=7,
                    breadth="S_dep = max(S_fit=q70(|ell|), 2theta, feeQ99); W = ceil_ladder(max(S_fit, 2theta))",
                    dipNull=dict(n=N_DIP, reps=N_DIP_NULL,
                                 q95=round(float(np.quantile(DIP_NULL, 0.95)), 5))),
       "gas": {str(m): GAS[m] for m in sorted(GAS)},
       "whitelist": {fam: {f"{sc:.2f}": {f"m{m}": dict(
            knotsB=WHITELIST[(fam, float(sc), m)]["knotsB"],
            w=[round(float(x), 4) for x in WHITELIST[(fam, float(sc), m)]["w"]],
            klRepCell=WHITELIST[(fam, float(sc), m)]["klRepCell"],
            modesFolded=WHITELIST[(fam, float(sc), m)]["modesFolded"],
            troughDepth=WHITELIST[(fam, float(sc), m)]["troughDepth"],
            certified=bool(WHITELIST[(fam, float(sc), m)]["klRepCell"] <= TOL_KL_REP
                           and WHITELIST[(fam, float(sc), m)]["modesFolded"] == 1),
            gasUpdate=GAS[m]["update"]) for m in FAM_M[fam]} for sc in SIGMA_CELLS} for fam in FAM_M},
       "assets": {}}

for sym in TARGETS:
    if ONLY and sym not in ONLY: continue
    cfg = CFG[sym]
    c = components(cfg)
    th = c["th"]; R = 2 * th
    rng = np.random.default_rng(7)
    Gd = rng.choice(c["G"], N_DRAWS)
    Ud = rng.uniform(-th, th, N_DRAWS)
    Dd = rng.choice(c["d3"], N_DRAWS, p=c["d3w"])
    ell = Gd + Ud + R * np.tanh(Dd / R)          # LOCKED soft-sat (kills the clip-rail Dirac)
    ell_raw = Gd + Ud + Dd                       # unsaturated: physical tail for the Hill veto
    # ── closed-form fits: LN sigma drives the cell/reporting; CN q70 drives SHAPE scale;
    #    DEPLOYED quiet support tracks fee-kernel density support (feeQ99), not q70.
    #    Soft-sat compresses LVR so q70 collapses majors to ~11 bp while ~99% of fee mass
    #    sits near ~20 bp (matches observed density / ~2w quiet chart range). Narrow hard
    #    floor remains 2θ only — no constant UX widen. ──
    mu, sg, _S_fit_ln = ln_fit(ell)
    sig_g, S_fit = nm_fit(ell)                   # shape scale: empirical q70 (30% cut)
    a = np.abs(ell)
    feeQ50, feeQ70, feeQ90, feeQ99 = (float(x) for x in np.quantile(a, [0.50, 0.70, 0.90, 0.99]))
    S_breadth = feeQ99                           # density support over the tape window
    S_dep = max(S_fit, R, S_breadth)
    cutFit = float(np.mean(a > S_fit)); cutDep = float(np.mean(a > S_dep))
    dip = dip_test(a[a <= S_dep])
    modeBp = 0.0                                 # central-normal: mode AT the mark (no LN offset mode)
    # ── FEE leg: CLASS-GATED family (stable->plateau, volatile->peaked) -> sigma-cell snap ->
    #    minimal-m gate on pre-certified cell weights. Deterministic, never a per-asset argmin. ──
    inFam = SIGMA_BAND[0] <= sg <= SIGMA_BAND[1]
    cell = float(SIGMA_CELLS[int(np.argmin(np.abs(SIGMA_CELLS - sg)))])
    fam = FAMILY[cfg["cls"]]
    edgesD = np.linspace(-S_dep, S_dep, NB_KL + 1)
    Pdata, _ = np.histogram(ell[np.abs(ell) <= S_dep], bins=edgesD)

    def fam_pick(f):
        """m-gate walk on family f's certified cells vs the ASSET-level target (sigma-hat)."""
        _, bmA = fam_targets(f, mu, sg, S_fit)
        mPath, pick = [], None
        for m in [mm for mm in M_GATE[cfg["cls"]] if mm in FAM_M[f]]:
            wl = WHITELIST[(f, cell, m)]
            kl, maxerr, nmod, trough = spline_metrics(wl["w"], wl["t"], bmA)
            mPath.append(dict(m=m, klRep=round(kl, 5), modesFolded=nmod))
            if pick is None and kl <= TOL_KL_REP and nmod == 1:
                pick = (m, kl, maxerr, nmod, trough)
        gateFail = pick is None
        if gateFail:                              # min-klRep fallback, flagged (never ships silently)
            m, kl, maxerr, nmod, trough = min(
                ((p["m"],) + spline_metrics(WHITELIST[(f, cell, p["m"])]["w"],
                                            WHITELIST[(f, cell, p["m"])]["t"], bmA)
                 for p in mPath), key=lambda x: x[1])
        else:
            m, kl, maxerr, nmod, trough = pick
        wl = WHITELIST[(f, cell, m)]
        klData = kl_bins(Pdata.astype(float), spline_bins(wl["w"], wl["t"], S_dep, S_dep))
        return dict(fam=f, m=m, kl=kl, maxerr=maxerr, nmod=nmod, trough=trough,
                    mPath=mPath, gateFail=gateFail, wl=wl, klData=klData)

    pickF = fam_pick(fam)
    alt = fam_pick("plateau") if fam == "peaked" else None      # referee 3-way (v4/plateau/peaked)
    m, kl, maxerr, nmod, trough = pickF["m"], pickF["kl"], pickF["maxerr"], pickF["nmod"], pickF["trough"]
    mPath, gateFail, wl, klData = pickF["mPath"], pickF["gateFail"], pickF["wl"], pickF["klData"]
    # ── RISK leg ──
    # W ladder snaps on shape+2θ (q70 / trigger band), NOT on feeQ99: breadth widens
    # minDisp inside the same σ-rung so stables do not flip W=1→2 from density support alone.
    dref = DISP_REF[cfg["cls"]]
    tail = hill_tail(ell_raw)
    W = ceil_ladder(max(S_fit, R))
    vetoW = tail["veto"] and W <= 1
    if vetoW: W = 2                               # tail-alpha loCI<2: no W<=1 cell
    # kappa>0 class (base USDC never walled). `nowall` opts a listed stable out: the convex coverage
    # wall is erected at $1-peg parity, so a NAV-accruing unit (syrupUSDC ~1.17) must never carry it.
    wallFlag = cfg["cls"] == "stable" and not cfg.get("nowall")
    minDisp = int(round(S_dep * dref / W))
    maxDispB99 = max(int(math.ceil(c["wall_floor"] * dref / W)), minDisp)
    liveMax = cfg["cur"][4] if cfg.get("cur") else 0
    maxDisp = max(maxDispB99, liveMax, cfg.get("mdFloor", 0))   # HOLD ratchet: never slash headroom
    minFeeBp = 2 * th + c["excPrem"]
    minFeePbps = max(int(round(minFeeBp * 100)), MINFEE_HARD_PBPS[cfg["cls"]])
    freeze = not inFam
    # ── OLD v4 vs NEW + bounded-delta dispatch ──
    old = V4.get(sym) or {}
    segs = SEGS.get((old.get("W"), old.get("regime")))
    oldM = (segs if isinstance(segs, int) else len(segs)) if segs is not None else None
    oldGas = GAS.get(oldM, {}).get("update") if oldM else None
    thetaBundle = old and abs(old.get("thetaFinal", th) - th) / th > 0.005   # v4 stores 3dp
    D_scale = abs(math.log(S_dep / old["supportDeployBp"])) if old.get("supportDeployBp") else None
    D_fee = abs(math.log(minFeePbps / (old["minFeeEff"] * 100))) if old.get("minFeeEff") else None
    FAM_TAG = {"cnplateau": "CN", "plateau": "LN", "peaked": "PK"}
    presetId = f"{FAM_TAG[fam]}{cell:.2f}-m{m}" + ("-wall" if wallFlag else "")
    altFit = None
    if alt:
        altFit = dict(presetId=f"LN{cell:.2f}-m{alt['m']}", family="plateau", m=alt["m"],
                      knotsU=KNOTS_U[alt["m"]], knotsB=alt["wl"]["knotsB"],
                      w=[round(float(x), 4) for x in alt["wl"]["w"]],
                      klRepAsset=round(alt["kl"], 5), klDataVsSpline=round(alt["klData"], 4),
                      gateFail=alt["gateFail"], gasUpdate=GAS[alt["m"]]["update"],
                      note="plateau diagnostic on the SAME S_dep/cell (referee 3-way baseline)")
    row = dict(
        cls=cfg["cls"], tape=cfg["tape"], spanD=round(c["span_d"], 1), bars=c["bars"],
        tapeStatus=cfg.get("tapeStatus") or tape_status(c["span_d"], klData, c["sess"], feeQ99),
        sessionGap=c["sess"], theta=round(th, 3), rail=round(R, 3), cadencePerH=round(c["cad"], 1),
        dip=dip, signed=signed_stats(ell), foldModesData=fold_modes(ell),
        ln=dict(mu=round(mu, 4), sigma=round(sg, 4), S_fit=round(S_fit, 3), S_dep=round(S_dep, 3),
                S_breadth=round(S_breadth, 3), breadth="feeQ99",
                feeQ50=round(feeQ50, 3), feeQ70=round(feeQ70, 3),
                feeQ90=round(feeQ90, 3), feeQ99=round(feeQ99, 3),
                floor2Theta=bool(S_dep > S_fit + 1e-12 and abs(S_dep - R) < 1e-9),
                floorBreadth=bool(S_dep > S_fit + 1e-12 and S_dep >= S_breadth - 1e-12),
                cutFitPct=round(100 * cutFit, 1),
                cutDepPct=round(100 * cutDep, 1), modeBp=round(modeBp, 3),
                modeOverS=round(modeBp / max(S_fit, 1e-12), 3),
                klDataVsLN=round(kl_data_vs_ln(ell, mu, sg, S_fit, S_dep), 4)),
        cell=dict(sigmaCell=cell, inFamily=inFam, freeze=freeze, presetId=presetId),
        fit=dict(family=fam, m=m, interiorKnots=m - 1, slots=1 + 2 * m,
                 knotsU=FAM_KNOTS[fam][m], knotsB=wl["knotsB"],
                 cPeak=(round(C_OF_SIGMA * cell, 4) if fam == "peaked" else None),
                 w=[round(float(x), 4) for x in wl["w"]],
                 wQ=[int(round(float(x) * W * 100 * Q)) for x in wl["w"]],
                 dispRef=dref, flags=FLAG_REQUIRES_WALL if wallFlag else 0,
                 klRepAsset=round(kl, 5), klRepCell=wl["klRepCell"], klDataVsSpline=round(klData, 4),
                 maxDensErrPct=round(100 * maxerr, 2), modesFolded=nmod,
                 troughDepth=round(trough, 4), tolMet=bool(kl <= TOL_KL_REP), gateFail=gateFail,
                 mPath=mPath, gasUpdate=GAS[m]["update"], gasFirstSet=GAS[m]["firstSet"]),
        altFit=altFit,
        risk=dict(W=W, dispRef=dref, minDisp=minDisp, maxDispB99=maxDispB99, maxDisp=maxDisp,
                  minFeeBp=round(minFeeBp, 4), minFeePbps=minFeePbps,
                  excPremBp=round(c["excPrem"], 4), wallFloorBp=round(c["wall_floor"], 2),
                  pushExcQ99=round(c["pushExcQ99"], 2), b99_6min=round(c["b99_6"], 2),
                  tailAlpha=tail, vetoW1=vetoW, wallFlag=wallFlag),
        old=(dict(regime=old.get("regime"), W=old.get("W"), dispRef=old.get("dispRef"),
                  minDisp=old.get("minDisp"), maxDisp=old.get("maxDisp"),
                  maxDispB99=old.get("maxDispB99"), S_dep=old.get("supportDeployBp"),
                  thetaFinal=old.get("thetaFinal"), minFeeEffPbps=old.get("minFeeEffPbps"),
                  klDiag=old.get("lossKL"), segs=oldM,
                  interiorKnots=(oldM - 1) if oldM else None,
                  slots=(1 + 2 * oldM) if oldM else None, gasUpdate=oldGas) if old else None),
        delta=dict(shape=f"{old.get('regime')}(9-catalogue) -> {presetId}",
                   knots=f"{(oldM - 1) if oldM else '?'} -> {m - 1}",
                   slots=f"{(1 + 2 * oldM) if oldM else '?'} -> {1 + 2 * m}",
                   gasUpdate=f"{oldGas} -> {GAS[m]['update']}"
                             + (f" ({100 * (GAS[m]['update'] / oldGas - 1):+.0f}%)" if oldGas else ""),
                   W=f"{old.get('W')} -> {W}", minDisp=f"{old.get('minDisp')} -> {minDisp}",
                   maxDisp=f"{old.get('maxDisp')} -> {maxDisp}",
                   minFeePbps=f"{old.get('minFeeEffPbps')} -> {minFeePbps}") if old else None,
        dispatch=dict(
            profile=dict(route="requestUpdateProfile", presetId=presetId, minDisp=minDisp,
                         maxDisp=maxDisp, timelock="LOW (1d; 5m Chapel)",
                         dwell="band >=1h, shape >=24h, <=1 profile/day/asset"),
            fast=dict(route="setAssetParamsBounded", minFeePbps=minFeePbps,
                      steps25=steps25(minFeePbps, old.get("minFeeEffPbps")) if old else 1),
            triggers=dict(D_scale=round(D_scale, 4) if D_scale is not None else None,
                          scaleFired=bool(D_scale is not None and
                                          (D_scale > DEADBANDS["scaleTight"] if S_dep < (old.get("supportDeployBp") or S_dep)
                                           else D_scale > DEADBANDS["scaleLoose"])),
                          D_fee=round(D_fee, 4) if D_fee is not None else None,
                          feeFired=bool(D_fee is not None and
                                        (D_fee > DEADBANDS["feeTight"] if minFeePbps < (old.get("minFeeEffPbps") or minFeePbps)
                                         else D_fee > DEADBANDS["feeLoose"])),
                          wFlip=bool(old and old.get("W") != W),
                          thetaBundle=bool(thetaBundle)),
            blocked=(["FREEZE: sigma out of family [%g,%g] - hold last-good + human alert" %
                      SIGMA_BAND] if freeze else []) + (["GATE-FAIL: klRep > tol at m<=5"] if gateFail else [])))
    OUT["assets"][sym] = row
    print(f"{sym:6} {fam:7} th={th:.3f} sg={sg:.4f} cell={cell:.2f}{'(OUT-FAM)' if freeze else ''} "
          f"m={m}{'(FAIL)' if gateFail else ''} klRep={kl:.3f} klData={klData:.3f} "
          f"dip p={dip['p']} uni={dip['unimodal']} S_fit={S_fit:.3f} feeQ99={feeQ99:.3f} "
          f"S_dep={S_dep:.3f} cut={100 * cutDep:.0f}% "
          f"W={W} minDisp={minDisp} minFee={minFeePbps}pbps "
          f"| old {old.get('regime')}/W{old.get('W')} {(oldM - 1) if oldM else '?'}knots", flush=True)

json.dump(OUT, open(HERE / "out" / "lognormal_fit.json", "w"), indent=1)
print("wrote out/lognormal_fit.json")
