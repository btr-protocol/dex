#!/usr/bin/env python3
"""Pull ~2wk NX-Rates OHLC per BTR testnet asset (base=USDC) for density-derived
risk params. NXR rolls s10 base -> any whitelisted tf server-side. NO API key
(basic JSON OHLC is open). Server hard-caps 10000 rows/req -> chunk under it.

  uv run --with requests python pull_nxr_ohlc.py        # 1min, 2wk
  TF=10 python pull_nxr_ohlc.py                          # 10s (finer, stables)
Writes data/nxr_ohlc/<ASSET>-USDC.json (concat, dedup, sorted).
"""
import json, os, time, urllib.request
from pathlib import Path

BASE = "https://api.nxrates.com/v1/ohlc"
TF   = int(os.environ.get("TF", "10"))          # 10s = finest (offset-from-mark basis needs it)
DAYS = int(os.environ.get("DAYS", "14"))
CHUNK_BARS = 9500                                # < 10000 server cap
OUT = Path(__file__).parent / "data" / "nxr_ohlc"; OUT.mkdir(parents=True, exist_ok=True)

# ASSET/USDC. USDC/USDC omitted (identity=1). CAKE/XAUT only exist vs USDT upstream
# but NXR synthesizes the /USDC cross (verified live).
# USDG: the USDG-USDC compose is glitched (5e8 closes) -> deep native USDG-USDT tape.
# USDF/USDTB: tickers exist but 0 shards on NXR (2026-07-21) -> nothing to pull.
ASSETS = os.environ.get("ASSETS", "USDT,USD1,USDE,FDUSD,U,USDG-USDT,EURC,BTC,ETH,BNB,CAKE,XAUT").split(",")

PACE = float(os.environ.get("PACE", "6"))       # s between reqs; anon IP rate-limits bursts (403)
UA   = "curl/8.6.0"                              # CF WAF 403s the default Python-urllib UA

def get(sym, frm, to):
    u = f"{BASE}/{sym}?tf={TF}&from={frm}&to={to}"
    back = 20
    for _ in range(6):
        try:
            req = urllib.request.Request(u, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=30) as r:
                out = json.load(r); time.sleep(PACE); return out
        except urllib.error.HTTPError as e:
            if e.code == 404:                            # empty range (short-history asset)
                time.sleep(PACE); return []
            print("  403/err backoff", back, e); time.sleep(back); back = min(back*2, 120)
        except Exception as e:
            print("  403/err backoff", back, e); time.sleep(back); back = min(back*2, 120)
    raise RuntimeError(f"fail {u}")

now = int(time.time()*1000); start = now - DAYS*86400*1000
step = CHUNK_BARS*TF*1000
for a in ASSETS:
    sym = a if "-" in a else f"{a}-USDC"; rows = {}
    frm = start
    try:
        while frm < now:
            to = min(frm+step, now)
            for r in get(sym, frm, to): rows[r["ts"]] = r
            frm = to
    except RuntimeError as e:
        print(f"{sym:11} FAIL {e} — skipping asset"); continue
    data = [rows[t] for t in sorted(rows)]
    if not data:
        print(f"{sym:11} rows=0 SKIP (no history)"); continue
    (OUT/f"{sym}.json").write_text(json.dumps(data))
    span_h = (data[-1]["ts"]-data[0]["ts"])/3.6e6
    print(f"{sym:11} rows={len(data):6d} span={span_h/24:.1f}d "
          f"[{data[0]['ts']}..{data[-1]['ts']}]")
    time.sleep(0.3)
print("done ->", OUT)
