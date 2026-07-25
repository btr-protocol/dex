#!/usr/bin/env python3
"""compose_usdc_cross.py — build <SYM>-USDC 10s tapes from the NXR <SYM>-USD + USDC-USD series.

The 2026-07-24 NXR landing ships /USD tapes for the six stables that previously had no usable
/USDC compose (USDC, USDG, U, SYRUPUSDC, USDF, USDTB). Pool params are quoted against the USDC
base, so the cross is the fit input:  X/USDC = (X/USD) / (USDC/USD).

Both legs share the NXR 10s grid, so the join is exact on ts (no interpolation, no forward-fill:
a bar missing on either leg is dropped — a synthesized bar would fabricate an offset the keeper
would never see). Activity fields (vbid/vask/tick_count) are carried MIN-wise: the cross is only
as real as its thinner leg, and load_tape() drops tick_count==0 bars as synthetic fills.

Run: python3 compose_usdc_cross.py            (writes data/nxr_ohlc/<SYM>-USDC.json)
"""
import json, os
from pathlib import Path

HERE = Path(__file__).parent
OHLC = HERE / "data" / "nxr_ohlc"
SYMS = os.environ.get("SYMS", "USDG,U,SYRUPUSDC,USDF,USDTB").split(",")
OUTNAME = {"SYRUPUSDC": "syrupUSDC"}  # roster casing (make_density_overlay.A)


def load(fn):
    return {r["ts"]: r for r in json.load(open(OHLC / fn))}


def main():
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
