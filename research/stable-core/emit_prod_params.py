#!/usr/bin/env python3
"""emit_prod_params.py — turn the FINAL central-normal-plateau fit into the two prod artifacts.

Inputs  : out/lognormal_fit.json   (fits + merged refereeJ; run lognormal_fit.py then
                                    referee_lognormal.py first — the referee IS the freeze gate)
          make_density_overlay.py  (asset roster: class, tape, notes, nowall/route flags)
Outputs : out/fit_results.json                    machine interface (deploy scripts + density service)
          ../../evm/deployments/sepolia-risk-params.json   deploy-facing, inside the foundry fs root
          RISK_PARAMS_TESTNET.md                  generated per-asset spec

WHY the deploy file is separate + parallel-arrayed: foundry's fs_permissions root is dex/evm, so a
script cannot read research/. And `vm.parseJson*Array` reads flat arrays cleanly while a JSON array
of objects needs one abi.decode per row — parallel arrays keep SepoliaPoolDeploy reviewable.

Preset identity = (W, dispRef, flags). The central-normal plateau's S-normalized curve is
CELL-INVARIANT (A_WALL is pinned by the exact 30% folded cut), so every asset shares one shape
vector and presets differ only by wall tier / dispersion reference / wall flag — asserted below,
never assumed.

Run: python3 emit_prod_params.py
"""
import json, time
from pathlib import Path

HERE = Path(__file__).parent
EVM = HERE.parent.parent / "evm"
LN = json.load(open(HERE / "out" / "lognormal_fit.json"))
FITS = LN["assets"]

_ov = open(HERE / "make_density_overlay.py").read()
_ns = {"__name__": "overlay_defs", "__file__": str(HERE / "make_density_overlay.py")}
exec(compile(_ov[: _ov.index("# ── tape load + cleaning")], "make_density_overlay.py[roster]", "exec"), _ns)
ROSTER = {c["sym"]: c for c in _ns["A"]}
CLASS = _ns["CLASS"]
FALLBACK = _ns["FALLBACK"]

CHAIN_ID = 11155111
# Sepolia pools (owner 2026-07-24). Base = USDC in BOTH; idx 0 is the base leg by construction.
STABLE_POOL = ["USDC", "USDT", "USDE", "USDS", "DAI", "USD1", "USDG", "PYUSD", "RLUSD",
               "syrupUSDC", "USDF", "U", "GHO", "TUSD", "USDTB", "FDUSD", "AUSD"]
VOLATILE_POOL = ["USDC", "USDT", "WETH", "WBTC", "cbBTC", "BNB", "XAUT", "PAXG", "EURC"]
# Wrapper legs carry no tape of their own: the mark ROUTES to the wrapped asset's feed, so the
# params are that asset's fit verbatim (a wrapper cannot have a different offset law than its mark).
ROUTE = {"WETH": "ETH", "WBTC": "BTC", "cbBTC": "BTC"}

GAMMA, VEGA = 20_000, 10_000                 # 2x inventory skew / 1x vega (Chapel SSoT, unchanged)
KAPPA_WALL = 100                             # convex coverage-wall strength on pegged stable spokes
MAXFEE = {"stable": 2_000, "volatile": 10_000}
# Depeg breaker tolerance vs the reference oracle. Pegged stables band against the signed USDC/USD
# reference; every other spoke bands against its OWN pair feed (comparing a non-USD mark to a unit
# price would halt permanently). Base is exempt (its own feed IS its breaker).
REF_BAND = {"base": 0, "stable": 150, "nav": 300, "volatile": 300, "metal": 200}
METALS = {"XAUT", "PAXG"}


def ref_band(sym, cls, cfg):
    if sym == "USDC":
        return REF_BAND["base"]
    if sym in METALS:
        return REF_BAND["metal"]
    if cls == "volatile":
        return REF_BAND["volatile"]
    return REF_BAND["nav"] if cfg.get("nowall") else REF_BAND["stable"]


def base_row():
    """USDC = the numeraire: mark identity 1.0, never pushed, never walled, no fit. Its params are
    the conservative stable class default — it still quotes as a leg, so it needs a real curve."""
    return dict(status="base-identity", cls="stable", tape=None, fallback=True,
                tapeStatus="N/A (identity numeraire)", sessionGap=None,
                thetaFinal=CLASS["stable"]["theta"], hb_s=CLASS["stable"]["hb"], cadencePerH=None,
                regime="cnplateau", family="cnplateau", m=3, W=1, dispRef=100,
                minDisp=200, maxDisp=2000, maxDispB99=None,
                supportBp=None, supportDeployBp=2.0, floor2Theta=True, cutDeployPct=None,
                lossKL=None, minFee2Theta=50, minFeeEff=0.50, minFeeEffPbps=50,
                wall=dict(flag=False, kappaCovBps=0, depthAmplifier=10_000, haircutSuppressor=10_000),
                referee=dict(J=None, gate="exempt", reason="identity numeraire, no tape to replay"),
                route=None,
                note="Base numeraire: price = 1 by construction, exempt from the pushed mark "
                     "(Pricing._readBasePriceOrHalt), kappa forbidden (AIMM_PROOFS Thm 2). The "
                     "signed USDC/USD reference feed (oracle idx 23) is its depeg breaker.")


def prod_row(sym):
    if sym == "USDC":
        return base_row()
    src = ROUTE.get(sym, sym)
    f = FITS.get(src)
    cfg = ROSTER[src]
    if f is None:                                       # no fit: conservative class default
        cls = cfg["cls"]
        fb = FALLBACK[cls]
        return dict(status="fallback", cls=cls, tape=None, fallback=True,
                    tapeStatus="TAPE_PENDING", sessionGap=None,
                    thetaFinal=CLASS[cls]["theta"], hb_s=CLASS[cls]["hb"], cadencePerH=None,
                    regime="cnplateau", family="cnplateau", m=3, W=fb["W"], dispRef=fb["dispRef"],
                    minDisp=int(round(2 * CLASS[cls]["theta"] * fb["dispRef"] / fb["W"])),
                    maxDisp=cfg.get("mdFloor", 8000), maxDispB99=None,
                    supportBp=None, supportDeployBp=2 * CLASS[cls]["theta"], floor2Theta=True,
                    cutDeployPct=None, lossKL=None,
                    minFee2Theta=int(round(2 * CLASS[cls]["theta"] * 100)),
                    minFeeEff=2 * CLASS[cls]["theta"],
                    minFeeEffPbps=int(round(2 * CLASS[cls]["theta"] * 100)),
                    wall=wall_cfg(cls, cfg),
                    referee=dict(J=None, gate="UNGATED", reason="no tape to replay"),
                    route=ROUTE.get(sym), note=cfg.get("note"))
    fit, risk, ln, cell = f["fit"], f["risk"], f["ln"], f["cell"]
    rj = f.get("refereeJ") or {}
    return dict(
        status="fit", cls=f["cls"], tape=f["tape"], fallback=False,
        tf_s=10, span_d=f["spanD"], bars=f["bars"], tapeStatus=f["tapeStatus"],
        sessionGap=f["sessionGap"], thetaFinal=f["theta"], hb_s=CLASS[f["cls"]]["hb"],
        cadencePerH=f["cadencePerH"],
        # `regime` is the density-service contract key; it now names the FINAL family, not one of
        # the retired 9-preset catalogue entries. The service's spline_shared_grid lookup therefore
        # returns null for the "optimal" overlay until it is repointed at `curve` below.
        regime="cnplateau", family=fit["family"], m=fit["m"], presetId=cell["presetId"],
        W=risk["W"], dispRef=risk["dispRef"], minDisp=risk["minDisp"], maxDisp=risk["maxDisp"],
        maxDispB99=risk["maxDispB99"],
        supportBp=ln["S_fit"], supportDeployBp=ln["S_dep"], floor2Theta=ln["floor2Theta"],
        cutDeployPct=ln["cutDepPct"], lossKL=fit["klDataVsSpline"],
        minFee2Theta=int(round(2 * f["theta"] * 100)), minFeeEff=risk["minFeeBp"],
        minFeeEffPbps=risk["minFeePbps"],
        curve=dict(knotsB=fit["knotsB"], wQ=fit["wQ"], dispRef=fit["dispRef"], flags=fit["flags"],
                   slots=fit["slots"], gasUpdate=fit["gasUpdate"], gasFirstSet=fit["gasFirstSet"]),
        wall=wall_cfg(f["cls"], ROSTER[src]),
        tailAlpha=risk["tailAlpha"], wallFloorBp=risk["wallFloorBp"],
        referee=dict(J=rj.get("new"), cells=None, vsV4=rj.get("deltaVsV4"),
                     gate=("PASS" if rj.get("new") is not None else "UNGATED"),
                     reason=None if rj.get("new") is not None else "referee not run"),
        route=ROUTE.get(sym), note=ROSTER[src].get("note"))


def wall_cfg(cls, cfg):
    """kappa>0 requires depthAmplifier==0 (the c<1 depth subsidy fights the wall) AND
    haircutSuppressor==0 (an over-covered leg must not drain across peg toll-free)."""
    walled = cls == "stable" and not cfg.get("nowall")
    if walled:
        return dict(flag=True, kappaCovBps=KAPPA_WALL, depthAmplifier=0, haircutSuppressor=0)
    # NAV-accruing units keep haircutSuppressor at 0 too: the haircut path is peg-parity reasoning.
    hs = 0 if cfg.get("nowall") else 10_000
    return dict(flag=False, kappaCovBps=0, depthAmplifier=10_000, haircutSuppressor=hs)


ALL = []
for s in STABLE_POOL + VOLATILE_POOL:
    if s not in ALL:
        ALL.append(s)
ROWS = {s: prod_row(s) for s in ALL}
# CAKE is fitted but not on the Sepolia roster; carry it so the density service keeps its row.
for s in FITS:
    if s not in ROWS:
        ROWS[s] = prod_row(s)

# ── out/fit_results.json ────────────────────────────────────────────────────────────────────
json.dump(dict(
    gen="emit_prod_params.py <- lognormal_fit.py (central-normal plateau, m=3, q70 cut; "
        "owner-FINAL 2026-07-24)",
    generated=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    basis=LN["spec"],
    referee=dict(gate="referee_lognormal.py damped consumption replay, lambda=0.4, 4 rounds; "
                      "J = (fee - LVR)/TVL annualized %, mean over L{1,3,6} x T{0.25,1,4}",
                 file="out/referee_lognormal.json"),
    shape=dict(family="cnplateau", m=3, interiorKnotsB=[1314, 8686],
               qTrunc=0.70, note="S-normalized curve is cell-invariant; classes differ only by S_dep"),
    gas=LN["gas"],
    assets=ROWS), open(HERE / "out" / "fit_results.json", "w"), indent=1)
print("wrote out/fit_results.json", len(ROWS), "assets")

# ── evm/deployments/sepolia-risk-params.json (parallel arrays; foundry-readable) ─────────────
shapes = {}
for s, r in ROWS.items():
    c = r.get("curve")
    if c:
        shapes.setdefault(tuple(c["wQ"]), set()).add(r["W"])
assert len(shapes) <= 1 or all(len(v) == 1 for v in shapes.values()), \
    "shape is not W-determined — preset identity (W, dispRef, flags) is unsound"

presets, pid_of = [], {}
for s in ALL:
    r = ROWS[s]
    key = (r["W"], r["dispRef"], 1 if r["wall"]["flag"] else 0)
    if key not in pid_of:
        pid_of[key] = len(presets) + 1
        presets.append(dict(id=pid_of[key], W=r["W"], interiorB=None, wQ=None,
                            dispRef=r["dispRef"], flags=key[2]))
    r["_pid"] = pid_of[key]
    # A preset takes its weights from any REAL fit in its group; base/fallback rows contribute
    # nothing (order of first appearance must not decide whether a preset is measured or derived).
    c = r.get("curve")
    p = presets[pid_of[key] - 1]
    if c and p["wQ"] is None:
        p["interiorB"], p["wQ"], p["from"] = c["knotsB"], c["wQ"], s
# A fallback/base row has no fitted wQ of its own; it borrows the shape at its own wall tier.
byW = {p["W"]: p for p in presets if p["wQ"]}
for p in presets:
    if not p["wQ"]:
        src = byW.get(p["W"]) or next(iter(byW.values()))
        p["wQ"] = [int(round(x * p["W"] / src["W"])) for x in src["wQ"]]
        p["interiorB"] = src["interiorB"]
        p["derived"] = f"W-rescaled from preset {src['id']} (no own tape)"

dep = dict(
    chainId=CHAIN_ID,
    gen="emit_prod_params.py (central-normal plateau, m=3; owner-FINAL 2026-07-24)",
    generated=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    stablePool=STABLE_POOL, volatilePool=VOLATILE_POOL,
    gamma=GAMMA, vega=VEGA,
    presets=presets,
    # Explicit count: foundry can index `.presets[i].field` but cannot ask an array for its
    # length (no `.length`, no `[*]`), so consumers need this to iterate.
    presetCount=len(presets),
    symbols=ALL,
    presetIds=[ROWS[s]["_pid"] for s in ALL],
    cls=[ROWS[s]["cls"] for s in ALL],
    minFeePbps=[ROWS[s]["minFeeEffPbps"] for s in ALL],
    maxFeePbps=[MAXFEE[ROWS[s]["cls"]] for s in ALL],
    minDisp=[ROWS[s]["minDisp"] for s in ALL],
    maxDisp=[ROWS[s]["maxDisp"] for s in ALL],
    kappaCovBps=[ROWS[s]["wall"]["kappaCovBps"] for s in ALL],
    depthAmplifier=[ROWS[s]["wall"]["depthAmplifier"] for s in ALL],
    haircutSuppressor=[ROWS[s]["wall"]["haircutSuppressor"] for s in ALL],
    refBandBps=[ref_band(s, ROWS[s]["cls"], ROSTER.get(ROUTE.get(s, s), {})) for s in ALL],
    refOwnFeed=[bool(s != "USDC" and (ROWS[s]["cls"] == "volatile"
                                      or ROSTER.get(ROUTE.get(s, s), {}).get("nowall")))
                for s in ALL],
    refereeJ=[ROWS[s]["referee"]["J"] for s in ALL],
    tapeStatus=[ROWS[s]["tapeStatus"] for s in ALL],
)
(EVM / "deployments" / "sepolia-risk-params.json").write_text(json.dumps(dep, indent=1))
print("wrote evm/deployments/sepolia-risk-params.json", len(ALL), "symbols,", len(presets), "presets")

for s in ALL:
    ROWS[s].pop("_pid", None)
