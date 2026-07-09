"""Runs ON the nxrates cluster (numpy venv: /tmp/nxv/bin/python). Streams a pool's
swaps (packed <q d d d>: ts_ms, amount0, amount1, liquidity) against the NXR
BTC/USDT .idx shards, marking every swap at the NXR mid (CEX truth) at its time.
The pool's value-change at the external price, summed, IS fee − arb-LVR (vs a
constant-mix rebalancer). Vectorized parse + searchsorted marking.

Args: cluster_mark.py <swaps.bin> <nxr_ticker_id> <usd_token> <d0> <d1> <fee_bps> <out.csv>
"""
import sys, math, datetime as dt
from pathlib import Path
import numpy as np

PVC = "/var/lib/local-path-provisioner/pvc-2ac9337b-5715-4676-892f-e73558ebe002_nxr_nxr-data-localpath/indexes"
EPOCH2010 = 1262304000000


def load_nxr_day(ticker_id, date):
    f = Path(PVC) / str(ticker_id) / f"{date}.idx"
    if not f.exists():
        return None, None
    a = np.frombuffer(f.read_bytes(), dtype=np.uint8)
    n = a.size // 56
    a = a[:n * 56].reshape(n, 56)
    ts8 = np.zeros((n, 8), np.uint8)
    ts8[:, :6] = a[:, 2:8]
    ts48 = ts8.view(np.uint64).ravel().astype(np.int64)
    ts_ms = EPOCH2010 + (ts48 * 16) // 1000
    bid = np.ascontiguousarray(a[:, 24:32]).view(np.float64).ravel()
    ask = np.ascontiguousarray(a[:, 32:40]).view(np.float64).ravel()
    keep = (a[:, 55] & 0x01) == 0          # drop heartbeat sentinels
    mid = (bid + ask) * 0.5
    ts_ms, mid = ts_ms[keep], mid[keep]
    order = np.argsort(ts_ms, kind="stable")
    return ts_ms[order], mid[order]


def v_active_usd(liq, btc_price, d0, d1, usd_token, w=0.05):
    if btc_price <= 0 or liq <= 0:
        return 0.0
    p_raw = (1.0 / btc_price if usd_token == 0 else btc_price) * 10 ** (d1 - d0)
    s = math.sqrt(p_raw)
    amt1 = liq * (s - s * math.sqrt(1 - w)) / 10 ** d1
    amt0 = liq * (1 / s - 1 / (s * math.sqrt(1 + w))) / 10 ** d0
    return (amt0 + amt1 * btc_price) if usd_token == 0 else (amt1 + amt0 * btc_price)


def main(swaps_path, ticker_id, usd_token, d0, d1, fee_bps, out_path):
    fee_frac = fee_bps / 1e4
    sw = np.frombuffer(Path(swaps_path).read_bytes(),
                       dtype=np.dtype([("ts", "<i8"), ("a0", "<f8"), ("a1", "<f8"), ("liq", "<f8")]))
    sw = np.sort(sw, order="ts")
    day_idx = sw["ts"] // 86400000
    rows = []
    for day in np.unique(day_idx):
        m = day_idx == day
        sts, sa0, sa1, sliq = sw["ts"][m], sw["a0"][m], sw["a1"][m], sw["liq"][m]
        date = dt.datetime.utcfromtimestamp(int(day) * 86400).strftime("%Y-%m-%d")
        nts, nmid = load_nxr_day(ticker_id, date)
        if nts is None or nts.size == 0:
            continue
        j = np.searchsorted(nts, sts, side="right") - 1
        j = np.clip(j, 0, nts.size - 1)
        price = nmid[j]                                  # NXR BTC price at each swap
        if usd_token == 0:
            e0, e1 = np.ones_like(price), price
        else:
            e0, e1 = price, np.ones_like(price)
        net = sa0 * e0 + sa1 * e1                        # value-change at external = fee−LVR
        in_usd = np.where(sa0 > 0, sa0 * e0, sa1 * e1)
        fee = in_usd * fee_frac
        mp = float(price.mean())
        vact = v_active_usd(float(sliq.mean()), mp, d0, d1, usd_token)
        rows.append((int(day) * 86400, float(net.sum()), float(fee.sum()), int(m.sum()), vact, mp))
    with open(out_path, "w") as o:
        o.write("date,net_usd,fee_usd,arb_lvr_usd,swaps,v_active_usd,btc_price\n")
        for d_, net, fee, n, vact, price in rows:
            o.write(f"{d_},{net:.2f},{fee:.2f},{fee-net:.2f},{n},{vact:.1f},{price:.2f}\n")
    print(f"DONE: {len(rows)} days, {sw.size:,} swaps → {out_path}")


if __name__ == "__main__":
    _, sp, tid, ut, d0, d1, fb, out = sys.argv
    main(sp, int(tid), int(ut), int(d0), int(d1), float(fb), out)
