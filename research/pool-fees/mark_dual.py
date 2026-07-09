"""Dual-volatile-leg vs-rebal marker (NXR-API, autonomous — no cluster PVC).

Marks each swap of a vol/vol pool (WBTC/WETH, BTCB/WBNB, ETH/BTCB, …) at BOTH
legs' NXR USD prices:
    net_i = a0·P0_usd(t_i) + a1·P1_usd(t_i)      Σ = fee − arb-LVR vs const-mix rebal
    fee_i = feeTier · |USD value of the INPUT (positive-amount) leg|
net/fee% = 1 − LVR/fee → POSITIVE means the vol/vol pool BEATS a 50/50 rebalancer
at CEX truth. Resolution-robust (per-swap mark error mean-zero, √N-suppressed in the
daily aggregate). Mirrors cluster_mark_dual.py but reads NXR via the OHLC API.

Usage: mark_dual.py <chain> <pool> <sym0> <sym1> <fee_bps> <d0> <d1> <start_block> <end_block> <out.jsonl>
  sym0/sym1 = NXR symbols for token0/token1 USD price (e.g. BTC-USDT, BNB-USDT)
"""
import asyncio, os, sys, bisect, json, urllib.request, time as _t
from pathlib import Path
from hypersync import HypersyncClient, ClientConfig, Query, LogSelection, FieldSelection, LogField, BlockField
import hs_pull

HERE = Path(__file__).parent
NXR_KEY = (HERE / "nxr.env").read_text().split("NXR_API_KEY=")[1].strip()


def nxr_px(sym, start_ms, end_ms):
    """NXR 1-min close USD price over [start,end], cached, WAF-safe UA."""
    # tf=300 (5-min): plenty for daily net/fee (per-swap mark error is mean-zero,
    # √N-suppressed in the daily aggregate) and 5× fewer requests than 1-min over 2yr.
    # Cache keyed by sym only (full-history reuse across pools sharing a leg).
    cache = HERE / "data_raw" / f"nxrpx5_{sym}.jsonl"
    if cache.exists():
        rows = [json.loads(l) for l in cache.open() if l.strip()]
    else:
        rows, cur, WIN, STEP = [], start_ms, 29 * 86400 * 1000, 300000
        while cur < end_ms:
            to = min(cur + WIN, end_ms)
            url = f"https://api.nxrates.com/v1/ohlc/{sym}?tf=300&from={cur}&to={to}&limit=10000"
            req = urllib.request.Request(url, headers={"Authorization": f"Bearer {NXR_KEY}",
                                                       "User-Agent": "curl/8.4.0", "Accept": "*/*"})
            d = None
            for a in range(12):  # resilient to transient DNS/network blips
                try:
                    d = json.loads(urllib.request.urlopen(req, timeout=40).read()); break
                except Exception:
                    if a == 11:
                        raise
                    _t.sleep(min(5 * (a + 1), 30))
            if d:
                rows.extend(d)
                cur = d[-1]["ts"] + STEP  # advance to LAST fetched bar (contiguous)
            else:
                cur = to
            _t.sleep(1.0)
        cache.write_text("\n".join(json.dumps(r) for r in rows))
    rows.sort(key=lambda r: r["ts"])
    return [r["ts"] for r in rows], [r["close"] for r in rows]


async def get_retry(client, q, tries=8):
    """HyperSync get() with retry — BSC/arb endpoints intermittently time out on
    long pulls; a died get() loses the tail. Retry with backoff so 2yr pulls finish."""
    for k in range(tries):
        try:
            return await client.get(q)
        except Exception:
            if k == tries - 1:
                raise
            await asyncio.sleep(5 * (k + 1))


async def run(chain, pool, sym0, sym1, fee_bps, d0, d1, sb, eb, out):
    client = HypersyncClient(ClientConfig(url=hs_pull.ENDPOINTS[chain], bearer_token=hs_pull.TOKEN,
                                          proactive_rate_limit_sleep=True))
    fee_frac = fee_bps / 1e4
    nts0 = ncl0 = nts1 = ncl1 = None
    def ext(ts, nts, ncl):
        i = bisect.bisect_right(nts, ts)
        return ncl[i - 1] if i > 0 else ncl[0]
    days = {}
    blk, reqs = sb, 0
    while blk < eb:
        q = Query(from_block=blk, to_block=eb,
                  logs=[LogSelection(address=[pool], topics=[hs_pull.SWAP_T0])],
                  field_selection=FieldSelection(block=[BlockField.NUMBER, BlockField.TIMESTAMP],
                                                 log=[LogField.BLOCK_NUMBER, LogField.DATA]))
        res = await get_retry(client, q)
        reqs += 1
        ts_of = {b.number: int(b.timestamp, 16) for b in (res.data.blocks or [])}
        if nts0 is None and res.data.logs:
            f0 = ts_of.get(res.data.logs[0].block_number, 0) * 1000
            nts0, ncl0 = nxr_px(sym0, f0 - 60000, 1783000000000)
            nts1, ncl1 = nxr_px(sym1, f0 - 60000, 1783000000000)
            print(f"  NXR {sym0}:{len(nts0)} bars  {sym1}:{len(nts1)} bars", flush=True)
        for lg in res.data.logs:
            dd = hs_pull.decode_swap_data(lg.data)
            if dd is None:
                continue
            ts = ts_of.get(lg.block_number, 0)
            tsm = ts * 1000
            # Skip swaps before NXR price coverage (can't mark without CEX truth);
            # lets us start the pull from the pool's first liquid block safely.
            if tsm < nts0[0] or tsm < nts1[0]:
                continue
            a0 = dd["amount0"] / 10 ** d0
            a1 = dd["amount1"] / 10 ** d1
            e0 = ext(tsm, nts0, ncl0)
            e1 = ext(tsm, nts1, ncl1)
            net = a0 * e0 + a1 * e1
            in_usd = abs(a0 * e0) if a0 > 0 else abs(a1 * e1)
            fee = in_usd * fee_frac
            day = ts // 86400
            r = days.setdefault(day, [0.0, 0.0, 0])
            r[0] += net
            r[1] += fee
            r[2] += 1
        nb = res.next_block
        if nb <= blk:
            break
        blk = nb
        if reqs % 25 == 0:
            print(f"  req {reqs} blk {blk:,}/{eb:,} days {len(days)}", flush=True)
    rows = [{"date": d * 86400, "net_usd": v[0], "fee_usd": v[1], "swaps": v[2]}
            for d, v in sorted(days.items())]
    Path(out).write_text("\n".join(json.dumps(r) for r in rows))
    sn = sum(r["net_usd"] for r in rows)
    sf = sum(r["fee_usd"] for r in rows)
    print(f"\n===== {pool} ({len(rows)} days) DUAL-MARKED ({sym0}/{sym1}) =====")
    print(f"  Σnet ${sn:,.0f}  Σfee ${sf:,.0f}  Σarb_lvr ${sf - sn:,.0f}")
    verdict = "BEATS rebal ✓" if sn > 0 else "LOSES vs rebal ✗"
    print(f"  >>> net/fee = {sn / sf * 100 if sf else 0:+.1f}%   ({verdict})")


if __name__ == "__main__":
    _, chain, pool, sym0, sym1, fee_bps, d0, d1, sb, eb, out = sys.argv
    asyncio.run(run(chain, pool, sym0, sym1, float(fee_bps), int(d0), int(d1), int(sb), int(eb), out))
