#!/usr/bin/env python3
"""compose_usdc_cross.py — build <SYM>-USDC 10s tapes from the NXR <SYM>-USD + USDC-USD series.

The 2026-07-24 NXR landing ships /USD tapes for the six stables that previously had no usable
/USDC compose (USDC, USDG, U, SYRUPUSDC, USDF, USDTB). Pool params are quoted against the USDC
base, so the cross is the fit input:  X/USDC = (X/USD) / (USDC/USD).

Both legs share the NXR 10s grid, so the join is exact on ts (no interpolation, no forward-fill:
a bar missing on either leg is dropped — a synthesized bar would fabricate an offset the keeper
would never see). Activity fields (vbid/vask/tick_count) are carried MIN-wise: the cross is only
as real as its thinner leg, and load_tape() drops tick_count==0 bars as synthetic fills.

FX legs carry NO USDC compose: the keeper marks them straight off the Pyth USD native, inverting
USD/X where the native is USD-quoted (keepers/scripts/gen-sepolia-feeds.py FEEDS, the on-chain
feed SoT — imported, never restated here). Fitting the composed cross would describe a mark the
keeper never pushes, so `FX=` derives <NAME>.json from exactly that source instead.

Run: python3 compose_usdc_cross.py                      (writes data/nxr_ohlc/<SYM>-USDC.json)
     FX=QCAD-USDC,AUDF-USDC python3 compose_usdc_cross.py   (fx legs from their native feeds)
"""
import json, os
from pathlib import Path

HERE = Path(__file__).parent
OHLC = HERE / "data" / "nxr_ohlc"
SYMS = os.environ.get("SYMS", "USDG,U,SYRUPUSDC,USDF,USDTB").split(",")
FX = list(filter(None, os.environ.get("FX", "").split(",")))
OUTNAME = {"SYRUPUSDC": "syrupUSDC"}  # roster casing (make_density_overlay.A)


def feed_sot():
    """{on-chain feed name: FEEDS row} from the keepers sibling. No local copy: a duplicated
    symbol/invert table is exactly how a fit ends up describing the wrong mark."""
    import importlib.util, sys
    sys.dont_write_bytecode = True          # never leave a __pycache__ in the sibling repo
    p = HERE.parents[2] / "keepers" / "scripts" / "gen-sepolia-feeds.py"
    if not p.exists():
        raise SystemExit(f"FX= needs the keepers sibling for the feed SoT: {p} missing")
    spec = importlib.util.spec_from_file_location("gen_sepolia_feeds", p)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return {f["name"]: f for f in mod.FEEDS}


def derive_fx():
    sot = feed_sot()
    for name in FX:
        f = sot.get(name)
        if f is None:
            print(f"{name:11} NOT IN FEED SoT — skip"); continue
        src = OHLC / f"{f['symbol']}.json"
        if not src.exists():
            print(f"{name:11} MISSING {src.name} — skip"); continue
        rows = json.load(open(src))
        if f.get("invert"):     # 1/x flips the bar: high<->low, and the bid/ask sides swap
            rows = [dict(r, open=1 / r["open"], high=1 / r["low"], low=1 / r["high"],
                         close=1 / r["close"], vbid=r.get("vask", 0), vask=r.get("vbid", 0))
                    for r in rows if min(r["open"], r["high"], r["low"], r["close"]) > 0]
        (OHLC / f"{name}.json").write_text(json.dumps(rows))
        live = sum(1 for r in rows if r.get("tick_count", 0) > 0)
        span_d = (rows[-1]["ts"] - rows[0]["ts"]) / 86.4e6
        print(f"{name:11} rows={len(rows):6d} live={live:6d} ({100 * live / len(rows):.0f}%) "
              f"span={span_d:.1f}d <- {f['symbol']}{' inverted' if f.get('invert') else ''}")


def load(fn):
    return {r["ts"]: r for r in json.load(open(OHLC / fn))}


def main():
    if FX:
        return derive_fx()
    base = load("USDC-USD.json")
    for sym in SYMS:
        src = OHLC / f"{sym}-USD.json"
        if not src.exists():
            print(f"{sym:11} MISSING {src.name} — skip")
            continue
        num = load(src.name)
        rows = []
        for ts in sorted(set(num) & set(base)):
            a, b = num[ts], base[ts]
            if a["close"] <= 0 or b["close"] <= 0:
                continue
            rows.append(
                dict(
                    ts=ts,
                    open=a["open"] / b["open"] if a["open"] > 0 and b["open"] > 0 else a["close"] / b["close"],
                    # high/low of a ratio are not the ratio of high/low; the conservative envelope
                    # (num extreme over the opposing base extreme) keeps the bar range a superset.
                    high=a["high"] / b["low"] if b["low"] > 0 else a["close"] / b["close"],
                    low=a["low"] / b["high"] if b["high"] > 0 else a["close"] / b["close"],
                    close=a["close"] / b["close"],
                    vbid=min(a.get("vbid", 0), b.get("vbid", 0)),
                    vask=min(a.get("vask", 0), b.get("vask", 0)),
                    tick_count=min(a.get("tick_count", 0), b.get("tick_count", 0)),
                )
            )
        if not rows:
            print(f"{sym:11} rows=0 — skip")
            continue
        out = OHLC / f"{OUTNAME.get(sym, sym)}-USDC.json"
        out.write_text(json.dumps(rows))
        live = sum(1 for r in rows if r["tick_count"] > 0)
        span_d = (rows[-1]["ts"] - rows[0]["ts"]) / 86.4e6
        print(
            f"{OUTNAME.get(sym, sym):11} rows={len(rows):6d} live={live:6d} "
            f"({100 * live / len(rows):.0f}%) span={span_d:.1f}d -> {out.name}"
        )


if __name__ == "__main__":
    main()
