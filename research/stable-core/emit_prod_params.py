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
import hashlib, importlib.util, json, math, os, time


def _load_keeper_feeds() -> dict:
    """The keeper catalog is the single source of truth for symbol<->feed naming
    (keepers/scripts/gen-sepolia-feeds.py FEEDS). Imported, never copied, so a
    catalog change cannot silently desync the deploy artifact."""
    from pathlib import Path as _P
    src = _P(__file__).resolve().parents[3] / "keepers/scripts/gen-sepolia-feeds.py"
    if not src.exists():
        raise SystemExit(f"keeper catalog SSoT not found: {src}")
    spec = importlib.util.spec_from_file_location("_gen_sepolia_feeds", src)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return {f["name"]: f for f in mod.FEEDS}


_KEEPER_FEEDS = _load_keeper_feeds()


def _load_prior_usd_quoted() -> dict:
    """Previously deployed usdQuoted flags, for assets parked out of the catalog."""
    from pathlib import Path as _P
    f = _P(__file__).resolve().parents[2] / "evm/deployments/sepolia-risk-params.json"
    if not f.exists():
        return {}
    d = json.loads(f.read_text())
    return dict(zip(d.get("symbols", []), d.get("usdQuoted", [])))


_PRIOR_USD_QUOTED = _load_prior_usd_quoted()
from pathlib import Path

HERE = Path(__file__).parent
EVM = HERE.parent.parent / "evm"
LN = json.load(open(HERE / "out" / "lognormal_fit.json"))
FITS = LN["assets"]
GEN = ("emit_prod_params.py <- lognormal_fit.py (cnplateau m=3; theta from the keeper config; "
       "S_dep=max(q70, 2*theta_keeper, feeQ99, wallFloor); minFee=max(2*theta_keeper, 2*theta+excPrem))")
MINFEE_HARD = LN["spec"]["minFeeHardPbps"]     # class hard floors, from the fit spec (one source)

_ov = open(HERE / "make_density_overlay.py").read()
_ns = {"__name__": "overlay_defs", "__file__": str(HERE / "make_density_overlay.py")}
exec(compile(_ov[: _ov.index("# ── tape load + cleaning")], "make_density_overlay.py[roster]", "exec"), _ns)
ROSTER = {c["sym"]: c for c in _ns["A"]}
CLASS = _ns["CLASS"]
FALLBACK = _ns["FALLBACK"]
# theta is keeper-owned (keepers/oracle.sepolia.toml). keeper_gate re-checks, per emitted leg,
# the two floors the keeper enforces at boot: minFee >= 2theta (H-2) and support >= 2theta.
keeper_spec, keeper_gate, tape_last_bar = _ns["keeper_spec"], _ns["keeper_gate"], _ns["tape_last_bar"]

CHAIN_ID = 11155111
# Sepolia pools (owner 2026-07-24). Base = USDC in BOTH; idx 0 is the base leg by construction.
STABLE_POOL = ["USDC", "USDT", "USDE", "USDS", "DAI", "USD1", "USDG", "PYUSD", "RLUSD",
               "USDF", "U", "GHO", "TUSD", "USDTB", "FDUSD", "AUSD"]
VOLATILE_POOL = ["USDC", "USDT", "WETH", "WBTC", "cbBTC", "BNB", "XAUT", "PAXG", "EURC"]
# FX core: mock ERC20s of real fiat-backed tokens, marked by the REAL NXR FX feeds
# (CAD/AUD/BRL/JPY/KRW-USD). Its own class because a fiat leg is neither ~1.0 against
# USDC nor as wide as a crypto major.
FX_POOL = ["USDC", "EURC", "QCAD", "AUDF", "BRLA", "JPYC", "KRW1"]
# Wrapper legs carry no tape of their own: the mark ROUTES to the wrapped asset's feed, so the
# params are that asset's fit verbatim (a wrapper cannot have a different offset law than its mark).
ROUTE = {"WETH": "ETH", "WBTC": "BTC", "cbBTC": "BTC"}

GAMMA, VEGA = 20_000, 10_000                 # 2x inventory skew / 1x vega (Chapel SSoT, unchanged)
KAPPA_WALL = 100                             # convex coverage-wall strength on pegged stable spokes
# fx = the fiat-FX tier declared at the protocol layer (SepoliaPoolDeploy.s.sol: p.fx, FX_TTL=3600,
# FX_MAXDEV=75bp, SIGMA_SEED_FX=800; SeedRiskFences.s.sol banner: "maxFee = 2000 (stable) / 10000
# (volatile) / 5000 (fx)"). That deploy script REJECTS an unrecognized cls, so "fx" was always meant
# to reach this dict: it just never had a MAXFEE/REF_BAND entry, so these 5 legs never emitted.
MAXFEE = {"stable": 2_000, "volatile": 10_000, "fx": 5_000}
# Depeg breaker tolerance vs the reference oracle. Pegged stables band against the signed USDC/USD
# reference; every other spoke bands against its OWN pair feed (comparing a non-USD mark to a unit
# price would halt permanently). Base is exempt (its own feed IS its breaker).
# fx REF_BAND=250 restores the value the 2026-07-27 FX-core bootstrap (commit 3c0c535) hand-seeded
# directly into the deploy JSON before any fit existed; this just re-derives it through the emitter
# instead of relying on preserve-extras to copy it forward forever.
REF_BAND = {"base": 0, "stable": 150, "nav": 300, "volatile": 300, "metal": 200, "fx": 250}
METALS = {"XAUT", "PAXG"}
# Deploy-cls "fx" legs: QCAD/AUDF/BRLA/JPYC/KRW1 only. EURC is ALSO fx-core (and FX_POOL) but was
# owner-reclassed stable->volatile on 2026-07-21 for its OWN pool AND fx-core (SepoliaPoolDeploy.s.sol
# p.fx would otherwise wrongly hand it FX_MAXDEV=75bp / FX_TTL=3600 in fx-core, diverging from its
# volatile-core deploy of the same feed): ROSTER's cls="volatile" for EURC already encodes that and
# must NOT be overridden here. Distinct from ROSTER's cls field, which for ALL fx=True legs (EURC
# included) stays "volatile": that field selects the DENSITY-FIT theta/heartbeat spec
# (make_density_overlay.py CLASS/TAU_INV), a different axis from this deploy-facing risk tier.
FX_RISK_CLASS = {"QCAD", "AUDF", "BRLA", "JPYC", "KRW1"}


def deploy_cls(sym, fit_cls):
    return "fx" if sym in FX_RISK_CLASS else fit_cls


def ref_band(sym, cls, cfg):
    if sym == "USDC":
        return REF_BAND["base"]
    if sym in METALS:
        return REF_BAND["metal"]
    if cls == "fx":
        return REF_BAND["fx"]
    if cls == "volatile":
        return REF_BAND["volatile"]
    return REF_BAND["nav"] if cfg.get("nowall") else REF_BAND["stable"]


def prod_row(sym):
    """One path for every leg, USDC included. The base used to short-circuit to a hand-copied
    genesis tuple: never fitted, never re-derived, and the only stable carrying
    haircutSuppressor 10000 purely because it skipped wall_cfg. Its exemptions are declared in
    the roster now (nowall = kappa forbidden, AIMM_PROOFS Thm 2) and everything else falls out
    of the same class-default arithmetic as any other tape-less leg."""
    src = ROUTE.get(sym, sym)
    f = FITS.get(src)
    cfg = ROSTER[src]
    if f is None:                                       # no fit: conservative class default
        cls = cfg["cls"]
        fb = FALLBACK[cls]
        ks = keeper_spec(sym)                          # None: leg the keeper does not sign
        th = ks["theta"] if ks else CLASS[cls]["theta"]
        # HOLD ratchet, same rule as maxDisp: a class default never NARROWS a deployed band.
        cur = cfg.get("cur")
        return dict(status="fallback", cls=deploy_cls(sym, cls), tape=None, fallback=True,
                    tapeStatus=cfg.get("tapeStatus") or "TAPE_PENDING", sessionGap=None,
                    thetaFinal=th, thetaKeeper=(ks or {}).get("theta"),
                    hb_s=ks["hb"] if ks else CLASS[cls]["hb"], cadencePerH=None,
                    regime="cnplateau", family="cnplateau", m=3, W=fb["W"], dispRef=fb["dispRef"],
                    minDisp=max(int(math.ceil(2 * th * fb["dispRef"] / fb["W"])),
                                cur[3] if cur else 0),
                    maxDisp=cfg.get("mdFloor", 8000), maxDispB99=None,
                    supportBp=None, supportDeployBp=2 * th, floor2Theta=True,
                    cutDeployPct=None, lossKL=None,
                    minFee2Theta=math.ceil(2 * th * 100),
                    minFeeEff=2 * th,
                    minFeeEffPbps=max(math.ceil(2 * th * 100), MINFEE_HARD[cls]),
                    wall=wall_cfg(cls, cfg),
                    referee=dict(J=None, gate="UNGATED", reason="no tape to replay"),
                    route=ROUTE.get(sym), note=cfg.get("note"))
    fit, risk, ln, cell = f["fit"], f["risk"], f["ln"], f["cell"]
    rj = f.get("refereeJ") or {}
    return dict(
        status="fit", cls=deploy_cls(sym, f["cls"]), tape=f["tape"], fallback=False,
        tf_s=10, span_d=f["spanD"], bars=f["bars"], tapeStatus=f["tapeStatus"],
        sessionGap=f["sessionGap"], thetaFinal=f["theta"], thetaKeeper=f.get("thetaKeeper"),
        hb_s=f.get("hb_s") or CLASS[f["cls"]]["hb"], tapeMeta=f.get("tapeMeta"),
        cadencePerH=f["cadencePerH"],
        # `regime` is the density-service contract key; it now names the FINAL family, not one of
        # the retired 9-preset catalogue entries. The service's spline_shared_grid lookup therefore
        # returns null for the "optimal" overlay until it is repointed at `curve` below.
        regime="cnplateau", family=fit["family"], m=fit["m"], presetId=cell["presetId"],
        W=risk["W"], dispRef=risk["dispRef"], minDisp=risk["minDisp"], maxDisp=risk["maxDisp"],
        maxDispB99=risk["maxDispB99"],
        supportBp=ln["S_fit"], supportDeployBp=ln["S_dep"], floor2Theta=ln["floor2Theta"],
        floorBreadth=ln.get("floorBreadth"), breadth=ln.get("breadth"),
        feeQ99=ln.get("feeQ99"), cutDeployPct=ln["cutDepPct"], lossKL=fit["klDataVsSpline"],
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
for s in STABLE_POOL + VOLATILE_POOL + FX_POOL:
    if s not in ALL:
        ALL.append(s)
ROWS = {s: prod_row(s) for s in ALL}
# CAKE is fitted but not on the Sepolia roster; carry it so the density service keeps its row.
for s in FITS:
    if s not in ROWS:
        ROWS[s] = prod_row(s)


def _usd_quoted(sym: str) -> bool:
    """True when the NXR-signed symbol is USD-quoted but the on-chain feed is
    named `<sym>-USDC`, so `Pricing._denominate` must divide by the idx-24
    USDC-USD mark. Read from the keeper catalog rather than duplicated here —
    one change, one place."""
    if sym == "USDC":
        return False  # the base IS the divisor
    feed = _KEEPER_FEEDS.get(f"{sym}-USDC")
    if feed is not None:
        return not feed["symbol"].endswith("-USDC")
    # PARKED asset: deployed in a pool but currently unsigned (e.g. XAUT, pulled
    # from the catalog 2026-07-29 over cross-replica sigma divergence). Keep the
    # flag it was deployed with — re-deriving it from nothing would silently flip
    # the pool's denomination the day it is relisted. A genuinely NEW asset has
    # no prior value and still aborts.
    prior = _PRIOR_USD_QUOTED.get(sym)
    if prior is None:
        raise SystemExit(
            f"usdQuoted: {sym} is absent from the keeper catalog SSoT and has no "
            f"prior declared value — add it to gen-sepolia-feeds.py FEEDS first")
    print(f"  usdQuoted: {sym} parked (not in catalog), preserving deployed value {prior}")
    return prior


# Output roots. Overridable so a constrained dry run reports what it WOULD write without
# touching the committed deploy artifact.
OUT_DIR = Path(os.environ.get("EMIT_OUT_DIR", HERE / "out"))
DEPLOY_DIR = Path(os.environ.get("EMIT_DEPLOY_DIR", EVM / "deployments"))


def provenance():
    """Bind the artifacts to their INPUTS, not to the wall clock.

    `generated` stamps the WRITE. The two artifacts carried the identical stamp
    2026-08-02T10:37:11Z and disagreed on the numbers (fit_results WETH 5047 vs deploy 2034),
    so the deploy file was not written by the run whose stamp it bore and nothing could tell.
    runId hashes the fit input plus the last bar of every tape behind it: two files sharing a
    runId were written from the same inputs, and a stale tape is visible in the artifact."""
    fit_raw = (HERE / "out" / "lognormal_fit.json").read_bytes()
    tapes = {r["tape"]: tape_last_bar(r["tape"]) for r in ROWS.values() if r.get("tape")}
    # hash the last BARS, not their age: two runs over the same inputs must share a runId.
    blob = fit_raw + json.dumps({k: v["lastBar"] for k, v in sorted(tapes.items())}).encode()
    return dict(runId=hashlib.sha256(blob).hexdigest()[:16],
                fitSha256=hashlib.sha256(fit_raw).hexdigest()[:16],
                keeperConfig=str(_ns["KEEPER_TOML"]),
                tapes=dict(sorted(tapes.items())))


def verify_pair(fit_path, dep_path):
    """Refuse to write over a pair that disagrees with itself: the on-disk deploy file then
    carries a stamp some other run wrote, and this run would silently inherit its provenance.
    EMIT_FORCE=1 acknowledges and overwrites."""
    if not (fit_path.exists() and dep_path.exists()):
        return
    a, b = json.loads(fit_path.read_text()), json.loads(dep_path.read_text())
    ra = (a.get("provenance") or {}).get("runId")
    rb = (b.get("provenance") or {}).get("runId")
    bad = [f"runId {ra} != {rb}"] if (ra or rb) and ra != rb else []
    fits = a.get("assets") or {}
    for i, s in enumerate(b.get("symbols") or []):                 # pre-provenance artifacts
        r = fits.get(s)
        if not r:
            continue
        for k, col in (("minFeeEffPbps", "minFeePbps"), ("minDisp", "minDisp")):
            if col in b and r.get(k) != b[col][i]:
                bad.append(f"{s}.{col}: fit_results {r.get(k)} vs deploy {b[col][i]}")
    if bad and os.environ.get("EMIT_FORCE") != "1":
        raise SystemExit("REFUSING TO EMIT: the on-disk artifacts were not written by the same "
                         "run.\n  " + "\n  ".join(bad[:12])
                         + f"\n({len(bad)} disagreement(s)). Re-emit both from one run, or set "
                           "EMIT_FORCE=1 to overwrite.")


def gate_or_die(dep):
    """The keeper's own floors, per emitted leg, against the KEEPER's theta. A generator that
    emits a value the push keeper refuses to boot on must FAIL, not warn: H-2 has no escape
    hatch (keepers/src/oracle/mod.rs:502) and aborts the boot, marks go stale, pools halt."""
    byid = {p["id"]: p for p in dep["presets"]}
    legs = [(s, dep["minFeePbps"][i], dep["minDisp"][i],
             byid.get(dep["presetIds"][i], {}).get("W"),          # preserved legs may carry a
             byid.get(dep["presetIds"][i], {}).get("dispRef"))    # preset this run did not build
            for i, s in enumerate(dep["symbols"])]
    fails = keeper_gate(legs)
    if fails:
        raise SystemExit("REFUSING TO EMIT: keeper floor violated on "
                         f"{len(fails)} leg(s)\n  " + "\n  ".join(fails))
    print(f"keeper gate: {len(legs)} legs clear minFee >= 2theta and support >= 2theta")


def note_breadth(dep):
    """Generated from what is actually being written. The literal it replaces asserted
    'WETH 2034, WBTC/cbBTC 1887, BNB 1842' whatever the arrays held, and already contradicted
    fit_results."""
    legs = ", ".join(f"{s} {dep['minDisp'][i]} @ preset {dep['presetIds'][i]}"
                     for i, s in enumerate(dep["symbols"]) if dep["cls"][i] != "stable")
    return ("Quiet support is dynamic: S_dep = max(S_fit=q70(|ell|), 2*theta_keeper, feeQ99, "
            "wallFloor=max(pushExcQ99, b99_6min)) from the ~2w fee-kernel density. JSON alone "
            "does not move live density; apply via requestUpdateProfile / executeUpdateProfile "
            "(or adminSetProfile). Non-stable legs as emitted: " + legs + ".")


def emit_artifacts():
    """Write fit_results + sepolia-risk-params. Never run on import (clobbers FX legs)."""
    fit_path, dep_path = OUT_DIR / "fit_results.json", DEPLOY_DIR / "sepolia-risk-params.json"
    verify_pair(fit_path, dep_path)

    # ── evm/deployments/sepolia-risk-params.json (parallel arrays) ───────────
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
        c = r.get("curve")
        p = presets[pid_of[key] - 1]
        if c and p["wQ"] is None:
            p["interiorB"], p["wQ"], p["from"] = c["knotsB"], c["wQ"], s
    byW = {p["W"]: p for p in presets if p["wQ"]}
    for p in presets:
        if not p["wQ"]:
            src = byW.get(p["W"]) or next(iter(byW.values()))
            p["wQ"] = [int(round(x * p["W"] / src["W"])) for x in src["wQ"]]
            p["interiorB"] = src["interiorB"]
            p["derived"] = f"W-rescaled from preset {src['id']} (no own tape)"

    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    prov = provenance()
    dep = dict(
        chainId=CHAIN_ID,
        gen=GEN,
        generated=stamp,
        provenance=prov,
        stablePool=STABLE_POOL, volatilePool=VOLATILE_POOL, fxPool=FX_POOL,
        gamma=GAMMA, vega=VEGA,
        presets=presets,
        presetCount=len(presets),
        symbols=list(ALL),
        # DEN-01: does the pool have to divide this asset's mark by USDC-USD?
        # Derived from the keeper catalog SSoT, never hand-maintained: a leg is
        # usdQuoted iff NXR signs it as `X-USD` while the on-chain feed is named
        # `X-USDC`. The base (USDC) is the divisor and must never be flagged.
        # Dropping this key makes SepoliaPoolDeploy REVERT rather than silently
        # assume "already USDC" — keep it that way.
        usdQuoted=[_usd_quoted(s) for s in ALL],
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
        # fx bands against its own pair feed too (a fiat cross is no closer to the 1.0 USDC peg than
        # a crypto major is): same "not ~1.0, don't use the signed USDC/USD reference" rule as
        # volatile/nowall, just never extended to the fx cls when it was added.
        refOwnFeed=[bool(s != "USDC" and (ROWS[s]["cls"] in ("volatile", "fx")
                                          or ROSTER.get(ROUTE.get(s, s), {}).get("nowall")))
                    for s in ALL],
        refereeJ=[ROWS[s]["referee"]["J"] for s in ALL],
        tapeStatus=[ROWS[s]["tapeStatus"] for s in ALL],
    )

    # Preserve FX / extra legs already in the deploy file (emit roster is core-only).
    if dep_path.exists():
        old = json.loads(dep_path.read_text())
        for k in ("seedUsdPerLeg",):
            if k in old and k not in dep:
                dep[k] = old[k]
        old_syms = old.get("symbols") or []
        extra = [s for s in old_syms if s not in dep["symbols"]]
        if extra:
            idx = {s: i for i, s in enumerate(old_syms)}
            parallel = [k for k, v in old.items() if isinstance(v, list) and len(v) == len(old_syms)
                        and k != "symbols"]
            for s in extra:
                i = idx[s]
                dep["symbols"].append(s)
                for k in parallel:
                    if k not in dep:
                        continue
                    dep[k].append(old[k][i])
            print(f"preserved {len(extra)} extra deploy symbols: {extra}")

    dep["noteBreadth"] = note_breadth(dep)
    gate_or_die(dep)                       # nothing is written until every leg clears

    fit_path.parent.mkdir(parents=True, exist_ok=True)
    dep_path.parent.mkdir(parents=True, exist_ok=True)
    for s in ALL:
        ROWS[s].pop("_pid", None)
    json.dump(dict(
        gen=GEN, generated=stamp, provenance=prov, basis=LN["spec"],
        referee=dict(gate="referee_lognormal.py damped consumption replay, lambda=0.4, 4 rounds; "
                          "J = (fee - LVR)/TVL annualized %, mean over L{1,3,6} x T{0.25,1,4}",
                     file="out/referee_lognormal.json"),
        shape=dict(family="cnplateau", m=3, interiorKnotsB=[1314, 8686],
                   qTrunc=0.70, note="S-normalized curve is cell-invariant; classes differ only by S_dep"),
        breadth=LN["spec"]["breadth"], gas=LN["gas"],
        assets=ROWS), open(fit_path, "w"), indent=1)
    print("wrote", fit_path, len(ROWS), "assets")
    dep_path.write_text(json.dumps(dep, indent=1) + "\n")
    print("wrote", dep_path, len(dep["symbols"]), "symbols,", len(presets), "presets",
          "| runId", prov["runId"])


if __name__ == "__main__":
    emit_artifacts()
