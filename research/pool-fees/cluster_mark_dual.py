"""DUAL-VOLATILE-LEG marker. Runs ON the nxrates cluster (numpy venv:
/tmp/nxv/bin/python). Streams a pool's swaps (packed <q d d d>: ts_ms,
amount0, amount1, liquidity) against TWO NXR USD .idx series (one per leg).

For a BTC/ETH (or cbBTC/WETH, WBTC/WETH) pool BOTH legs are volatile, so we
mark each at its NXR USD price at the swap time:
    net_i = amount0 * P_token0_usd(t_i) + amount1 * P_token1_usd(t_i)
summed over real swaps = fee - arb-LVR vs a constant-mix rebalancer, at CEX
truth. fee_i = feeTier * |USD value of the INPUT leg| (the leg flowing INTO
the pool, i.e. the positive amount). The constant-mix carry is captured by the
dual USD marking exactly as the single-leg version captured it with one $1 leg.

amount0/amount1 in the .bin are already decimal-scaled to TOKEN units
(pull_swaps.py divided by 10**d), so we just multiply by USD price per token.

Args: cluster_mark_dual.py <swaps.bin> <tid0> <tid1> <d0> <d1> <fee_bps> <out.csv>
  tid0 = NXR ticker_id giving token0's USD price (e.g. ETHUSDT id for WETH leg)
  tid1 = NXR ticker_id giving token1's USD price (e.g. BTCUSDT id for cbBTC leg)
  d0/d1 = token decimals (informational; amounts already scaled). Used for V_active.
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


def v_active_usd_dual(liq, p0_usd, p1_usd, d0, d1, w=0.05):
    """USD value of `liq` spread over +/-w around the current price, both legs
    marked at their USD price. v3 pool price P = token1/token0 (raw units):
    P_raw = (p0_usd / p1_usd) * 10**(d1-d0). Amounts of each token held over the
    +/-w band, valued at their respective USD prices."""
    if liq <= 0 or p0_usd <= 0 or p1_usd <= 0:
        return 0.0
    p_raw = (p0_usd / p1_usd) * 10 ** (d1 - d0)   # token1 per token0, raw
    s = math.sqrt(p_raw)
    amt1 = liq * (s - s * math.sqrt(1 - w)) / 10 ** d1   # token1 units
    amt0 = liq * (1 / s - 1 / (s * math.sqrt(1 + w))) / 10 ** d0   # token0 units
    return amt0 * p0_usd + amt1 * p1_usd


def main(swaps_path, tid0, tid1, d0, d1, fee_bps, out_path):
    fee_frac = fee_bps / 1e4
    sw = np.frombuffer(Path(swaps_path).read_bytes(),
                       dtype=np.dtype([("ts", "<i8"), ("a0", "<f8"), ("a1", "<f8"), ("liq", "<f8")]))
    sw = np.sort(sw, order="ts")
    day_idx = sw["ts"] // 86400000
    rows = []
    skipped = 0
    for day in np.unique(day_idx):
        m = day_idx == day
        sts, sa0, sa1, sliq = sw["ts"][m], sw["a0"][m], sw["a1"][m], sw["liq"][m]
        date = dt.datetime.utcfromtimestamp(int(day) * 86400).strftime("%Y-%m-%d")
        nts0, nmid0 = load_nxr_day(tid0, date)
        nts1, nmid1 = load_nxr_day(tid1, date)
        if nts0 is None or nts0.size == 0 or nts1 is None or nts1.size == 0:
            skipped += int(m.sum())
            continue
        j0 = np.clip(np.searchsorted(nts0, sts, side="right") - 1, 0, nts0.size - 1)
        j1 = np.clip(np.searchsorted(nts1, sts, side="right") - 1, 0, nts1.size - 1)
        p0 = nmid0[j0]                     # token0 USD price at each swap
        p1 = nmid1[j1]                     # token1 USD price at each swap
        # value-change at external (both legs at CEX USD) = fee - arb-LVR
        net = sa0 * p0 + sa1 * p1
        # fee = feeTier * |USD value of the INPUT leg| (positive amount = into pool)
        in_usd = np.where(sa0 > 0, sa0 * p0, np.where(sa1 > 0, sa1 * p1, 0.0))
        fee = in_usd * fee_frac
        mp0, mp1 = float(p0.mean()), float(p1.mean())
        vact = v_active_usd_dual(float(sliq.mean()), mp0, mp1, d0, d1)
        rows.append((int(day) * 86400, float(net.sum()), float(fee.sum()),
                     int(m.sum()), vact, mp0, mp1))
    with open(out_path, "w") as o:
        o.write("date,net_usd,fee_usd,arb_lvr_usd,swaps,v_active_usd,p0_usd,p1_usd\n")
        for d_, net, fee, n, vact, mp0, mp1 in rows:
            o.write(f"{d_},{net:.2f},{fee:.2f},{fee-net:.2f},{n},{vact:.1f},{mp0:.4f},{mp1:.4f}\n")
    print(f"DONE: {len(rows)} days, {sw.size:,} swaps ({skipped:,} skipped no-NXR-day) -> {out_path}")


if __name__ == "__main__":
    _, sp, t0, t1, d0, d1, fb, out = sys.argv
    main(sp, int(t0), int(t1), int(d0), int(d1), float(fb), out)
