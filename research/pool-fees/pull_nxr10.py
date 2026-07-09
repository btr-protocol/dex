"""Pull 2yr of NXR tf=10 (10-second) closes for one symbol into a compact binary
(packed little-endian <qd: ts_ms, close> per row — same layout as *.block.bin).

Purpose: block-aligned basis analysis (pool px vs CEX truth within 10s) — the 5-min
sampling was misalignment-dominated (BTC moves 10-30bps in 5min >> the 5bps fee band).
Streams straight to disk; ~6.3M rows -> ~100MB, no big in-memory JSON.

Usage: pull_nxr10.py <sym> <start_ms> <end_ms> <out.bin>
"""
import sys, json, struct, time, urllib.request
from pathlib import Path

HERE = Path(__file__).parent
NXR_KEY = (HERE / "nxr.env").read_text().split("NXR_API_KEY=")[1].strip()
WIN = 29 * 86400 * 1000  # 30d API cap per request window


def fetch(sym, frm, to):
    url = f"https://api.nxrates.com/v1/ohlc/{sym}?tf=10&from={frm}&to={to}&limit=10000"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {NXR_KEY}",
                                               "User-Agent": "curl/8.4.0", "Accept": "*/*"})
    for a in range(12):
        try:
            return json.loads(urllib.request.urlopen(req, timeout=40).read())
        except Exception:
            if a == 11:
                raise
            time.sleep(min(5 * (a + 1), 30))


def main(sym, start_ms, end_ms, out):
    n = 0
    cur = start_ms
    with open(out, "wb") as f:
        while cur < end_ms:
            to = min(cur + WIN, end_ms)
            d = fetch(sym, cur, to)
            if not d:
                cur = to
                continue
            for r in d:
                f.write(struct.pack("<qd", r["ts"], r["close"]))
            n += len(d)
            cur = d[-1]["ts"] + 10_000
            if n % 200_000 < 10_000:
                print(f"  {sym}: {n:,} bars, cur={cur}", flush=True)
            time.sleep(1.2)
    print(f"DONE {sym}: {n:,} bars -> {out}", flush=True)


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4])
