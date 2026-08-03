#!/usr/bin/env python3
"""make_density_overlay.py — density basis v4 (two-kernel) + referee-locked params + overlay.

BASIS (v4, TWO-KERNEL; referee-locked, owner 2026-07-22; supersedes the v3
offset-from-mark shape basis):

FEE kernel (spline SHAPE target) = tethered quote-offset law,
    ell = law of G + U + Y     (independent draws, N=400k, seed 7 per asset;
                                == convolution g_theta (*) U(-h,h) (*) pi_clip)
  G ~ push_offsets law (θ_final-cross + heartbeat mark sim on the finest NXR
      tape): reset-bridge tent incl. overshoot, heartbeat, tape quantization.
  U ~ Uniform(-θ_final, θ_final): arb tether, pool mid floats freely inside the
      half-spread of truth (minFee/2 = θ; Pricing.sol:198-200).
  Y ~ clip(d_τ, ±2θ_final) drawn w/ prob ∝ dt·σ² (level-crossing weight on the
      SLOW kernel only): d = 1e4·(ln P − ln C_τ), C = winsorized flow-EMA center
      (2-pass, h_w = q70|d|), equal-weight mixture τ_inv·{1/2,1,2}
      (τ_inv 4h stable / 1h volatile / 2h fx-metal). The 2θ clip is the AIMM
      restoring band (restoring-band invariant): divergence beyond it piles up AT the
      rail, it cannot occupy larger offsets.
θ basis unchanged: θ_final = max(spec θ, θ@100/h cap); FX/metals session-gap
basis unchanged (frozen bars dropped, moving-regime fit).

LVR kernel (tails/wall/floors), exceedance-only, never dwell:
  wall floor = max(push-instant exceedance q99, b99_6min, session-open b99 [fx])
  maxDispB99 = band top containing the wall floor; S_dep = max(S_fit, 2·θ_final)
  minFee = 2·θ_final; minFeeEff = 2·θ_final + E[(|G|−θ)+] (exceedance premium).

PARAMS ARE REFEREE-LOCKED (out/density_basis_v2.json, referee_sim.py damped
consumption replay, 2026-07-22): the deployed (regime, W, S_dep, minDisp,
maxDispB99) per asset are FROZEN referee decisions, not re-fit here. Verdict:
ADOPT v2 refit for USD1+USDE; KEEP v3 shapes for USDT/FDUSD/BTC/ETH/BNB/CAKE;
provisional keep-v3 EURC/XAUT/PAXG (feed QC); class-default fallbacks
U/USDG/USDF/USDTB. Replayed J = (fee−LVR)/TVL is the deploy criterion;
density-match KL is DIAGNOSTIC only (J-rank inverts KL-rank on 6/8: fees are a
crossing measure concentrated near the mark, dwell-matching over-widens).
The optimizer still runs on the ell target and emits its pick + runners as
diagnostics; any preset/θ/cadence change MUST re-run referee_sim.py before
adoption (param-freeze gate).

WHY offset-from-mark (v3) retired as shape target: |G| alone is the Green's
function of θ-killed BM — it measures the PUSH POLICY, not where the quote
offset dwells (65-93% of v3 mass inside 1θ vs 12-25% measured traded-volume
dwell). The tails half of v3 (exceedance wall machinery) was correct and is
KEPT verbatim; only the shape target moved to the two-kernel ell.

Carried v3 rules still in force: S_dep >= 2θ floor (price defense >= fee
defense) · maxDisp HELD at deployed values (σ-dispersion lever inert,
Pricing.sol:105) · ATOMIC θ deploy gate (θ ladder + minFee=2θ + fence resync in
one change) · tape-pending assets emit param-complete FALLBACK rows.

Reproducible: `python3 make_density_overlay.py`
  -> out/fit_results.v4.json (v4 diagnostic snapshot; the DEPLOYED artifact is written
     by emit_prod_params.py, which owns out/fit_results.json)
  -> out/density_overlay.html (per-asset overlay + markers + diagnostics)
Tapes: data/nxr_ohlc/*.json from `TF=10 python3 pull_nxr_ohlc.py`.
Referee decisions: out/density_basis_v2.json (rerun referee_sim.py to refresh).
"""
import json, math, os, time
from pathlib import Path
import numpy as np

ONLY = set(filter(None, os.environ.get("ONLY", "").split(",")))   # e.g. ONLY=USDT,BTC — iterate fast
TAPE_FROM = float(os.environ.get("TAPE_FROM", "0") or 0)          # unix s floor; see load_tape

HERE = Path(__file__).parent
GRID = json.load(open(HERE / "out" / "spline_shared_grid.json"))
V2 = json.load(open(HERE / "out" / "density_basis_v2.json"))["assets"]   # referee-locked decisions
OHLC = HERE / "data" / "nxr_ohlc"
WALLKEY = {0.5: "W0_5", 1: "W1", 2: "W2", 5: "W5"}
REGIMES9 = ["hyper", "flat", "plateau", "meso", "lepto", "platy", "skew_L", "skew_R", "pin_M"]
DISP_REF = {"hyper": 50, "flat": 100, "plateau": 100, "meso": 200, "lepto": 500,
            "platy": 500, "skew_L": 500, "skew_R": 500, "pin_M": 500}   # RISK_PARAMS §1.1
NO_SHIP = {"skew_L", "skew_R", "pin_M"}     # scored, never chosen (mark prices skew; pin needs frozen anchor)
CAP_RATE_H = 100.0                          # push-cadence cap (gas); θ_final = max(spec θ, θ hitting <=100/h)
FROZEN_S = 900                              # fx/metals: unchanged-close run or tape hole >= this = closed session
TAU_INV = {"stable": 4 * 3600, "volatile": 3600, "fx": 2 * 3600}   # slow-kernel class defaults (iteration-0;
                                            # derive TVL*dc_band/flow once pool flow exists)
N_DRAWS = 400_000                           # ell composite draws per asset (seed 7, per-asset rng)
NBINS = (61, 81, 101)                                   # binning sweep for loss robustness
CUT_LO, CUT_HI = 0.25, 0.35                             # tail-cut hard band (target ~0.30)
CLASS = {"stable": dict(theta=0.25, hb=1800), "volatile": dict(theta=5.0, hb=300)}
FALLBACK = {"stable": dict(regime="plateau", W=1, dispRef=100),      # tape-pending class defaults (conservative)
            "volatile": dict(regime="lepto", W=5, dispRef=500)}
TAPE_MAX_AGE_H = float(os.environ.get("TAPE_MAX_AGE_H", 24))        # last bar older than this = PROVISIONAL
TAPE_META = {}                                                      # tape file -> last bar + age, filled by load_tape

# ── theta / heartbeat: the KEEPER config is the single source ─────────────────────────────
# theta is not ours to choose. It is the keeper's push trigger AND its H-2 boot gate
# (minFeePbps >= 2*theta*100, keepers/src/oracle/mod.rs:495, no escape hatch), so a theta
# re-derived here from the tape describes a push process nobody runs. That divergence emitted
# USDF minFeePbps 69 against a keeper theta of 0.365 (floor 73): the value bricks the push
# keeper at startup the day the pool list is populated. CLASS above is the LAST RESORT for
# legs the keeper does not sign, and those legs are marked PROVISIONAL, never fitted as if
# they carried a keeper-enforced trigger.
KEEPER_TOML = Path(os.environ.get("KEEPER_ORACLE_TOML",
                                  HERE.parents[2] / "keepers" / "oracle.sepolia.toml"))
KEEPER_SYM = {"ETH": "WETH-USDC", "BTC": "WBTC-USDC",     # fit symbol -> keeper feed name
              "USDC": "USDC-USD"}                          # base numeraire: its own USD reference


def _keeper_feeds():
    if not KEEPER_TOML.exists():
        raise SystemExit(
            f"keeper oracle config not found: {KEEPER_TOML}\n"
            "theta is keeper-owned; point KEEPER_ORACLE_TOML at it. Refusing to fit on class "
            "defaults: that is how a keeper-bricking minFeePbps gets emitted.")
    import tomllib
    return {f["name"]: f for f in tomllib.loads(KEEPER_TOML.read_text()).get("feeds", [])}


KEEPER_FEEDS = _keeper_feeds()


def keeper_spec(sym):
    """{theta, hb} the keeper actually runs for this leg, or None when it signs no such feed
    (parked/unlisted: no H-2 constraint exists and the row is PROVISIONAL)."""
    f = KEEPER_FEEDS.get(KEEPER_SYM.get(sym, f"{sym}-USDC"))
    return None if f is None else dict(theta=float(f["theta_bps"]), hb=int(f["heartbeat_s"]))


def keeper_gate(legs):
    """The two keeper-side floors, checked per leg against the keeper's OWN theta.
    legs: iterable of (sym, minFeePbps, minDisp, W, dispRef). Returns a list of failure
    strings, empty when every leg clears. Same arithmetic as keepers/src/risk/fences.rs:149
    (H-2 minFee) and :158 (S_dep), which is what refuses the deploy and the keeper boot."""
    out = []
    for sym, min_fee_pbps, min_disp, W, disp_ref in legs:
        ks = keeper_spec(sym)
        if ks is None:
            continue                                       # unsigned leg: no keeper constraint
        need = math.ceil(2 * ks["theta"] * 100)
        if min_fee_pbps < need:
            out.append(f"{sym}: minFeePbps {min_fee_pbps} < 2*theta {need} pbps "
                       f"(keeper theta {ks['theta']}bp): H-2 refuses the push keeper's boot")
        if W and disp_ref:
            support = min_disp / (disp_ref / W)
            if support < 2 * ks["theta"] - 1e-9:
                out.append(f"{sym}: support {support:.3f}bp (minDisp {min_disp} @ dispRef/W "
                           f"{disp_ref / W:g}) < S_dep floor 2*theta {2 * ks['theta']:.3f}bp "
                           f"(keeper theta {ks['theta']}bp)")
    return out


def tape_last_bar(fn):
    """Last real print in a tape + its age, for provenance and the freshness gate."""
    rows = json.load(open(OHLC / fn))
    ts = max((r["ts"] for r in rows if r.get("close", 0) > 0 and r.get("tick_count", 1) > 0),
             default=None)
    if ts is None:
        return dict(lastBar=None, ageH=None)
    return dict(lastBar=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts / 1000.0)),
                ageH=round((time.time() - ts / 1000.0) / 3600.0, 1))

# ── per-asset config: class + tape + current deployed (regime, W, dispRef, minDisp, maxDisp)
#    (RISK_PARAMS §3/§4) for delta display + maxDisp hold. Deployed shape/scale come from the
#    referee lock (out/density_basis_v2.json), never from the in-script fit (diagnostic only). ──
A = [
 dict(sym="USDC",  cls="stable",   tape=None, cur=("plateau", 1, 100, 200, 2000), nowall=True,
      mdFloor=2000, tapeStatus="N/A (identity numeraire)",
      note="Base numeraire: price = 1 by construction, exempt from the pushed mark "
           "(Pricing._readBasePriceOrHalt), kappa FORBIDDEN (AIMM_PROOFS Thm 2, hence nowall). "
           "The signed USDC/USD reference feed (oracle idx 23) is its depeg breaker, and supplies "
           "the keeper theta this row's minFee floor is checked against."),
 dict(sym="USDT",  cls="stable",   tape="USDT-USDC.json",  cur=("hyper", 0.5, 50, 600, 6000)),
 dict(sym="USD1",  cls="stable",   tape="USD1-USDC.json",  cur=("plateau", 1, 100, 500, 5000)),
 dict(sym="USDE",  cls="stable",   tape="USDE-USDC.json",  cur=("plateau", 2, 200, 800, 5000)),
 dict(sym="FDUSD", cls="stable",   tape="FDUSD-USDC.json", cur=("plateau", 1, 100, 1000, 8000)),
 # ── 2026-07-24 NXR landing: the six previously-untapeable stables now ship gapless /USD series.
 #    Fit input = the USDC cross composed locally (compose_usdc_cross.py: X/USDC = X/USD ÷ USDC/USD,
 #    exact 10s ts-join, no fill). Supersedes the bad_feed/no_data defers below. ──
 dict(sym="U",     cls="stable",   tape="U-USDC.json",     cur=None, mdFloor=8000,
      note="Refit 2026-07-24 on the U/USD landing (composed vs USDC/USD). Supersedes the U-USDC "
           "feed collision (19% of prints at ~0.00034 = the other 'U' token) — the /USD series is clean."),
 dict(sym="USDG",  cls="stable",   tape="USDG-USDC.json",  cur=None, mdFloor=8000,
      pxwin=(0.99, 1.01), tapeStatus="PROVISIONAL",
      note="Refit 2026-07-24 on the USDG/USD landing (composed vs USDC/USD). PARTIAL feed fix only: "
           "the 1..1e15 glitch prints PERSIST (18% of live bars out of a +-2x window, max ~1e15). Fit "
           "on the CLEAN SUBSET (px window 0.99-1.01, 82% of live prints; q99 |r1| 2.45bp = peer-normal). "
           "PROVISIONAL: a px-window subset is not a clean feed. DEPLOY RISK: the keeper marks off the "
           "same NXR series, so glitch pushes will be rejected by the 50bp maxDeviation floor and the "
           "feed goes STALE rather than wrong. Fix NXR USDG QC before mainnet."),
 dict(sym="USDF",  cls="stable",   tape="USDF-USDC.json",  cur=None, mdFloor=8000,
      note="Refit 2026-07-24 on the USDF/USD landing (composed vs USDC/USD); trades a persistent "
           "~35bp under peg — a real level, not a glitch."),
 dict(sym="USDTB", cls="stable",   tape="USDTB-USDC.json", cur=None, mdFloor=8000,
      note="Refit 2026-07-24 on the USDTB/USD landing (composed vs USDC/USD)."),
 # ── Sepolia launch roster adds (2026-07-22): 23-asset roster (keepers/oracle.sepolia.toml idx 0-22).
 #    Fresh 14d 10s tapes -> real v4 two-kernel fits, UNREFEREED (provisional until referee_sim run).
 #    mdFloor = stable sibling maxDisp envelope: no in-tape depeg regime on a 14d calm window, same
 #    maxDisp-HELD rationale as rule 2 (never slash stress headroom on a calm fit). ──
 dict(sym="USDS",  cls="stable", tape="USDS-USDC.json",  cur=None, mdFloor=8000,
      note="Sepolia roster add 2026-07-22 (14d NXR tape)"),
 dict(sym="DAI",   cls="stable", tape="DAI-USDC.json",   cur=None, mdFloor=8000,
      note="Sepolia roster add 2026-07-22 (14d NXR tape)"),
 dict(sym="PYUSD", cls="stable", tape="PYUSD-USDC.json", cur=None, mdFloor=8000,
      note="Sepolia roster add 2026-07-22 (14d NXR tape)"),
 dict(sym="RLUSD", cls="stable", tape="RLUSD-USDC.json", cur=None, mdFloor=8000,
      note="Sepolia roster add 2026-07-22 (14d NXR tape)"),
 dict(sym="GHO",   cls="stable", tape="GHO-USDC.json",   cur=None, mdFloor=8000,
      note="Sepolia roster add 2026-07-22 (14d NXR tape)"),
 dict(sym="TUSD",  cls="stable", tape="TUSD-USDC.json",  cur=None, mdFloor=8000,
      note="Sepolia roster add 2026-07-22 (14d NXR tape; peg drifting soft, 0.996-0.999 in-window)"),
 dict(sym="AUSD",  cls="stable", tape="AUSD-USDC.json",  cur=None, mdFloor=8000, tapeStatus="PROVISIONAL",
      note="Sepolia roster add 2026-07-22 (14d NXR tape, SPARSE: ~1/3 of hourly bars populated; "
           "refit on a dense tape before referee)"),
 dict(sym="syrupUSDC", cls="stable", tape="syrupUSDC-USDC.json", cur=None, mdFloor=8000, nowall=True,
      note="NON-PEG: Maple syrupUSDC is NAV-accruing (~1.17 and drifting up), NOT a $1 peg. Refit "
           "2026-07-24 on the SYRUPUSDC/USD landing (composed vs USDC/USD): the fit is on log-offsets "
           "from the pushed mark, so the NAV level is immaterial and the shape is honest. NAV-aware "
           "deploy config UNCHANGED: kappa=0 + haircutSuppressor=0 (the coverage wall assumes $1-peg "
           "parity; a NAV asset must not be walled at 1.0) + oracle seed ORACLE_SEED_syrupUSDC_1E18 "
           "from live NAV, refBand vs the NAV mark not USDC=1."),
 dict(sym="EURC",  cls="volatile", tape="EURC-USDC.json", cur=None, fx=True, mdFloor=500_000,
      note="POOL RE-CLASS (owner 2026-07-21): stable -> VOLATILE (θ spec 5bp). Session-gap-aware FX basis: "
           "frozen/weekend bars dropped (moving-regime fit), wall tier floored by session-open vol. Prior BLOCK "
           "(4.4d tape, KL 1.18 frozen-quote atom) addressed by the moving-regime basis; PROVISIONAL until a "
           ">=10d tape spanning FX sessions lands."),
 # ── FX core (Sepolia fx pool 0x18c7376A…B229, added 2026-07-29). Mock ERC20s of fiat-backed
 #    tokens; the mark is the Pyth USD NATIVE the oracle keeper actually pushes (feed idx 25-29,
 #    keepers/scripts/gen-sepolia-feeds.py), inverted where the native is USD-quoted. The fit input
 #    is that same series — NOT a USDC compose, which would describe a mark no keeper ever pushes.
 #    Tapes: `FX=QCAD-USDC,… python3 compose_usdc_cross.py`. cls=volatile carries the spec θ=5bp /
 #    300s heartbeat of oracle.sepolia.toml; fx=True selects the session-gap basis (frozen bars
 #    dropped, wall tier floored by session-open vol) and TAU_INV["fx"]. mdFloor = the DEPLOYED
 #    maxDispersion (hold ratchet: a calm-window fit never slashes stress headroom).
 dict(sym="QCAD", cls="volatile", tape="QCAD-USDC.json", fx=True, mdFloor=100_000,
      note="fx-core leg; mark = USD-CAD inverted (feed idx 25)."),
 dict(sym="AUDF", cls="volatile", tape="AUDF-USDC.json", fx=True, mdFloor=100_000,
      note="fx-core leg; mark = AUD-USD (feed idx 26)."),
 dict(sym="BRLA", cls="volatile", tape="BRLA-USDC.json", fx=True, mdFloor=100_000,
      note="fx-core leg; mark = USD-BRL inverted (feed idx 27). BRL prints only in Brazilian hours; "
           "the source is provably dead outside them, so the session mask carries this fit."),
 dict(sym="JPYC", cls="volatile", tape="JPYC-USDC.json", fx=True, mdFloor=100_000,
      note="fx-core leg; mark = USD-JPY inverted (feed idx 28)."),
 dict(sym="KRW1", cls="volatile", tape="KRW1-USDC.json", fx=True, mdFloor=100_000,
      note="fx-core leg; mark = USD-KRW inverted (feed idx 29)."),
 dict(sym="BTC",   cls="volatile", tape="BTC-USDC.json",   cur=("lepto", 5, 500, 50000, 500000)),
 dict(sym="ETH",   cls="volatile", tape="ETH-USDC.json",   cur=("lepto", 5, 500, 50000, 500000)),
 # Sepolia wrapper legs: explicit rows per addAsset target; mark ROUTES to the fitted feed (NXR owns
 # the symbol mapping, keepers/oracle.sepolia.toml). Params inherit the source referee-locked row.
 dict(sym="WETH",  cls="volatile", tape=None, cur=None, route="ETH",
      note="Sepolia launch: WETH mark = ETH-USDC feed (idx 17)."),
 dict(sym="WBTC",  cls="volatile", tape=None, cur=None, route="BTC",
      note="Sepolia launch: WBTC mark = BTC-USDC feed (idx 18)."),
 dict(sym="cbBTC", cls="volatile", tape=None, cur=None, route="BTC",
      note="Sepolia launch: cbBTC mark = BTC-USDC feed (idx 19)."),
 dict(sym="BNB",   cls="volatile", tape="BNB-USDC.json",   cur=("lepto", 5, 500, 50000, 500000)),
 dict(sym="CAKE",  cls="volatile", tape="CAKE-USDC.json",  cur=("platy", 5, 500, 50000, 500000)),
 dict(sym="XAUT",  cls="volatile", tape="XAUT-USDC.json",  cur=("meso", 2, 200, 50000, 500000), fx=True,
      pxwin=(3500, 4400), tapeStatus="PROVISIONAL",
      note="POOL RE-CLASS (owner 2026-07-21): session-gap-aware metals basis. Fit on the CLEAN SUBSET only "
           "(px window 3500-4400 drops the ~2300 mirror cluster; tick_count>0 drops synth fills; frozen/weekend "
           "bars dropped). PROVISIONAL: §4 feed-QC caveat stands until the NXR mirror-cluster fix is confirmed; "
           "px-window subset != clean feed. Deployed meso W2 held as cur for delta display."),
 dict(sym="PAXG",  cls="volatile", tape="PAXG-USD.json", cur=None, fx=True, mdFloor=500_000,
      note="POOL RE-CLASS (owner 2026-07-21): VOLATILE (gold, session-gap-aware basis). PAXG/USD from NXR; "
           "if the tape is absent (backfill not yet on prod) a lepto-W5 class-default fallback row ships "
           "(TAPE_PENDING)."),
]

# ── tape load + cleaning (auto px window + auto glitch clip; no manual per-asset knobs) ──
def load_tape(fn, pxwin=None):
    rows = json.load(open(OHLC / fn))
    ts = np.array([r["ts"] for r in rows], dtype="int64") / 1000.0          # s
    close = np.array([r["close"] for r in rows])
    vol = np.array([r.get("vbid", 0) + r.get("vask", 0) for r in rows], dtype=float)
    tick = np.array([r.get("tick_count", 1) for r in rows])
    if vol.max() <= 0: vol = tick.astype(float)   # FDUSD tape ships no vbid/vask; tick-count activity proxy
    ok = (close > 0) & (tick > 0)                                            # real prints only
    # NXR changed s10 sampling density on 2026-07-09: every tape carries 1-3 ticks/bar before
    # it and 8-29 after (USDT 93% unchanged-close and 2.5k distinct prices/week in June vs 0.1%
    # and 52k in late July). A window straddling it fits a two-microstructure mixture, which is
    # what drove klData 1.0-1.85 on the 60d stables. TAPE_FROM pins the homogeneous regime.
    if TAPE_FROM: ok &= ts >= TAPE_FROM
    lo, hi = pxwin if pxwin else (np.median(close[ok]) * 0.5, np.median(close[ok]) * 2.0)
    ok &= (close > lo) & (close < hi)                                        # glitch px window
    tf = float(np.median(np.diff(ts)))
    # FRESHNESS: span is derived from the file's own contents, so a dead feed still shows a
    # healthy span and the fit silently describes the last good window. EURC was 98h stale and
    # passed the >=10d span test with a 56.6h blackout inside it. Age is measured against the
    # wall clock, and a stale tape downgrades the row to PROVISIONAL (tape_status).
    age_h = (time.time() - ts[ok][-1]) / 3600.0
    TAPE_META[fn] = dict(lastBar=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts[ok][-1])),
                         ageH=round(age_h, 1), stale=bool(age_h > TAPE_MAX_AGE_H))
    if age_h > TAPE_MAX_AGE_H:
        print(f"  STALE TAPE {fn}: last bar {age_h:.0f}h old (> {TAPE_MAX_AGE_H:g}h): PROVISIONAL")
    c = close[ok]
    r1 = 1e4 * np.log(c[1:] / c[:-1])
    clip = max(50.0, 10.0 * float(np.quantile(np.abs(r1), 0.999)))           # anti-wick, auto
    return ts, close, vol, ok, tf, clip

def push_offsets(ts, close, ok, theta, hb_s, clip, rec=None):
    """mark = last θ-crossing close (+heartbeat); per-bar-close log-offset from mark (bp)
    + push-instant |offset| at θ-crossings (LVR-kernel exceedances).
    rec = optional full-length record mask (fx: moving-regime bars only); the push
    process always runs on the full tape (mark path + cadence stay realistic)."""
    idx = np.flatnonzero(ok)
    if len(idx) < 100: return np.empty(0), 0, 0.0, np.empty(0)
    mark = close[idx[0]]; last_ts = ts[idx[0]]
    off = np.empty(len(idx) - 1); n = 0; pushes = 0; exc = []
    lg = np.log(close[idx[1:]]); t = ts[idx[1:]]
    rm = rec[idx[1:]] if rec is not None else None
    lm = math.log(mark)
    for i in range(len(lg)):
        o = 1e4 * (lg[i] - lm)
        if o > clip or o < -clip: continue                                   # glitch wick: skip, no re-mark
        if rm is None or rm[i]: off[n] = o; n += 1
        if o >= theta or -o >= theta or (t[i] - last_ts) >= hb_s:
            if o >= theta or -o >= theta: exc.append(abs(o))                 # θ-crossing push instant
            lm = lg[i]; pushes += 1; last_ts = t[i]
    span_h = (ts[idx[-1]] - ts[idx[0]]) / 3600.0
    return off[:n], pushes, span_h, np.array(exc)

def theta_for_rate(ts, close, ok, target_h, hb_s, clip, theta_floor):
    """θ_final = max(spec θ, θ hitting <=target_h): returns the spec floor when its
    cadence is already under target, else log-bisects θ MINIMALLY UP to the cap
    (returns the >=-side bracket so realized cadence stays <= target). Targets below
    the heartbeat cadence floor (3600/hb) are unreachable: clamp just above it."""
    target_h = max(target_h, 1.1 * 3600.0 / hb_s)
    def rate(th):
        _, p, sh, _ = push_offsets(ts, close, ok, th, hb_s, clip)
        return p / sh if sh else 0.0
    lo, hi = theta_floor, 2000.0
    if rate(lo) <= target_h: return lo                                       # spec θ already ≤ cap
    for _ in range(18):
        mid = math.sqrt(lo * hi)
        if rate(mid) > target_h: lo = mid
        else: hi = mid
    return hi                                                                # cadence(hi) <= cap side

def session_mask(ts, close, ok):
    """FX/metals session-gap basis: frozen = run of unchanged closes lasting >=
    FROZEN_S (weekend/closed hours) or a tape hole >= FROZEN_S. Returns full-length
    bool masks (rec = moving-regime bars, opn = first hour after each reopen,
    both ⊆ ok) + frozen-time % + hole count."""
    idx = np.flatnonzero(ok); c = close[idx]; t = ts[idx]; n = len(idx)
    frozen = np.zeros(n, bool)
    i = 0
    while i < n:
        j = i
        while j + 1 < n and c[j + 1] == c[i]: j += 1
        if t[j] - t[i] >= FROZEN_S: frozen[i:j + 1] = True
        i = j + 1
    hole = np.concatenate([[False], np.diff(t) >= FROZEN_S])
    reopen = (~frozen) & (np.concatenate([[False], frozen[:-1]]) | hole)
    opn = np.zeros(n, bool)
    for k in np.flatnonzero(reopen):
        opn |= (~frozen) & (t >= t[k]) & (t < t[k] + 3600)
    rec_f = np.zeros(len(ts), bool); rec_f[idx[~frozen]] = True
    opn_f = np.zeros(len(ts), bool); opn_f[idx[opn]] = True
    return rec_f, opn_f, 100.0 * frozen.mean(), int(hole.sum())

def wq(x, w, q):
    """weighted quantile(s)."""
    i = np.argsort(x); cw = np.cumsum(w[i]); cw /= cw[-1]
    return np.interp(q, cw, x[i])

def flow_ema_div(t, p, v, tf, tau, h_bp=None):
    """winsorized flow-EMA channel divergence (bp), full-length on the given grid.
    h_bp = None -> pass 1 (raw center, used only to set h_w = q70|d|); else pass 2
    winsorizes the center INPUT at ±h_bp so one-sided excursions cannot drag it."""
    vpos = v[v > 0]
    vfloor = 0.1 * (float(np.median(vpos)) if len(vpos) else 1.0)
    w = np.maximum(v, vfloor)
    dt = np.minimum(np.diff(t, prepend=t[0]), 3 * tf)
    N = w[0] * p[0]; D = w[0]; C = p[0]
    d = np.empty(len(t)); hl = math.log(1 + (h_bp or 0) / 1e4)
    for i in range(len(t)):
        pi = p[i]
        if h_bp is not None:
            lo, hi = C * math.exp(-hl), C * math.exp(hl)
            pi = lo if pi < lo else (hi if pi > hi else pi)
        a = math.exp(-dt[i] / tau)
        N = a * N + w[i] * pi; D = a * D + w[i]; C = N / D
        d[i] = 1e4 * (math.log(p[i]) - math.log(C))
    return d

def ewma_var(r1sq, t, hl_s):
    """EWMA of glitch-clipped squared bp-returns (σ² level-crossing weight)."""
    out = np.empty(len(r1sq)); prev = float(np.mean(r1sq[:60])) if len(r1sq) > 60 else r1sq[0]
    tp = t[0]
    for i in range(len(r1sq)):
        a = math.exp(-math.log(2) * min(t[i] - tp, 3600.0) / hl_s)
        prev = a * prev + (1 - a) * r1sq[i]; out[i] = prev; tp = t[i]
    return out

# ── preset pdfs (native x ∈ [-W, W]) ──
def preset_pdf(regime, W):
    d = np.array(GRID["walls"][WALLKEY[W]]["presets"][regime]["series"]["density"], dtype=float)
    xs, ys = d[:, 0], np.maximum(d[:, 1], 0.0)
    f = ys / np.trapezoid(ys, xs)
    cdf = np.concatenate([[0], np.cumsum(0.5 * (f[1:] + f[:-1]) * np.diff(xs))])
    cdf /= cdf[-1]
    return xs, f, cdf

PRESETS = {}
for _wn, _wk in WALLKEY.items():
    for _r in GRID["portableMatrix"][_wk]:
        if _r in REGIMES9: PRESETS[(_wn, _r)] = preset_pdf(_r, _wn)
SEGS = {(w, r): GRID["walls"][WALLKEY[w]]["presets"][r]["segments"] for (w, r) in PRESETS}

def trunc_kl_js(samples, weights, xs, cdf, W, S, nb):
    """truncated-support KL/JS: obs|[-S,S] renormalized vs preset (mass 1 on support)."""
    edges = np.linspace(-S, S, nb + 1)
    P, _ = np.histogram(samples, bins=edges, weights=weights)
    if P.sum() <= 0: return 9e9, 9e9
    P = P / P.sum()
    Q = np.diff(np.interp(edges * (W / S), xs, cdf)); Q = np.maximum(Q, 1e-12); Q /= Q.sum()
    m = P > 0
    kl = float(np.sum(P[m] * np.log(P[m] / Q[m])))
    M = 0.5 * (P + Q)
    js = 0.5 * float(np.sum(P[m] * np.log(P[m] / M[m]))) + 0.5 * float(np.sum(Q * np.log(Q / M)))
    return kl, js

# ── per-asset pipeline ──
def fit_asset(cfg):
    cl = CLASS[cfg["cls"]]
    ks = keeper_spec(cfg["sym"]) or cl              # spec theta is the KEEPER's, per leg
    ts, close, vol, ok, tf, clip = load_tape(cfg["tape"], cfg.get("pxwin"))
    span_d = (ts[ok][-1] - ts[ok][0]) / 86400.0
    rec = opn = sess = None
    if cfg.get("fx"):
        rec, opn, frozen_pct, holes = session_mask(ts, close, ok)
    # θ_final = max(spec θ, θ_100perH): spec basis, minimally raised to hit the <=100/h cadence cap
    th_fin = theta_for_rate(ts, close, ok, CAP_RATE_H, ks["hb"], clip, ks["theta"])
    G, pushes, span_h, pexc = push_offsets(ts, close, ok, th_fin, ks["hb"], clip, rec)
    rate_h = pushes / span_h
    gw = np.full(len(G), 1.0 / len(G))
    if cfg.get("fx"):
        offo, _, _, _ = push_offsets(ts, close, ok, th_fin, ks["hb"], clip, opn)
        b99_open = float(np.quantile(np.abs(offo), 0.99)) if len(offo) > 200 else 0.0
        sess = dict(frozenPct=round(frozen_pct, 1), holes=holes, b99OpenBp=round(b99_open, 2))
    q50g, q70g, q99g = map(float, wq(np.abs(G), gw, [0.5, 0.70, 0.99]))
    pushExcQ99 = float(np.quantile(pexc, 0.99)) if len(pexc) else 0.0
    excPrem = float(np.mean(np.maximum(np.abs(G) - th_fin, 0.0)))   # E[(|G|-θ)+] exceedance fee premium
    # 6-min-horizon b99 (band-top containment; fx: moving bars only, no cross-gap spans)
    k = max(1, round(360 / tf))
    idx6 = np.flatnonzero(rec) if rec is not None else np.flatnonzero(ok)
    c = close[idx6]; t6 = ts[idx6]
    r6 = 1e4 * np.log(c[k:] / c[:-k]); dt6 = t6[k:] - t6[:-k]
    r6 = r6[(np.abs(r6) <= clip) & (dt6 <= 2 * 360)]
    b99_6 = float(np.quantile(np.abs(r6), 0.99))
    if sess: b99_6 = max(b99_6, sess["b99OpenBp"])        # wall tier floored by session-open vol
    wall_floor = max(pushExcQ99, b99_6)                    # LVR kernel: exceedance-only wall floor
    # ── FEE kernel: ell = G + U + Y (two-kernel composite; per-asset rng, seed 7) ──
    idx = np.flatnonzero(ok)
    t = ts[idx]; p = close[idx]; v = vol[idx]; lg = np.log(p)
    recm = rec[idx] if rec is not None else np.ones(len(idx), bool)
    r1 = np.concatenate([[0.0], 1e4 * np.diff(lg)])
    r1sq = np.where(np.abs(r1) > clip, 0.0, r1 ** 2)
    dt = np.minimum(np.diff(t, prepend=t[0]), 3 * tf)
    sig2 = ewma_var(r1sq, t, 30 * tf)                      # hl 30*tf (~300s), << tau_inv
    sig2 = np.maximum(sig2, np.quantile(sig2[sig2 > 0], 0.10))
    sub = np.flatnonzero(recm)
    tsub, psub, vsub = t[sub], p[sub], v[sub]
    dtsub = np.minimum(np.diff(tsub, prepend=tsub[0]), 3 * tf)
    tau0 = TAU_INV["fx" if cfg.get("fx") else cfg["cls"]]
    taus = (tau0 / 2, tau0, 2 * tau0)
    burn = t > t[0] + 3 * max(taus)
    d3_s, d3_w, winsors = [], [], []
    for tau in taus:
        d1 = flow_ema_div(tsub, psub, vsub, tf, tau)
        b1 = tsub > tsub[0] + 3 * tau
        h_w = float(wq(np.abs(d1[b1]), dtsub[b1], 0.70))
        d2 = flow_ema_div(tsub, psub, vsub, tf, tau, h_w)
        full = np.full(len(idx), np.nan); full[sub] = d2
        m = burn & recm & ~np.isnan(full) & (np.abs(full) <= clip)
        d3_s.append(full[m]); d3_w.append(dt[m] * sig2[m] / 3.0); winsors.append(round(h_w, 3))
    d3 = np.concatenate(d3_s); d3w = np.concatenate(d3_w); d3w = d3w / d3w.sum()
    railPct = round(100 * float(np.sum(d3w[np.abs(d3) > 2 * th_fin])), 1)
    rng = np.random.default_rng(7)
    ell = (rng.choice(G, N_DRAWS) + rng.uniform(-th_fin, th_fin, N_DRAWS)
           + rng.choice(np.clip(d3, -2 * th_fin, 2 * th_fin), N_DRAWS, p=d3w))
    samples = ell                                          # overlay obs = fee-kernel law
    weights = np.full(N_DRAWS, 1.0 / N_DRAWS)
    fq = wq(np.abs(ell), weights, [0.5, 0.70, 0.90, 0.99])
    feeQ50, feeQ70, feeQ90, feeQ99 = (round(float(x), 3) for x in fq)
    # ── DIAGNOSTIC optimizer on the ell target (v3 machinery; NOT the deploy pick) ──
    aq = wq(np.abs(ell), weights, [1 - CUT_HI, 1 - CUT_LO])
    S_grid = np.linspace(float(aq[0]), float(aq[1]), 15)
    wsum = weights.sum()
    cuts = np.array([float(np.sum(weights[np.abs(ell) > S]) / wsum) for S in S_grid])
    pen = 0.01 * ((cuts - 0.30) / 0.05) ** 2          # ≈ KL-scale at band edges, 0 at target
    cands = []
    for (W_, reg_), (xs, f, cdf) in PRESETS.items():
        if reg_ == "hyper" and not (cfg["cls"] == "stable" and cfg["sym"] != "USDC"): continue  # κ-wall gate
        best = None
        for j, S in enumerate(S_grid):
            kls = [trunc_kl_js(ell, weights, xs, cdf, W_, S, nb) for nb in NBINS]
            score = float(np.mean([k_ for k_, _ in kls])) + pen[j]
            if best is None or score < best[0]:
                best = (score, float(S), kls[1], cuts[j])  # kls[1] = nb=81 headline
        cands.append(dict(regime=reg_, W=W_, loss=best[0], S=best[1], kl=best[2][0], js=best[2][1],
                          cut=float(best[3])))
    cands.sort(key=lambda c_: c_["loss"])
    # ── REFEREE LOCK: deployed params frozen by the consumption-replay verdict ──
    v2row = V2.get(cfg["sym"]) or {}
    refr = v2row.get("referee") or {}
    if "regime" in refr:                                   # refereed winner (KEEP v3 or ADOPT v2)
        lock, decision, prov = refr, refr["decision"], False
    elif v2row:                                            # provisional keep-v3 (feed QC pending)
        lock, decision, prov = v2row["v3"], "keep-v3", True
    else:                                                  # no referee row: diagnostic pick, flagged
        # hyper additionally excluded unrefereed: the needle needs a referee run + clean depeg
        # history (USD1 precedent, RISK_PARAMS section 3), never a first-fit pick.
        ship = [c_ for c_ in cands if c_["regime"] not in NO_SHIP and c_["regime"] != "hyper"]
        top = ship[0]
        Sd = max(top["S"], 2.0 * th_fin)
        lock = dict(regime=top["regime"], W=top["W"], S_dep=Sd, S_fit=top["S"],
                    minDisp=int(round(Sd * DISP_REF[top["regime"]] / top["W"])), maxDispB99=0)
        decision, prov = "UNREFEREED", True
    reg, W = lock["regime"], lock["W"]
    dref = DISP_REF[reg]
    S_dep = float(lock["S_dep"])
    S = float((v2row["v2"] if decision == "v2pick" else v2row["v3"])["S_fit"]) if v2row \
        else float(lock.get("S_fit", S_dep))
    minDisp = int(lock["minDisp"])
    maxDispB99 = int(lock["maxDispB99"]) if lock.get("maxDispB99") else \
        max(int(math.ceil(wall_floor * dref / W)), minDisp)
    maxDisp = max(cfg["cur"][4], maxDispB99) if cfg["cur"] else \
        max(maxDispB99, cfg.get("mdFloor", 0))             # HOLD: σ-lever inert (Pricing.sol:105)
    xs, f, cdf = PRESETS[(W, reg)]                         # locked-shape diagnostics at deployed scale
    kl81 = trunc_kl_js(ell, weights, xs, cdf, W, S_dep, NBINS[1])
    cut_lo = float(np.sum(weights[ell < -S]) / wsum)
    cut_hi = float(np.sum(weights[ell > S]) / wsum)
    cutd = float(np.sum(weights[np.abs(ell) > S_dep]) / wsum)
    minFeeEff = float(refr.get("minFee_eff") or (2 * th_fin + excPrem))
    Jval, Jd = refr.get("J"), refr.get("J_vs_v3")
    note = cfg.get("note")
    rnote = (f"referee-locked {decision}"
             + (f" (J {Jval} APR%, vs v3 {Jd:+})" if Jval is not None else "")
             + (f" PROVISIONAL: {refr.get('reason')}" if prov and refr.get("reason") else ""))
    note = (note + " · " if note else "") + rnote
    res = dict(
        status="fit", cls=cfg["cls"], tape=cfg["tape"], tf_s=round(tf), span_d=round(span_d, 1),
        bars=int(ok.sum()), clip_bp=round(clip, 1), theta_spec_bp=cl["theta"], hb_s=cl["hb"],
        thetaFinal=round(th_fin, 3), cadencePerH=round(rate_h, 1), horizon_s=round(3600 / rate_h),
        fallback=False,
        tapeStatus=cfg.get("tapeStatus") or ("ok" if span_d >= 10 else "PROVISIONAL"),
        sessionGap=sess,
        regime=reg, W=W, dispRef=dref,
        minDisp=minDisp,
        minDispFit=int(round(S * dref / W)),
        maxDisp=maxDisp, maxDispB99=maxDispB99,
        supportBp=round(S, 3), supportDeployBp=round(S_dep, 3), floor2Theta=bool(S_dep > S),
        cutPct=round(100 * (cut_lo + cut_hi), 1),
        cutLoPct=round(100 * cut_lo, 1), cutHiPct=round(100 * cut_hi, 1),
        cutDeployPct=round(100 * cutd, 1),
        lossKL=round(kl81[0], 4), lossJS=round(kl81[1], 4),
        offQ50=round(q50g, 3), offQ70=round(q70g, 3), offQ99=round(q99g, 3), b99_6min=round(b99_6, 2),
        feeQ50=feeQ50, feeQ70=feeQ70, feeQ90=feeQ90, feeQ99=feeQ99,
        pushExcQ99=round(pushExcQ99, 2), wallFloorBp=round(wall_floor, 2),
        railPctSig2=railPct, tetherBp=round(th_fin, 3), railClipBp=round(2 * th_fin, 3),
        tauInvH=round(tau0 / 3600, 1), winsorH=winsors,
        minFee2Theta=int(round(2 * th_fin * 100)),
        minFeeEff=round(minFeeEff, 4), minFeeEffPbps=int(round(minFeeEff * 100)),
        referee=dict(decision=decision, provisional=prov, J=Jval, J_vs_v3=Jd,
                     gates=refr.get("gates"), reason=refr.get("reason")),
        cur=(dict(regime=cfg["cur"][0], W=cfg["cur"][1], dispRef=cfg["cur"][2], minDisp=cfg["cur"][3],
                  maxDisp=cfg["cur"][4]) if cfg["cur"] else None),
        runners=[dict(regime=c_["regime"], W=c_["W"], kl=round(c_["kl"], 4), S=round(c_["S"], 3),
                      cut=round(100 * c_["cut"], 1)) for c_ in cands[:4]],
        note=note)
    return res, samples, weights

def fallback_row(cfg, fitted):
    """param-complete class-default row for tape-pending assets. Referee freeze
    (2026-07-22): class default = plateau W1 at the 2θ envelope of fitted class
    siblings (max θ_final); adopted-v2 widened supports are NOT inherited (the
    widening was asset-specific depeg-tail evidence, absent here). Refit + referee
    when the tape lands."""
    fb = FALLBACK[cfg["cls"]]; cl = CLASS[cfg["cls"]]
    sib = [r for r in fitted.values() if r.get("status") == "fit" and r["cls"] == cfg["cls"]
           and r["referee"]["decision"] != "UNREFEREED"]   # envelope = referee-frozen fits only:
    th = max([r["thetaFinal"] for r in sib], default=cl["theta"])   # unrefereed Sepolia adds must not
                                                                    # silently widen frozen fallback rows
    S_dep = 2.0 * th * cfg.get("widen", 1)      # widen>1: NAV/non-peg provisional (syrupUSDC)
    minDisp = int(round(S_dep * fb["dispRef"] / fb["W"]))
    maxDisp = max([r["maxDisp"] for r in sib] + ([cfg["cur"][4]] if cfg.get("cur") else [10 * minDisp]))
    return dict(
        status=cfg.get("defer", "no_data"), cls=cfg["cls"], fallback=True, tapeStatus="TAPE_PENDING",
        theta_spec_bp=cl["theta"], hb_s=cl["hb"], thetaFinal=round(th, 3), cadencePerH=None,
        regime=fb["regime"], W=fb["W"], dispRef=fb["dispRef"],
        minDisp=minDisp, maxDisp=maxDisp, supportDeployBp=round(S_dep, 3),
        minFee2Theta=int(round(2 * th * 100)),
        referee=dict(decision="class-default", provisional=True, J=None, J_vs_v3=None,
                     gates=None, reason="no referee tape"),
        cur=(dict(regime=cfg["cur"][0], W=cfg["cur"][1], dispRef=cfg["cur"][2], minDisp=cfg["cur"][3],
                  maxDisp=cfg["cur"][4]) if cfg.get("cur") else None),
        note=((cfg.get("note") or "") + " · FALLBACK (referee-frozen class default): plateau W1 at the "
              + ("2θ sibling envelope WIDENED %gx (non-peg NAV drift)" % cfg["widen"] if cfg.get("widen")
                 else "2θ sibling envelope")
              + "; param-complete for deploy, refit + referee when tape lands."))

def routed_row(cfg, fitted):
    """explicit param row for a wrapper leg whose mark ROUTES to a fitted feed (Sepolia:
    WETH -> ETH, WBTC/cbBTC -> BTC; NXR owns the symbol mapping). The deploy needs a row
    per addAsset target; params inherit the source referee-locked row, never refit here.
    Wrapper basis risk (wrapper vs underlying depeg) is NOT modeled."""
    src = fitted[cfg["route"]]
    r = {k: src[k] for k in ("cls", "theta_spec_bp", "hb_s", "thetaFinal", "cadencePerH",
                             "regime", "W", "dispRef", "minDisp", "maxDisp", "maxDispB99",
                             "supportDeployBp", "minFee2Theta", "minFeeEff", "minFeeEffPbps")
         if k in src}
    r.update(status="routed", fallback=False, tapeStatus="ROUTED:" + cfg["route"],
             routeFeed=cfg["route"], cur=None,
             referee=dict(decision="routed:" + cfg["route"], provisional=True,
                          J=src["referee"].get("J"), J_vs_v3=None, gates=None,
                          reason="params inherited from the routed feed row; not separately refereed"),
             note=((cfg.get("note") or "") + f" · ROUTED (mark = {cfg['route']} feed): params inherit "
                   f"the {cfg['route']} referee-locked row ({src['regime']} W{src['W']}, minDisp "
                   f"{src['minDisp']}); wrapper-vs-underlying basis risk not modeled."))
    return r

# ── run all assets (pass 1 = fits; pass 2 = identity + param-complete fallbacks needing the fitted envelope) ──
results, panels = {}, []
for cfg in A:
    if ONLY and cfg["sym"] not in ONLY: continue
    if cfg["tape"] is None or not (OHLC / (cfg["tape"] or "")).exists():
        continue
    r, samples, weights = fit_asset(cfg)
    results[cfg["sym"]] = r
    # panel series: obs two-kernel fee density ell (unit mass) + locked preset density at DEPLOYED scale.
    # x-axis is SYMLOG (0-centered, linear within ±lt): the sub-bp core and the hundreds-of-bp deployed skirt
    # (maxDisp) are 100-600x apart, so linear-x collapses every asset to an identical spike at 0. Bins are
    # uniform IN SYMLOG SPACE (heights stay per-linear-bp densities) so the core keeps resolution.
    mdBp = r["maxDisp"] * r["W"] / r["dispRef"]                # deployed stress skirt, bp
    b99Bp = r["maxDispB99"] * r["W"] / r["dispRef"]            # wall-floor band top, bp
    lt = max(0.05, round(r["feeQ50"], 3))                      # linthresh ≈ per-asset fee-kernel q50
    xr = float(max(1.15 * r["supportDeployBp"], np.max(np.abs(samples)), mdBp))
    slog = lambda x: np.sign(x) * np.log1p(np.abs(x) / lt)
    sexp = lambda u: np.sign(u) * lt * np.expm1(np.abs(u))
    nb = 121; edges = sexp(np.linspace(-float(slog(xr)), float(slog(xr)), nb + 1))
    H, _ = np.histogram(samples, bins=edges, weights=weights)
    bwv = np.diff(edges)
    obs = [[round(float(0.5 * (edges[i] + edges[i + 1])), 4), round(float(H[i] / (weights.sum() * bwv[i])), 5)]
           for i in range(nb)]
    gran = r["offQ50"] < 0.02                                  # near 10s-tape price quantization
    xs, f, _ = PRESETS[(r["W"], r["regime"])]
    sc = r["supportDeployBp"] / r["W"]
    fit = [[round(float(x * sc), 4), round(float(y / sc), 5)] for x, y in zip(xs, f)]
    fit = fit[::max(1, len(fit) // 160)]
    rf = r["referee"]
    st = dict(regime=f"{r['regime']} W{r['W']}", decision=rf["decision"],
              thetaFinal=f"{r['thetaFinal']}bp", cadence=f"{r['cadencePerH']}/h",
              horizon=f"{r['horizon_s']}s", KLdiag=r["lossKL"],
              cutDep=f"{r['cutDeployPct']}% @±{r['supportDeployBp']}bp",
              minDisp=r["minDisp"], maxDisp=r["maxDisp"],
              feeQ50=r["feeQ50"], feeQ99=r["feeQ99"], markQ50=r["offQ50"],
              rail=f"{r['railPctSig2']}% @±{r['railClipBp']}bp",
              wall=f"{r['wallFloorBp']}bp", minFee=f"{r['minFee2Theta']}/{r['minFeeEffPbps']} pbps")
    if rf.get("J") is not None:
        st["J"] = f"{rf['J']} APR% ({rf['J_vs_v3']:+} vs v3)"
    if gran:
        st["granularity"] = f"FLOOR (mark q50 {r['offQ50']}bp < 0.02bp)"
    if r.get("sessionGap"):
        st["frozen"] = f"{r['sessionGap']['frozenPct']}%"; st["b99open"] = r["sessionGap"]["b99OpenBp"]
    delta = (f"{r['cur']['regime']} W{r['cur']['W']} minDisp {r['cur']['minDisp']} → " if r["cur"] else "unlisted → ") \
        + f"{r['regime']} W{r['W']} minDisp {r['minDisp']}"
    cap = (f"{delta}. Two-kernel basis: fee core ell = G (push-offset, θ_final {r['thetaFinal']}bp = "
           f"max(spec {r['theta_spec_bp']}bp, θ@100/h cap), realized {r['cadencePerH']}/h, hb {r['hb_s']}s) "
           f"CONV U(±θ tether) CONV clip(channel, ±2θ rail; {r['railPctSig2']}% σ²-mass at the rail, "
           f"τ_inv {r['tauInvH']}h). LVR tails exceedance-only: wall floor {r['wallFloorBp']}bp = "
           f"max(push-exc q99 {r['pushExcQ99']}, 6-min b99 {r['b99_6min']}) -> band top {r['maxDispB99']}; "
           f"maxDisp HELD at {r['maxDisp']} (σ-dispersion lever inert, Pricing.sol:105). Deployed support "
           f"±{r['supportDeployBp']}bp cuts {r['cutDeployPct']}% of fee mass; truncated-KL of the locked shape "
           f"{r['lossKL']} (DIAGNOSTIC; deploy criterion = referee J)."
           + (f" Session-gap basis: {r['sessionGap']['frozenPct']}% frozen bars dropped, "
              f"session-open b99 {r['sessionGap']['b99OpenBp']}bp." if r.get("sessionGap") else "")
           + (" GRANULARITY FLOOR: mark-offset q50 below the 10s-tape price quantum (~0.02bp); the G-kernel "
              "core width is a LOWER BOUND, the true between-push density may be narrower." if gran else "")
           + (f" {r['note']}" if r.get("note") else ""))
    panels.append(dict(sym=cfg["sym"], status="fit", obs=obs, fit=fit, xr=round(xr, 3), lt=lt,
                       S=r["supportDeployBp"], Sfit=r["supportBp"],
                       md=round(mdBp, 2), b99=round(b99Bp, 2), gran=gran, cap=cap, stats=st,
                       regime=r["regime"], W=r["W"], KL=r["lossKL"], dec=rf["decision"]))
    print(f"{cfg['sym']:6} {r['regime']:8} W{r['W']:<3} [{rf['decision']}] Sfit=±{r['supportBp']:.3g}bp "
          f"Sdep=±{r['supportDeployBp']:.3g}bp cutDep={r['cutDeployPct']}% KLdiag={r['lossKL']} "
          f"minDisp={r['minDisp']} maxDispB99={r['maxDispB99']} maxDisp={r['maxDisp']} θfin={r['thetaFinal']}bp "
          f"cad={r['cadencePerH']}/h J={rf.get('J')} [{r['tapeStatus']}]", flush=True)

# pass 2: identity + fallback rows (need the fitted class envelope from pass 1)
for cfg in A:
    if ONLY and cfg["sym"] not in ONLY: continue
    if cfg["sym"] in results: continue
    if cfg["sym"] == "USDC":
        results["USDC"] = dict(status="identity", cls="stable", fallback=False, tapeStatus="identity",
                               note=cfg.get("note"),
                               cur=dict(regime=cfg["cur"][0], W=cfg["cur"][1], dispRef=cfg["cur"][2],
                                        minDisp=cfg["cur"][3], maxDisp=cfg["cur"][4]))
        panels.insert(0, dict(sym="USDC", status="identity", obs=[[-0.02, 0], [0, 60], [0.02, 0]], fit=[],
                              xr=2.0, S=0, cap=cfg.get("note", ""), stats={}))
    elif cfg.get("route"):
        results[cfg["sym"]] = routed_row(cfg, results)
    else:
        results[cfg["sym"]] = fallback_row(cfg, results)
results = {cfg["sym"]: results[cfg["sym"]] for cfg in A if cfg["sym"] in results}   # restore roster order

out_json = dict(gen="make_density_overlay.py v4 (two-kernel fee/LVR basis, referee-locked params, "
                    "owner 2026-07-22)",
                generated=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                basis=dict(theta="spec theta per class, raised minimally to the cadence cap: theta_final = "
                                 "max(spec, theta_100perH)",
                           cap_rate_h=CAP_RATE_H, frozen_s=FROZEN_S, cut_band=[CUT_LO, CUT_HI], theta_spec=CLASS,
                           fee_kernel="ell = law of G + U(-theta,theta) + clip(d_3tau, +-2theta): G = push-offset "
                                      "law (theta_final-cross + heartbeat mark sim); U = arb tether (minFee/2); "
                                      "Y drawn w/ prob ~ dt*sigma2 (EWMA hl 30*tf), winsorized flow-EMA center "
                                      "(2-pass, h_w = q70|d|), tau_inv {4h stable, 1h volatile, 2h fx-metal} "
                                      "x {1/2,1,2}; N=400k draws, seed 7 per asset",
                           lvr_kernel="exceedance-only, never dwell: wall floor = max(push-instant exc q99, "
                                      "b99_6min, session-open b99); maxDispB99 = band top >= wall floor; "
                                      "S_dep = max(S_fit, 2*theta_final); minFee = 2*theta_final; minFeeEff = "
                                      "2*theta_final + E[(|G|-theta)+]",
                           loss="truncated-support KL of the LOCKED shape on the ell target at S_dep, bins 81 "
                                "(DIAGNOSTIC only; deploy criterion = referee J)"),
                referee=dict(
                    source="out/density_basis_v2.json (referee_sim.py damped consumption replay, 2026-07-22)",
                    J="(fee - LVR)/TVL annualized %, mean over latency {1,3,6} bars x turnover {0.25,1,4} at the "
                      "minFee floor (dynamic vol fees not modeled)",
                    verdict="ADOPT v2 refit USD1+USDE; KEEP v3 USDT/FDUSD/BTC/ETH/BNB/CAKE; provisional keep-v3 "
                            "EURC/XAUT/PAXG (feed QC); class-default fallbacks U/USDG/USDF/USDTB/syrupUSDC; "
                            "Sepolia adds USDS/DAI/PYUSD/RLUSD/GHO/TUSD/AUSD fitted UNREFEREED; "
                            "WETH/WBTC/cbBTC routed to ETH/BTC feed rows",
                    freeze="params are FROZEN referee decisions; any preset/theta/cadence change re-runs "
                           "referee_sim.py before adoption. Density-match KL demoted to diagnostic (J-rank "
                           "inverts KL-rank on 6/8: fees are a crossing measure concentrated near the mark)",
                    damping=0.4, fp_rounds=4),
                reconcile=dict(
                    date="2026-07-22",
                    rules=["TWO-KERNEL basis owner 2026-07-22: fee core = g_theta CONV pi_inv (tethered "
                           "quote-offset law) replaces offset-from-mark as SHAPE target; LVR tails stay "
                           "exceedance-only (v3 machinery kept verbatim)",
                           "HIGH-CADENCE owner decision 2026-07-21: spec-theta basis capped at 100/h",
                           "deployed support S_dep = max(S_fit, 2*theta_final)",
                           "maxDisp HELD at deployed values (sigma-dispersion gain inert, Pricing.sol:105)",
                           "ATOMIC deploy gate: theta -> theta_final ladder + minFee = 2*theta_final + fence resync "
                           "in one change",
                           "POOL RE-CLASS owner 2026-07-21: EURC, XAUT, PAXG -> VOLATILE class, session-gap-aware "
                           "FX/metals basis (frozen bars dropped, wall tier floored by session-open vol)",
                           "tape-pending assets emit param-complete FALLBACK rows (fallback=true, "
                           "tapeStatus=TAPE_PENDING): U, USDG, USDF, USDTB, syrupUSDC",
                           "SEPOLIA ROSTER completion 2026-07-22: 23-asset launch roster "
                           "(keepers/oracle.sepolia.toml idx 0-22) param-complete. v4 two-kernel fits "
                           "(UNREFEREED, provisional, hyper excluded unrefereed) for "
                           "USDS/DAI/PYUSD/RLUSD/GHO/TUSD/AUSD on fresh 14d 10s tapes; NAV-aware 2x-widened "
                           "fallback syrupUSDC (non-peg ~1.17: base kappa=0 + haircutSuppressor=0, NAV oracle "
                           "seed); routed rows WETH (ETH feed) + WBTC/cbBTC (BTC feed). All pending tape "
                           "maturity + adaptive-keeper refit + referee_sim before any freeze"]),
                assets=results)
# v4 diagnostic snapshot, NOT the emitted artifact: out/fit_results.json is written by
# emit_prod_params.py alone. Two writers of one file is how it came to disagree with the deploy
# JSON while both carried the same `generated` stamp. lognormal_fit.py reads this as `old`.
(HERE / "out" / "fit_results.v4.json").write_text(json.dumps(out_json, indent=1))
print("wrote out/fit_results.v4.json")

# ── overlay HTML (palette/skeleton carried from v1 / spline_template.html) ──
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

def tag_of(kl): return "good" if kl <= 0.05 else ("loose" if kl <= 0.15 else "mismatch")
def tag_dec(rf):
    if rf.get("provisional"): return "na"
    return "good" if (rf.get("J") or 0) > 0 else "loose"

sum_rows = ""
for sym, r in results.items():
    if r["status"] != "fit":
        if r.get("fallback") or r.get("routeFeed"):
            tag = "ROUTED:" + r["routeFeed"] if r.get("routeFeed") else "FALLBACK"
            sum_rows += (f"<tr><td>{sym}</td><td>{r['cls']}</td><td>{r['status']}</td>"
                         f"<td>{r['regime']} W{r['W']}/{r['minDisp']} ({tag})</td><td>-</td>"
                         f"<td>±{r['supportDeployBp']}</td><td>-</td><td>-</td><td>-</td><td>-</td>"
                         f"<td>{r['thetaFinal']}</td><td>-</td>"
                         f"<td>{r['maxDisp']}</td><td><span class='pill na'>{r['tapeStatus']}</span></td></tr>")
        else:
            sum_rows += (f"<tr><td>{sym}</td><td>{r['cls']}</td><td colspan='11'>{r['status']}"
                         f"{' · ' + (r.get('note') or '') if r.get('note') else ''}</td>"
                         f"<td><span class='pill na'>n/a</span></td></tr>")
        continue
    cur = r["cur"]
    old = f"{cur['regime']} W{cur['W']}/{cur['minDisp']}" if cur else "unlisted"
    rf = r["referee"]
    t = tag_dec(rf)
    Jtxt = "-" if rf.get("J") is None else f"{rf['J']:+}"
    sum_rows += (f"<tr><td>{sym}</td><td>{r['cls']}</td><td>{old}</td>"
                 f"<td>{r['regime']} W{r['W']}/{r['minDisp']}</td><td>{rf['decision']}</td>"
                 f"<td>±{r['supportDeployBp']}</td>"
                 f"<td>{r['cutDeployPct']}%</td><td>{Jtxt}</td><td>{r['lossKL']}</td><td>{r['thetaFinal']}</td>"
                 f"<td>{r['cadencePerH']}</td><td>{r['maxDispB99']}</td>"
                 f"<td>{r['maxDisp']}</td><td><span class='pill {t}'>{rf['decision']}"
                 f"{'' if r['tapeStatus'] == 'ok' else ' · ' + r['tapeStatus']}</span></td></tr>")

DATA = {"panels": panels}
HTML = f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>BTR AIMM — Two-kernel fee density vs locked preset (basis v4, referee-locked)</title>
<style>{CSS}</style></head><body>
<div class="wrap">
 <header>
  <div class="eyebrow">BTR AIMM · density basis v4 · two-kernel fee/LVR · referee-locked</div>
  <h1>Two-kernel fee density vs deployed bonding-curve density</h1>
  <p class="lede">Per asset: the <b>observed</b> fee-kernel density ell = G ⊛ U ⊛ Y (push-offset bridge G at
  θ_final = max(spec θ, θ@100/h cap), arb tether U(±θ), rail-clipped channel divergence Y at ±2θ weighted by
  dt·σ²; owner 2026-07-22) overlaid on the <b>deployed</b> preset density at its locked scale
  (support = W·minDisp/dispRef). Deployed (regime, W, S_dep, minDisp, maxDispB99) are <b>REFEREE-LOCKED</b>
  (damped consumption replay, J = (fee−LVR)/TVL over a latency×turnover sweep): ADOPT v2 refit for USD1+USDE,
  KEEP v3 shapes for USDT/FDUSD/BTC/ETH/BNB/CAKE, provisional keep-v3 EURC/XAUT/PAXG (feed QC). The KL shown is
  the truncated-support KL of the LOCKED shape on the ell target: a <b>diagnostic</b>, not the deploy criterion
  (J-rank inverts KL-rank on 6/8 assets; fees are a crossing measure concentrated near the mark, so
  dwell-matching over-widens). LVR tails stay exceedance-only: wall floor = max(push-instant exceedance q99,
  6-min b99, session-open b99); S_dep ≥ 2θ; maxDisp HELD (σ-dispersion lever inert). FX/metals fit on the
  moving regime only (frozen/weekend bars dropped).</p>
  <div class="legend-top">
   <span><span class="sw" style="border-color:var(--obs)"></span>observed fee-kernel density ell (two-kernel composite)</span>
   <span><span class="sw" style="border-color:var(--fit)"></span>deployed preset density (referee-locked scale)</span>
   <span><span class="sw" style="border-color:var(--wall)"></span>deployed support ±S_dep (solid-dash) · shape-fit ±S_fit (fine-dash)</span>
   <span><span class="sw" style="border-color:var(--loose)"></span>6-min b99 band top ±b99</span>
   <span><span class="sw" style="border-color:var(--fit);opacity:.55"></span>deployed stress skirt edge ±maxDisp (dotted + shaded band)</span>
  </div>
  <p class="lede">x-axis is <b>symlog</b> (0-centered, linear within a per-asset ±linthresh ≈ fee-kernel q50,
  log beyond): the bp-scale fee core and the hundreds-of-bp deployed skirt differ by 100-600x, so a linear axis
  collapses every asset into an identical spike at 0. The symlog view keeps both the core shape and the stress
  headroom legible. Where the G-kernel (mark-offset) q50 sits below the 10s-tape price quantum (~0.02bp) the
  panel carries a GRANULARITY FLOOR flag: the G core width is a lower bound.</p>
 </header>

 <div class="grid2" id="panels"></div>

 <section class="card">
  <div class="notes"><b>Referee-locked summary (basis v4).</b> <span class="mono">locked</span> = deployed
  (regime, W, minDisp) frozen by the consumption-replay referee; <span class="mono">S dep</span> = deployed
  support = W·minDisp/dispRef (≥ 2·θ_final); <span class="mono">cut dep</span> = fee-kernel mass beyond it;
  <span class="mono">J</span> = replayed (fee−LVR)/TVL APR% at the minFee floor (deploy criterion);
  <span class="mono">KL</span> = truncated-KL of the locked shape on the ell target (diagnostic only);
  <span class="mono">θ fin</span> = max(spec θ, θ@100/h cap); <span class="mono">cad</span> = realized pushes/h;
  <span class="mono">wall b99</span> = maxDispB99 band top (exceedance wall floor);
  <span class="mono">maxDisp</span> = HELD deployed value (σ-lever inert). Pill: green = J&gt;0, amber = refereed
  at the structural minFee-floor deficit (fee/cadence lever, not shape), grey = provisional/fallback. All fitted
  rows gate on the ATOMIC θ_final + minFee=2θ_final + fence resync deploy; any param change re-runs
  referee_sim.py first.</div>
  <table class="sum"><thead><tr><th>asset</th><th>class</th><th>current</th><th>locked</th><th>decision</th>
  <th>S dep bp</th><th>cut dep</th><th>J APR%</th><th>KL diag</th><th>θ fin bp</th><th>cad /h</th><th>wall b99</th><th>maxDisp</th><th>verdict</th></tr></thead><tbody>{sum_rows}</tbody></table>
 </section>
 <div class="foot">generated by make_density_overlay.py v4 · basis: two-kernel fee/LVR (ell = g_θ ⊛ π_inv fee core + exceedance tails) on NXR /v1/ohlc 10s tapes · params referee-locked: out/density_basis_v2.json · presets: out/spline_shared_grid.json · emitted: out/fit_results.v4.json</div>
</div>
<script>
const DATA={json.dumps(DATA)};
const css=k=>getComputedStyle(document.documentElement).getPropertyValue(k).trim();
function draw(cv,p){{
 const dpr=Math.max(1,window.devicePixelRatio||1),W=cv.clientWidth,H=cv.clientHeight;
 cv.width=W*dpr;cv.height=H*dpr;const g=cv.getContext('2d');g.setTransform(dpr,0,0,dpr,0,0);g.clearRect(0,0,W,H);
 const mL=8,mR=8,mT=10,mB=22,pw=W-mL-mR,ph=H-mT-mB,xr=p.xr;
 let ymax=0;for(const a of[p.obs,p.fit])for(const d of a)if(d[1]>ymax)ymax=d[1];ymax*=1.12||1;
 // symlog x: 0-centered, linear within ±lt, log beyond — sub-bp core AND hundreds-of-bp skirt in one view
 const lt=p.lt||0.05,T=x=>Math.sign(x)*Math.log1p(Math.abs(x)/lt),tx=T(xr);
 const X=x=>mL+(T(x)+tx)/(2*tx)*pw, Y=y=>mT+ph-(y/ymax)*ph;
 // deployed stress skirt band ±S..±maxDisp (fit-colored) under the cut shading
 if(p.md>p.S&&p.S>0){{g.globalAlpha=.05;g.fillStyle=css('--fit');
  g.fillRect(X(-Math.min(p.md,xr)),mT,X(-p.S)-X(-Math.min(p.md,xr)),ph);
  g.fillRect(X(p.S),mT,X(Math.min(p.md,xr))-X(p.S),ph);g.globalAlpha=1;}}
 // shaded cut region beyond ±S
 if(p.S>0&&p.S<xr){{g.globalAlpha=.06;g.fillStyle=css('--wall');
  g.fillRect(mL,mT,X(-p.S)-mL,ph);g.fillRect(X(p.S),mT,mL+pw-X(p.S),ph);g.globalAlpha=1;}}
 g.strokeStyle=css('--hair');g.lineWidth=1;
 g.beginPath();g.moveTo(X(0),mT);g.lineTo(X(0),mT+ph);g.stroke();
 // decade ticks (symlog): 0 plus ±10^d outside the linear zone
 const ticks=[0];for(let d=-2;;d++){{const v=Math.pow(10,d);if(v>xr)break;if(v>=lt*1.4)ticks.push(v,-v);}}
 g.fillStyle=css('--mut');g.font='10px ui-monospace,monospace';g.textAlign='center';
 for(const t of ticks){{const a=Math.abs(t);
  g.fillText((t>0?'+':'')+(a>=1||a===0?t.toFixed(0):String(t)),X(t),H-7);
  if(t!==0){{g.strokeStyle=css('--hair');g.beginPath();g.moveTo(X(t),mT+ph-4);g.lineTo(X(t),mT+ph);g.stroke();}}}}
 g.textAlign='right';g.fillText('offset bp · symlog, linear ±'+lt,W-mR-2,mT+10);g.textAlign='left';
 // deployed-support markers at ±S (solid-dash) + shape-fit markers at ±Sfit (fine-dash)
 if(p.S>0)for(const s of[-1,1]){{const wx=s*p.S;if(Math.abs(wx)<=xr){{g.strokeStyle=css('--wall');g.setLineDash([4,3]);
  g.beginPath();g.moveTo(X(wx),mT);g.lineTo(X(wx),mT+ph);g.stroke();g.setLineDash([]);}}}}
 if(p.Sfit>0&&p.Sfit<p.S)for(const s of[-1,1]){{const wx=s*p.Sfit;if(Math.abs(wx)<=xr){{
  g.strokeStyle=css('--wall');g.globalAlpha=.45;g.setLineDash([1,3]);
  g.beginPath();g.moveTo(X(wx),mT);g.lineTo(X(wx),mT+ph);g.stroke();g.setLineDash([]);g.globalAlpha=1;}}}}
 // 6-min-b99 band top (±b99, loose-amber) + deployed maxDisp skirt edge (±md, fit-amber)
 if(p.b99>0)for(const s of[-1,1]){{const wx=s*p.b99;if(Math.abs(wx)<=xr){{
  g.strokeStyle=css('--loose');g.globalAlpha=.8;g.setLineDash([6,4]);
  g.beginPath();g.moveTo(X(wx),mT);g.lineTo(X(wx),mT+ph);g.stroke();g.setLineDash([]);g.globalAlpha=1;}}}}
 if(p.md>0)for(const s of[-1,1]){{const wx=s*p.md;if(Math.abs(wx)<=xr){{
  g.strokeStyle=css('--fit');g.globalAlpha=.55;g.setLineDash([2,5]);
  g.beginPath();g.moveTo(X(wx),mT);g.lineTo(X(wx),mT+ph);g.stroke();g.setLineDash([]);g.globalAlpha=1;}}}}
 // guide labels (right side only, stacked to avoid overlap)
 g.font='9px ui-monospace,monospace';g.textAlign='left';
 const lab=[];if(p.S>0)lab.push(['S_dep',p.S,'--wall']);
 if(p.b99>0&&p.b99<=xr)lab.push(['b99_6m',p.b99,'--loose']);
 if(p.md>0&&p.md<=xr)lab.push(['maxDisp',p.md,'--fit']);
 lab.forEach((L,i)=>{{g.fillStyle=css(L[2]);g.fillText(L[0],Math.min(X(L[1])+3,W-mR-46),mT+20+i*11);}});
 g.fillStyle=css('--mut');g.font='10px ui-monospace,monospace';
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
 const dtag=p.dec==='keep-v3'?'na':(p.dec?'good':'na');
 const badge=p.status==='fit'?`<span class="badge ${{dtag}}">${{p.dec}} · KL ${{p.KL}}</span>`:`<span class="badge na">${{p.status}}</span>`;
 const st=p.stats||{{}};
 const rows=Object.entries(st).map(([k,v])=>`<div><span class="k">${{k}}</span><span class="v">${{v}}</span></div>`).join('');
 c.innerHTML=`<div class="ch-head"><h2>${{p.sym}}<span class="reg">${{p.status==='fit'?p.regime+' · W'+p.W:''}}</span></h2>${{badge}}</div>
  <div class="canvas-box"><canvas></canvas></div>
  <div class="stats">${{rows}}</div>
  <div class="cap">${{p.cap||''}}</div>`;
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
HTML = HTML.replace("—", "-")          # no em-dash in emitted HTML (voice rule)
out.write_text(HTML)
print(f"wrote {out}  ({len(HTML)} bytes)")
