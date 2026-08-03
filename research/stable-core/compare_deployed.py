#!/usr/bin/env python3
"""compare_deployed.py - diff two risk-param ARTIFACTS, and check both against the keeper floors.

NOT a deployment check. It reads JSON files, never the chain, so an artifact that agrees with
itself can still disagree with what the pool actually holds: that divergence (file minDisp 1472
vs chain 400 on the fx legs) is exactly what it cannot see. To use it as one, pass a snapshot of
the CHAIN state as <before> and read the keeper-floor section, which applies the same arithmetic
the keeper runs at boot (make_density_overlay.keeper_gate, keepers/src/risk/fences.rs:149/158)
to BOTH files.

The `delta` block inside lognormal_fit.json only covers assets carrying a hardcoded `cur` tuple
in the roster (10 of 29), so diff artifact-against-artifact instead: that covers every leg the
pools hold, including the wrapper legs (WETH/WBTC/cbBTC, which route another asset's fit and
never appear in TARGETS) and the fx pool.

Per-leg fit context (span, theta, wall_floor) is joined from fit_results.json on the ROUTED
source symbol, so a wrapper reports the span of the tape that actually backs it.

  python3 compare_deployed.py <before.json> [after.json]
    after defaults to ../../evm/deployments/sepolia-risk-params.json (the fresh emit)
Both files share one schema, so <before> is a pre-emit snapshot or a chain snapshot.
"""
import json, sys
from pathlib import Path

HERE = Path(__file__).parent
DEPLOY = HERE.parent.parent / "evm/deployments/sepolia-risk-params.json"
if len(sys.argv) < 2:
    raise SystemExit(__doc__)
before_p = Path(sys.argv[1])
after_p = Path(sys.argv[2]) if len(sys.argv) > 2 else DEPLOY

COLS = ("presetIds", "minDisp", "maxDisp", "minFeePbps", "tapeStatus", "cls")


def rows(p):
    d = json.loads(Path(p).read_text())
    return d, {s: {k: d[k][i] for k in COLS if k in d} for i, s in enumerate(d["symbols"])}


DB, OLD = rows(before_p)
DA, NEW = rows(after_p)
FITS = json.load(open(HERE / "out" / "fit_results.json"))["assets"]
ROUTE = {"WETH": "ETH", "WBTC": "BTC", "cbBTC": "BTC"}


def d(a, b):
    if a is None or b is None:
        return str(a if b is None else b)
    return f"{a}->{b}" + (f" ({b / a:.2f}x)" if a else "")


print(f"before: {before_p.name}  {DB.get('generated')}")
print(f"after : {after_p.name}  {DA.get('generated')}\n")
print(f"{'sym':10}{'cls':9}{'spanD':>7}{'tape':>13}{'theta':>7}{'wallFlr':>9}{'W':>3}"
      f"{'minDisp':>22}{'maxDisp':>20}{'minFee':>16}  fit(minDisp/minFee)")
stale = []
for sym in DA["symbols"]:
    n = NEW.get(sym, {})
    o = OLD.get(sym, {})
    f = FITS.get(ROUTE.get(sym, sym)) or FITS.get(sym) or {}
    # A leg whose emitted minDisp differs from its own fit was NOT written by this emit: it
    # survived via the "preserve extra deploy legs" fallback, which copies a stale row forward
    # every wave. Show the fit so the gap is visible, not silent.
    fd, ff = f.get("minDisp"), f.get("minFeeEffPbps")
    mark = ""
    if fd is not None and n.get("minDisp") is not None and fd != n["minDisp"]:
        mark = f"  <-- NOT EMITTED: fit={fd}/{ff}"
        stale.append(sym)
    print(f"{sym:10}{str(n.get('cls'))[:8]:9}{str(f.get('span_d') or '-'):>7}"
          f"{str(n.get('tapeStatus'))[:12]:>13}{str(f.get('thetaFinal') or '-'):>7}"
          f"{str(f.get('wallFloorBp') or '-'):>9}{str(f.get('W') or '-'):>3}"
          f"{d(o.get('minDisp'), n.get('minDisp')):>22}"
          f"{d(o.get('maxDisp'), n.get('maxDisp')):>20}"
          f"{d(o.get('minFeePbps'), n.get('minFeePbps')):>16}{mark}")
if stale:
    print(f"\n{len(stale)} leg(s) carry a fit the emitter never wrote: {stale}")
gone = [s for s in OLD if s not in NEW]
add = [s for s in NEW if s not in OLD]
if gone or add:
    print(f"\nleg set changed: removed={gone} added={add}")

# ── keeper floors, both files ────────────────────────────────────────────────────────────
# The only check here that is about the chain rather than about the diff: feed it a chain
# snapshot as <before> and it reports the legs the keeper would refuse to boot on.
_ov = open(HERE / "make_density_overlay.py").read()
_ns = {"__name__": "overlay_defs", "__file__": str(HERE / "make_density_overlay.py")}
exec(compile(_ov[: _ov.index("# \u2500\u2500 tape load + cleaning")], "overlay[roster]", "exec"), _ns)


def _legs(d):
    byid = {p["id"]: p for p in d.get("presets", [])}
    return [(s, d["minFeePbps"][i], d["minDisp"][i],
             byid.get(d["presetIds"][i], {}).get("W"),
             byid.get(d["presetIds"][i], {}).get("dispRef"))
            for i, s in enumerate(d["symbols"])]


for tag, d in (("before", DB), ("after", DA)):
    bad = _ns["keeper_gate"](_legs(d))
    print(f"\nkeeper floors [{tag}]: " + (f"{len(bad)} VIOLATION(S)" if bad else "all legs clear"))
    for b in bad:
        print("  " + b)
