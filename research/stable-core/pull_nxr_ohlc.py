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
TF   = int(os.environ.get("TF", "60"))          # 60=1min (10 ok; 300 -> single req/asset)
DAYS = int(os.environ.get("DAYS", "14"))
CHUNK_BARS = 9500                                # < 10000 server cap
OUT = Path(__file__).parent / "data" / "nxr_ohlc"; OUT.mkdir(parents=True, exist_ok=True)

# ASSET/USDC. USDC/USDC omitted (identity=1). CAKE/XAUT only exist vs USDT upstream
# but NXR synthesizes the /USDC cross (verified live).
ASSETS = ["USDT","USD1","USDE","FDUSD","BTC","ETH","BNB","CAKE","XAUT"]

PACE = float(os.environ.get("PACE", "6"))       # s between reqs; anon IP rate-limits bursts (403)

def get(sym, frm, to):
    u = f"{BASE}/{sym}?tf={TF}&from={frm}&to={to}"
    back = 20
    for _ in range(6):
        try:
            with urllib.request.urlopen(u, timeout=30) as r:
                out = json.load(r); time.sleep(PACE); return out
        except Exception as e:
            print("  403/err backoff", back, e); time.sleep(back); back = min(back*2, 120)
    raise RuntimeError(f"fail {u}")

now = int(time.time()*1000); start = now - DAYS*86400*1000
step = CHUNK_BARS*TF*1000
for a in ASSETS:
    sym = f"{a}-USDC"; rows = {}
    frm = start
    while frm < now:
        to = min(frm+step, now)
        for r in get(sym, frm, to): rows[r["ts"]] = r
        frm = to
    data = [rows[t] for t in sorted(rows)]
    (OUT/f"{sym}.json").write_text(json.dumps(data))
    span_h = (data[-1]["ts"]-data[0]["ts"])/3.6e6 if data else 0
    print(f"{sym:11} rows={len(data):6d} span={span_h/24:.1f}d "
          f"[{data[0]['ts']}..{data[-1]['ts']}]")
    time.sleep(0.3)
print("done ->", OUT)
