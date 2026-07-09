"""Decisive headroom test for a SUB-DAILY neutral gate (operator's "out of market,
fast prices" lever). Marks each ETH WBTC/USDT swap at the external NXR BTC price
(10s OHLC) → net_val = fee - arb_LVR per swap (resolution-robust external mark,
identical method to lvr_sim). Buckets BOTH hourly and daily, then computes the
ORACLE (perfect-foresight) gate at each granularity:

  oracle_gate_net = Σ over buckets of max(0, net_bucket)   (exit every losing bucket)

The ratio hourly_oracle / daily_oracle is the CEILING headroom from finer gating.
If ≈1, daily averaging already captured the structure ⇒ convexity lever is dead.
If ≫1, intraday σ² spikes are exitable ⇒ worth a causal+cost analysis.

Usage: hourly_gate_test.py <chain> <pool> <nxr_sym> <fee_bps> <usd_token> <d0> <d1> <start_block> <end_block>
"""
import asyncio, os, sys, bisect, statistics as st
from pathlib import Path
from hypersync import HypersyncClient, ClientConfig, Query, LogSelection, FieldSelection, LogField, BlockField
import urllib.request, json, time as _t, os
import hs_pull

HERE = Path(__file__).parent
for line in (HERE / "nxr.env").read_text().splitlines():
    if line.startswith("NXR_API_KEY="):
        os.environ["NXR_API_KEY"] = line.split("=", 1)[1].strip()
NXR_KEY = os.environ["NXR_API_KEY"]


def nxr_ohlc60(sym, start_ms, end_ms):
    """NXR 1-min OHLC close over [start,end], cached. Robust to burst-403 (long backoff)."""
    cache = HERE / "data_raw" / f"nxr60_{sym}_{start_ms}_{end_ms}.jsonl"
    if cache.exists():
        rows = [json.loads(l) for l in cache.open() if l.strip()]
    else:
        rows, cur = [], start_ms
        while cur < end_ms:
            to = min(cur + 60000 * 10000, end_ms)
            url = f"https://api.nxrates.com/v1/ohlc/{sym}?tf=60&from={cur}&to={to}&limit=10000"
            req = urllib.request.Request(url, headers={"Authorization": f"Bearer {NXR_KEY}",
                                                       "User-Agent": "curl/8.4.0", "Accept": "*/*"})
            d = None
            for attempt in range(8):
                try:
                    d = json.loads(urllib.request.urlopen(req, timeout=40).read()); break
                except Exception:
                    _t.sleep(8 * (attempt + 1))  # burst cooldown can be long
            if d is None:
                raise RuntimeError(f"NXR fetch failed at {cur}")
            if not d:
                cur = to; continue
            rows.extend(d); cur = d[-1]["ts"] + 60000; _t.sleep(2.5)
        cache.write_text("\n".join(json.dumps(r) for r in rows))
    rows.sort(key=lambda r: r["ts"])
    return [r["ts"] for r in rows], [r["close"] for r in rows]


async def run(chain, pool, nxr_sym, fee_bps, usd_token, d0, d1, start_block, end_block):
    client = HypersyncClient(ClientConfig(url=hs_pull.ENDPOINTS[chain], bearer_token=hs_pull.TOKEN,
                                          proactive_rate_limit_sleep=True))
    fee_frac = fee_bps / 1e4
    nxr_ts = nxr_cl = None
    def ext(ts_ms):
        i = bisect.bisect_right(nxr_ts, ts_ms)
        return nxr_cl[i - 1] if i > 0 else nxr_cl[0]
    hourly = {}   # hour -> net
    daily = {}    # day  -> net
    hr_fee = {}   # hour -> fee
    blk = start_block
    reqs = 0
    while blk < end_block:
        q = Query(from_block=blk, to_block=end_block,
                  logs=[LogSelection(address=[pool], topics=[hs_pull.SWAP_T0])],
                  field_selection=FieldSelection(block=[BlockField.NUMBER, BlockField.TIMESTAMP],
                                                 log=[LogField.BLOCK_NUMBER, LogField.DATA]))
        res = await client.get(q)
        reqs += 1
        ts_of = {b.number: int(b.timestamp, 16) for b in (res.data.blocks or [])}
        if nxr_ts is None and res.data.logs:
            first_ts = ts_of.get(res.data.logs[0].block_number, 0) * 1000
            nxr_ts, nxr_cl = nxr_ohlc60(nxr_sym, first_ts - 60000, 1782000000000)
            print(f"  NXR {nxr_sym}: {len(nxr_ts)} bars", flush=True)
        for lg in res.data.logs:
            dd = hs_pull.decode_swap_data(lg.data)
            if dd is None:
                continue
            ts = ts_of.get(lg.block_number, 0)
            e_asset = ext(ts * 1000)
            a0 = dd["amount0"] / 10 ** d0
            a1 = dd["amount1"] / 10 ** d1
            (e0, e1) = (1.0, e_asset) if usd_token == 0 else (e_asset, 1.0)
            net_val = a0 * e0 + a1 * e1            # fee - LVR at external price
            in_usd = (a0 * e0) if a0 > 0 else (a1 * e1)
            fee_val = in_usd * fee_frac
            hour = ts // 3600
            day = ts // 86400
            hourly[hour] = hourly.get(hour, 0.0) + net_val
            daily[day] = daily.get(day, 0.0) + net_val
            hr_fee[hour] = hr_fee.get(hour, 0.0) + fee_val
        nb = res.next_block
        if nb <= blk:
            break
        blk = nb
        if reqs % 25 == 0:
            print(f"  req {reqs}, blk {blk:,}/{end_block:,}, hours {len(hourly)}", flush=True)

    H = list(hourly.values())
    D = list(daily.values())
    uncond = sum(H)
    hourly_oracle = sum(v for v in H if v > 0)
    daily_oracle = sum(v for v in D if v > 0)
    fee_tot = sum(hr_fee.values())
    fee_in_losing_hrs = sum(hr_fee[h] for h, v in hourly.items() if v <= 0)
    print(f"\n===== {pool} hourly-vs-daily ORACLE gate headroom =====")
    print(f"  buckets: {len(H)} hours / {len(D)} days")
    print(f"  UNCONDITIONAL net (always-on):     ${uncond:,.0f}")
    print(f"  DAILY-oracle gate net (exit neg days):  ${daily_oracle:,.0f}")
    print(f"  HOURLY-oracle gate net (exit neg hrs):  ${hourly_oracle:,.0f}")
    print(f"  >>> HEADROOM ratio hourly/daily = {hourly_oracle/daily_oracle if daily_oracle else float('nan'):.2f}x")
    print(f"  losing hours hold {fee_in_losing_hrs/fee_tot*100:.0f}% of all fees (FORGONE if exited)")

    # ── CAUSAL test: is the hourly sign forecastable, or is the oracle just cherry-picking noise? ──
    # NXR realized vol per hour = std of 1-min log returns within the hour.
    import math
    vol_by_hr = {}
    cur_hr, closes = None, []
    for ts, cl in zip(nxr_ts, nxr_cl):
        hr = (ts // 1000) // 3600
        if hr != cur_hr:
            if len(closes) > 2:
                rets = [math.log(closes[i]/closes[i-1]) for i in range(1, len(closes)) if closes[i-1] > 0]
                if rets:
                    vol_by_hr[cur_hr] = (sum(r*r for r in rets)/len(rets)) ** 0.5
            cur_hr, closes = hr, [cl]
        else:
            closes.append(cl)
    hrs = sorted(hourly)
    net_s = [hourly[h] for h in hrs]
    vol_s = [vol_by_hr.get(h, 0.0) for h in hrs]
    # write per-hour series for offline causal modelling
    with open(HERE / "data_raw" / "eth_wbtc_hourly.jsonl", "w") as f:
        for h in hrs:
            f.write(json.dumps({"hour": h, "net": hourly[h], "fee": hr_fee.get(h, 0.0),
                                "vol": vol_by_hr.get(h, 0.0)}) + "\n")
    def acf(x, lag):
        n = len(x); m = sum(x)/n; v = sum((xi-m)**2 for xi in x)/n
        if v == 0: return 0.0
        return sum((x[i]-m)*(x[i-lag]-m) for i in range(lag, n))/((n-lag)*v)
    print(f"\n  CAUSAL diagnostics ({len(hrs)} active hours):")
    print(f"    hourly-net autocorr lag1={acf(net_s,1):+.3f} lag2={acf(net_s,2):+.3f} lag6={acf(net_s,6):+.3f}")
    # corr(net_h, trailing vol_{h-1})  — does prior-hour vol predict a losing hour?
    if len(hrs) > 10:
        nv = [(net_s[i], vol_s[i-1]) for i in range(1, len(hrs))]
        mn = sum(a for a,_ in nv)/len(nv); mv = sum(b for _,b in nv)/len(nv)
        cov = sum((a-mn)*(b-mv) for a,b in nv)/len(nv)
        sn = (sum((a-mn)**2 for a,_ in nv)/len(nv))**0.5; sv = (sum((b-mv)**2 for _,b in nv)/len(nv))**0.5
        print(f"    corr(net_h, vol_(h-1)) = {cov/(sn*sv) if sn*sv else 0:+.3f}  (negative ⇒ high prior-vol → losing hour ⇒ gateable)")
    # simple CAUSAL gate: out when trailing-EWMA vol above its running median; count transitions (cost driver)
    ewma, alpha, gated_net, deployed, trans, prev_state = 0.0, 0.3, 0.0, 0, 0, True
    vhist = []
    for i, h in enumerate(hrs):
        v = vol_s[i]; ewma = alpha*v + (1-alpha)*ewma if i else v; vhist.append(ewma)
        thr = sorted(vhist)[len(vhist)//2] if len(vhist) > 5 else 0.0
        state = ewma <= thr  # True = deploy (low-vol), False = out
        if i and state != prev_state: trans += 1
        prev_state = state
        if state: gated_net += hourly[h]; deployed += 1
    print(f"    CAUSAL vol-gate (EWMA>median→out): net ${gated_net:,.0f} vs always-on ${uncond:,.0f} "
          f"({(gated_net-uncond)/abs(uncond)*100 if uncond else 0:+.0f}%), deployed {deployed}/{len(hrs)} hrs, {trans} transitions")
    print(f"    ⇒ {trans} switches × ~5bps inventory-swap cost = {trans*5} bps drag (vs the $ uplift above)")


if __name__ == "__main__":
    _, chain, pool, nxr_sym, fee_bps, ut, d0, d1, sb, eb = sys.argv
    asyncio.run(run(chain, pool, nxr_sym, float(fee_bps), int(ut), int(d0), int(d1), int(sb), int(eb)))
