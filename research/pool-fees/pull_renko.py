"""Pull full 2yr NXR renko bricks for a symbol -> compact JSONL.
Paginates: server caps ~10000 rows/req. Advance cursor by last close_ms.
Each output line: [close_ms, open, close, drift, vol_imbalance, tick_count, realized_var, bipower_var]
Usage: pull_renko.py <sym> <days_back> <out.jsonl>
"""
import sys, json, time, urllib.request
from pathlib import Path

HERE = Path(__file__).parent
NXR_KEY = (HERE / "nxr.env").read_text().split("NXR_API_KEY=")[1].strip()


def fetch(sym, frm, to):
    url = f"https://api.nxrates.com/v1/bars/{sym}/renko?from={frm}&to={to}&limit=10000"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {NXR_KEY}",
                                               "Accept": "application/json", "User-Agent": "curl/8.4.0"})
    for a in range(12):
        try:
            return json.loads(urllib.request.urlopen(req, timeout=60).read())
        except Exception as e:
            if a == 11:
                raise
            time.sleep(min(5 * (a + 1), 30))


def main(sym, days, out):
    now = int(time.time() * 1000)
    start = now - int(days) * 86400 * 1000
    cur = start
    n = 0
    last_ms = 0
    WIN = 29 * 86400 * 1000
    with open(out, "w") as f:
        while cur < now:
            to = min(cur + WIN, now)
            d = fetch(sym, cur, to)
            if not d:
                cur = to
                continue
            got = 0
            for r in d:
                cm = r["close_ms"]
                if cm <= last_ms:
                    continue
                f.write(json.dumps([cm, r["open"], r["close"], r["drift"],
                                    r["vol_imbalance"], r["tick_count"],
                                    r["realized_var"], r["bipower_var"]]) + "\n")
                last_ms = cm
                got += 1
            n += got
            # advance: if we hit the row cap, continue from last brick; else jump window
            if len(d) >= 10000:
                cur = last_ms + 1
            else:
                cur = to
            if n % 20000 < got:
                print(f"  {n:,} bricks, cur={time.strftime('%Y-%m-%d', time.gmtime(cur/1000))}", flush=True)
            time.sleep(0.8)
    print(f"DONE {sym}: {n:,} bricks -> {out}", flush=True)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
