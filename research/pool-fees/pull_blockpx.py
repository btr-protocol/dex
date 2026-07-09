"""Per-block pool price for the C1 pool-vs-NXR slippage overlay.

Paginate v3 Swaps for a pool over [start_ms,end_ms], decode sqrtPriceX96, and emit
the *per-block* mean pool price (USDT/USDC per base token, oriented to match the NXR
kline scale). Two outputs:
  <prefix>.block.bin   packed '<qd' (ts_ms i64, pool_px f64) — one row per block w/ swaps
                       (deep-zoom "1 block" granularity the operator asked for).
  <prefix>.bar.json    30-min-bucket mean pool price aligned to the ALM trace grid
                       {"bars":[[ts_ms, pool_px, n_swaps], ...]} for the overlay.

Price orientation: v3 sqrtP gives token1/token0 (human, decimal-adjusted). We auto-flip
to whichever orientation lands in [1e-9, 1e12] near the NXR scale of a BTC/ETH pair, so
the series overlays the NXR USDT-per-base price directly.

Usage: pull_blockpx.py <chain> <pool> <d0> <d1> <start_ms> <end_ms> <out_prefix> [blocktime_s]
"""
import asyncio, sys, struct, json
from pathlib import Path
from hypersync import HypersyncClient, ClientConfig, Query, LogSelection, FieldSelection, LogField, BlockField
import hs_pull

BUCKET_MS = 1_800_000  # 30-min, matches the ALM trace grid
BLOCKTIME = {"bsc": 3.0, "base": 2.0, "eth": 12.1}


def px_from_sqrt(sqrtp, d0, d1):
    """token1 per token0 (human). 0 if degenerate."""
    s = sqrtp / 2 ** 96
    if s <= 0:
        return 0.0
    return s * s * 10 ** (d0 - d1)


async def _ts_at(client, b):
    """Timestamp (s) of block b, or None. include_all_blocks → returned even w/o logs."""
    q = Query(from_block=b, to_block=b + 1, include_all_blocks=True,
              field_selection=FieldSelection(block=[BlockField.NUMBER, BlockField.TIMESTAMP]))
    res = await client.get(q)
    for blk in (res.data.blocks or []):
        if blk.number == b:
            return int(blk.timestamp, 16)
    return None


async def block_at_ts(client, target_s, lo, hi):
    """Binary-search the first block with ts >= target_s in [lo,hi]. Chain-agnostic →
    immune to per-chain / forked block-time drift (e.g. BSC Maxwell 3s→0.75s)."""
    while lo < hi:
        mid = (lo + hi) // 2
        ts = await _ts_at(client, mid)
        if ts is None:                       # gap → probe upward
            ts = await _ts_at(client, min(mid + 1, hi))
        if ts is None or ts < target_s:
            lo = mid + 1
        else:
            hi = mid
    return lo


async def run(chain, pool, d0, d1, start_ms, end_ms, prefix, blocktime):
    client = HypersyncClient(ClientConfig(url=hs_pull.ENDPOINTS[chain], bearer_token=hs_pull.TOKEN,
                                          proactive_rate_limit_sleep=True))
    height = await client.get_height()
    start_block = await block_at_ts(client, start_ms // 1000, 0, height)
    end_block = await block_at_ts(client, end_ms // 1000, start_block, height)
    print(f"[{chain} {pool[:10]}] head={height:,} start_blk={start_block:,} end_blk={end_block:,}", flush=True)

    # orientation: decide once from the first valid swap
    flip = None
    blk_px = {}          # block -> [sum_px, n]
    bars = {}            # bucket_ms -> [sum_px, n]
    fbin = open(prefix + ".block.bin", "wb")
    blk = start_block
    reqs = n = 0
    last_block_flushed = -1
    while blk < end_block:
        q = Query(from_block=blk, to_block=end_block + 1,
                  logs=[LogSelection(address=[pool], topics=[hs_pull.SWAP_T0])],
                  field_selection=FieldSelection(
                      block=[BlockField.NUMBER, BlockField.TIMESTAMP],
                      log=[LogField.BLOCK_NUMBER, LogField.LOG_INDEX, LogField.DATA]))
        res = await client.get(q)
        reqs += 1
        ts_of = {b.number: int(b.timestamp, 16) for b in (res.data.blocks or [])}
        stop = False
        buf = bytearray()
        for lg in res.data.logs:
            dd = hs_pull.decode_swap_data(lg.data)
            if dd is None:
                continue
            ts = ts_of.get(lg.block_number, 0)
            ts_ms = ts * 1000
            if ts_ms < start_ms:
                continue
            if ts_ms > end_ms:
                stop = True
                break
            p = px_from_sqrt(dd["sqrtPriceX96"], d0, d1)
            if p <= 0:
                continue
            if flip is None:
                flip = p < 1.0  # BTC/ETH USD pairs are >> 1; if <1, token0 is the stable → invert
            px = (1.0 / p) if flip else p
            n += 1
            bk = lg.block_number
            li = lg.log_index or 0
            # block-CLOSING price = swap with the highest log_index (the committed
            # post-state); arithmetic mean of intra-block prints is sandwich-MEV-biased.
            cur = blk_px.get(bk)
            if cur is None or li >= cur[0]:
                blk_px[bk] = [li, px, ts_ms]
        # flush completed per-block rows (all blocks < pagination cursor are final), ts-ordered
        nb = res.next_block
        done = sorted((b for b in blk_px if b < nb and b > last_block_flushed))
        for bk in done:
            _li, px, tms = blk_px[bk]
            buf += struct.pack("<qd", tms, px)
            bu = (tms // BUCKET_MS) * BUCKET_MS
            rb = bars.get(bu)
            if rb is None or tms >= rb[1]:        # bucket close = latest block in bucket
                bars[bu] = [px, tms, (rb[2] + 1 if rb else 1)]
            else:
                rb[2] += 1
        if done:
            last_block_flushed = done[-1]
        for bk in [b for b in blk_px if b < nb]:  # drop flushed → bounded memory
            del blk_px[bk]
        fbin.write(buf)
        if stop or nb <= blk:
            break
        blk = nb
        if reqs % 25 == 0:
            print(f"  req {reqs}, blk {blk:,}/{height:,}, swaps {n:,}, bars {len(bars)}", flush=True)
    fbin.close()
    bar_rows = [[bu, close, nbk] for bu, (close, _ts, nbk) in sorted(bars.items())]
    Path(prefix + ".bar.json").write_text(json.dumps({"bucket_ms": BUCKET_MS, "bars": bar_rows}))
    pxs = [r[1] for r in bar_rows]
    rng = (min(pxs), max(pxs)) if pxs else (0, 0)
    print(f"DONE {pool}: {n:,} swaps, {reqs} reqs, {len(bar_rows)} bars, flip={flip}, "
          f"px∈[{rng[0]:.2f},{rng[1]:.2f}] → {prefix}.bar.json + .block.bin "
          f"({Path(prefix+'.block.bin').stat().st_size/1e6:.1f} MB)", flush=True)


if __name__ == "__main__":
    a = sys.argv
    chain, pool, d0, d1, sms, ems, prefix = a[1], a[2], int(a[3]), int(a[4]), int(a[5]), int(a[6]), a[7]
    bt = float(a[8]) if len(a) > 8 else BLOCKTIME.get(chain, 3.0)
    asyncio.run(run(chain, pool, d0, d1, sms, ems, prefix, bt))
