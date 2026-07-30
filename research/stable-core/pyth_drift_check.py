#!/usr/bin/env python3
"""pyth_drift_check.py - independent 200d check on the realized-drift floor.

WHY this and not a tape backfill. `fetch-pyth-history` (nx-rates series-factory)
emits 1-MINUTE candles; the fit basis (`push_offsets`) re-marks at every bar close,
so feeding it 60s bars hides every sub-minute mark update and inflates the offset
law. Measured on a 10s->60s decimation of the SAME 14d window: minDisp +7.6%
(USDT), +8.8% (RLUSD), +14.4% (PAXG), and the sigma cell walks 0.60 -> 0.65
OUT-OF-FAMILY, which trips FREEZE. So 1-min history must not enter the s10 tape.

`b99_6` is the exception: a 6-minute log return off 1-min closes is EXACT (k=6),
not an approximation of a 10s-sampled quantity. So the wall_floor's b99_6 leg is
checkable over 200d of Pyth history at zero bias, which is the whole point -- a
14-60d tape sees 2-8 FX weekend gaps, 200d sees ~28.

Reports q99 of |6-min move| over the moving-regime bars (session mask for fx and
metals, same FROZEN_S basis as the fit) against wallFloorBp from out/fit_results.json.
Read-only: no tape is written, nothing enters the NXR pipeline.

Run: NXR_ORACLE_TOKEN_PYTH=... python3 pyth_drift_check.py [DAYS]
"""
import json, os, time, urllib.parse, urllib.request
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
_src = open(HERE / "make_density_overlay.py").read()
exec(compile(_src[: _src.index("# ── per-asset pipeline ──")], "make_density_overlay.py[defs]", "exec"))
# in scope: session_mask, FROZEN_S

HIST = "https://pyth.dourolabs.app/v1/fixed_rate@200ms/history"
DAYS = int(os.environ.get("DAYS", "200"))
TOKEN = os.environ.get("NXR_ORACLE_TOKEN_PYTH", "")
# NXR feed symbol -> Pyth Lazer symbol. Asset-class prefix is part of the id:
# `fetch_pyth_history.rs` hardcodes `Crypto.`, so it cannot address the FX.* legs
# at all -- another reason the fx set was never backfillable with that tool as-is.
PYTH = {"EURC-USD": "Crypto.EURC/USD", "PAXG-USD": "Crypto.PAXG/USD",
        "USDG-USD": "Crypto.USDG/USD", "USDC-USD": "Crypto.USDC/USD",
        "U-USD": "Crypto.U/USD", "USDF-USD": "Crypto.USDF/USD",
        "USDTB-USD": "Crypto.USDTB/USD", "SYRUPUSDC-USD": "Crypto.SYRUPUSDC/USD",
        "AUSD-USD": "Crypto.AUSD/USD",
        "USD-CAD": "FX.USD/CAD", "AUD-USD": "FX.AUD/USD", "USD-BRL": "FX.USD/BRL",
        "USD-JPY": "FX.USD/JPY", "USD-KRW": "FX.USD/KRW",
        "XAU-USD": "Metal.XAU/USD"}
# pool leg -> (feed symbol, session-gapped). Feed mapping mirrors the keeper
# catalog (gen-sepolia-feeds.py); duplicating it is how a check ends up validating
# the wrong mark, so only the legs this script can actually reach are listed.
LEGS = {"EURC": ("EURC-USD", True), "PAXG": ("PAXG-USD", True), "USDG": ("USDG-USD", False),
        "U": ("U-USD", False), "USDF": ("USDF-USD", False), "USDTB": ("USDTB-USD", False),
        "syrupUSDC": ("SYRUPUSDC-USD", False), "AUSD": ("AUSD-USD", False),
        "QCAD": ("USD-CAD", True), "AUDF": ("AUD-USD", True), "BRLA": ("USD-BRL", True),
        "JPYC": ("USD-JPY", True), "KRW1": ("USD-KRW", True),
        # spot-gold reference: no pool leg, it bounds what PAXG/XAUT drift CAN be. Pyth's own
        # PAXG (token) and XAU (spot) must agree to within the token's basis, and both are the
        # ceiling on any gold number a composite tape produces.
        "XAU(ref)": ("XAU-USD", True)}


def history(sym, days):
    to = int(time.time()); frm = to - days * 86400
    q = urllib.parse.urlencode(dict(symbol=sym, resolution="1", **{"from": frm, "to": to}))
    req = urllib.request.Request(f"{HIST}?{q}", headers={"User-Agent": "curl/8.6.0"}
                                 | ({"Authorization": f"Bearer {TOKEN}"} if TOKEN else {}))
    with urllib.request.urlopen(req, timeout=120) as r:
        d = json.load(r)
    if d.get("s") != "ok":
        raise RuntimeError(f"{sym}: status {d.get('s')}")
    t = np.asarray(d["t"], dtype="int64"); c = np.asarray(d["c"], dtype=float)
    ok = np.isfinite(c) & (c > 0)
    return t[ok].astype(float), c[ok]


def b99_6(ts, close, sess):
    """q99 |6-min log move| in bp over moving-regime bars. k=6 on 1-min closes is
    the fit's `k = round(360/tf)` exactly, not a resampling approximation."""
    ok = np.ones(len(close), bool)
    r1 = 1e4 * np.log(close[1:] / close[:-1])
    clip = max(50.0, 10.0 * float(np.quantile(np.abs(r1), 0.999)))
    if sess:
        rec, opn, frozen_pct, holes = session_mask(ts, close, ok)
        idx = np.flatnonzero(rec)
    else:
        rec = opn = None; frozen_pct = 0.0; holes = 0
        idx = np.flatnonzero(ok)
    c6, t6 = close[idx], ts[idx]
    r6 = 1e4 * np.log(c6[6:] / c6[:-6]); dt6 = t6[6:] - t6[:-6]
    r6 = r6[(np.abs(r6) <= clip) & (dt6 <= 720)]
    return dict(b99=float(np.quantile(np.abs(r6), 0.99)), n6=int(len(r6)),
                frozenPct=round(frozen_pct, 1), holes=holes,
                spanD=round((ts[-1] - ts[0]) / 86400.0, 1))


FITS = json.load(open(HERE / "out" / "fit_results.json"))["assets"]
print(f"{'leg':10} {'feed':14} {'spanD':>6} {'n6':>8} {'frz%':>6} {'b99_6(200d)':>12} "
      f"{'wallFlr(fit)':>13} {'ratio':>7} {'tapeSpanD':>10}")
for leg, (feed, sess) in LEGS.items():
    try:
        ts, c = history(PYTH[feed], DAYS)
        m = b99_6(ts, c, sess)
    except Exception as e:
        print(f"{leg:10} {feed:14} ERR {e}"); continue
    f = FITS.get(leg) or {}
    wf = f.get("wallFloorBp")
    ratio = f"{m['b99'] / wf:.2f}x" if wf else "-"
    print(f"{leg:10} {feed:14} {m['spanD']:>6} {m['n6']:>8} {m['frozenPct']:>6} "
          f"{m['b99']:>12.2f} {str(wf):>13} {ratio:>7} {str(f.get('span_d')):>10}", flush=True)
