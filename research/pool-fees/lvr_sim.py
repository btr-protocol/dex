"""External-marked LVR simulation — the unambiguous hedged vs-rebal.

For each real Swap, the pool's value-change marked at the EXTERNAL (NXR) price is
`amount0·e0 + amount1·e1` (e = external price of each token; USD leg = 1, asset leg
= NXR mid at the swap time). Summed over swaps this IS `fees − LVR` directly (a
fair swap at external nets 0; the fee makes it +, adverse selection makes it −) —
the genuine deadband effect, with NO pool-price round-trip artifact. We mark at the
NXR feed (the price truth), not the pool's own oscillating price.

Per day we accumulate: net_value (fee−LVR, USD), gross fees, and V_active → annualized
net-vs-rebal, f0, and the implied real LVR = f0 − net.

Usage: lvr_sim.py <chain> <pool> <nxr_sym> <fee_bps> <usd_token> <d0> <d1> <start> <end> <out>
NXR external uses 10s OHLC close (aggregate net is resolution-robust — per-swap
marking error is mean-zero and √N-suppressed; 200ms idx available if needed).
"""
import asyncio, os, sys, json, math, bisect
import urllib.request
from pathlib import Path
import hypersync
from hypersync import HypersyncClient, ClientConfig, Query, LogSelection, FieldSelection, LogField, BlockField
import hs_pull

HERE = Path(__file__).parent
for line in (HERE / "nxr.env").read_text().splitlines():
    if line.startswith("NXR_API_KEY="):
        os.environ["NXR_API_KEY"] = line.split("=", 1)[1].strip()
NXR_KEY = os.environ["NXR_API_KEY"]
NXR_API = "https://api.nxrates.com"


def nxr_ohlc(sym, start_ms, end_ms):
    """Download NXR 10s OHLC close over [start,end], cached to disk. Returns (ts[], close[])."""
    cache = HERE / "data_raw" / f"nxr_{sym}_{start_ms}_{end_ms}.jsonl"
    if cache.exists():
        rows = [json.loads(l) for l in cache.open() if l.strip()]
    else:
        import time as _t
        rows = []
        cur = start_ms
        while cur < end_ms:
            to = min(cur + 10000 * 10000, end_ms)  # 10000-bar cap per request
            url = f"{NXR_API}/v1/ohlc/{sym}?tf=10&from={cur}&to={to}&limit=10000"
            req = urllib.request.Request(url, headers={"Accept": "application/json",
                                                       "Authorization": f"Bearer {NXR_KEY}"})
            d = None
            for attempt in range(6):
                try:
                    d = json.loads(urllib.request.urlopen(req, timeout=40).read())
                    break
                except Exception:
                    _t.sleep(5 * (attempt + 1))  # ride the ~20s burst cooldown
            if d is None:
                raise RuntimeError(f"NXR fetch failed at {cur}")
            if not d:
                cur = to
                continue
            rows.extend(d)
            cur = d[-1]["ts"] + 10000
            _t.sleep(2.0)  # conservative pace — burst protection trips fast
            if len(rows) % 200000 < 10000:
                print(f"    nxr {sym}: {len(rows)} bars, cur={cur}", flush=True)
        cache.write_text("\n".join(json.dumps(r) for r in rows))
    rows.sort(key=lambda r: r["ts"])
    ts = [r["ts"] for r in rows]
    cl = [r["close"] for r in rows]
    return ts, cl


async def run(chain, pool, nxr_sym, fee_bps, start_block, end_block, usd_token, d0, d1, out_path):
    # 1. block→ts needs a quick height/time anchor; we read ts from the swap query.
    client = HypersyncClient(ClientConfig(url=hs_pull.ENDPOINTS[chain], bearer_token=hs_pull.TOKEN,
                                          proactive_rate_limit_sleep=True))
    fee_frac = fee_bps / 1e4
    # NXR external covering the pool window (approx via block→ts at run-time; load lazily after first ts).
    nxr_ts = nxr_cl = None
    def ext(ts_ms):
        i = bisect.bisect_right(nxr_ts, ts_ms)
        return nxr_cl[i - 1] if i > 0 else nxr_cl[0]
    days = {}  # day -> [net_usd, fee_usd, swaps, sumL, sumS]
    blk = start_block
    reqs = 0
    pend_first_ts = None
    while blk < end_block:
        q = Query(from_block=blk, to_block=end_block,
                  logs=[LogSelection(address=[pool], topics=[hs_pull.SWAP_T0])],
                  field_selection=FieldSelection(block=[BlockField.NUMBER, BlockField.TIMESTAMP],
                                                 log=[LogField.BLOCK_NUMBER, LogField.DATA]))
        res = await client.get(q)
        reqs += 1
        ts_of = {b.number: int(b.timestamp, 16) for b in (res.data.blocks or [])}
        # lazy-load NXR once we know the first ts (pool start)
        if nxr_ts is None and res.data.logs:
            first_ts = ts_of.get(res.data.logs[0].block_number, 0) * 1000
            last_ts = 1782000000000
            nxr_ts, nxr_cl = nxr_ohlc(nxr_sym, first_ts - 60000, last_ts)
            print(f"  NXR {nxr_sym}: {len(nxr_ts)} bars loaded", flush=True)
        for lg in res.data.logs:
            dd = hs_pull.decode_swap_data(lg.data)
            if dd is None:
                continue
            ts = ts_of.get(lg.block_number, 0)
            ts_ms = ts * 1000
            e_asset = ext(ts_ms)
            a0 = dd["amount0"] / 10 ** d0
            a1 = dd["amount1"] / 10 ** d1
            # external prices: usd leg = 1, asset leg = NXR mid
            (e0, e1) = (1.0, e_asset) if usd_token == 0 else (e_asset, 1.0)
            net_val = a0 * e0 + a1 * e1          # pool value change at external = fee − LVR
            # gross fee = input-leg (positive amount) value × feeTier
            in_usd = (a0 * e0) if a0 > 0 else (a1 * e1)
            fee_val = in_usd * fee_frac
            day = ts // 86400
            r = days.setdefault(day, [0.0, 0.0, 0, 0.0, 0.0])
            r[0] += net_val
            r[1] += fee_val
            r[2] += 1
            r[3] += dd["liquidity"]
            r[4] += dd["sqrtPriceX96"]
        nb = res.next_block
        if nb <= blk:
            break
        blk = nb
        if reqs % 25 == 0:
            print(f"  [{pool[:10]}] req {reqs}, blk {blk:,}/{end_block:,}, days {len(days)}", flush=True)
    # emit daily
    rows = []
    for day in sorted(days):
        net, fee, n, sumL, sumS = days[day]
        meanL = sumL / n
        meanS = sumS / n
        vact = hs_pull.v_active_usd(meanL, meanS, d0, d1, usd_token)
        if vact <= 0:
            continue
        net_apr = net / vact * 365.0
        f0 = fee / vact * 365.0
        rows.append({"date": day * 86400, "net_vs_rebal_apr": net_apr, "f0_apr": f0,
                     "real_lvr_apr": f0 - net_apr, "v_active_usd": vact, "swaps": n})
    Path(out_path).write_text("\n".join(json.dumps(r) for r in rows))
    import statistics as st
    NETS = [r["net_vs_rebal_apr"] for r in rows]
    F0 = [r["f0_apr"] for r in rows]
    LV = [r["real_lvr_apr"] for r in rows]
    print(f"\n===== {pool} ({len(rows)} days) EXTERNAL-MARKED (NXR {nxr_sym}) =====")
    print(f"  f0:           mean {st.mean(F0):.2f}  median {st.median(F0):.2f}")
    print(f"  real LVR:     mean {st.mean(LV):.2f}  median {st.median(LV):.2f}")
    print(f"  NET vs-rebal: mean {st.mean(NETS)*100:+.1f}%  median {st.median(NETS)*100:+.1f}%  "
          f"({'DEPLOYABLE' if st.mean(NETS)>0 else 'LOSES'})")


if __name__ == "__main__":
    _, chain, pool, nxr_sym, fee_bps, ut, d0, d1, sb, eb, out = sys.argv
    asyncio.run(run(chain, pool, nxr_sym, float(fee_bps), int(sb), int(eb), int(ut), int(d0), int(d1), out))
