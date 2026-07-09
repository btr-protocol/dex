"""Pull every v3 Swap for a pool → compact binary (ts_ms, amount0, amount1, liquidity)
for the external-marked arb-LVR sim. Amounts are decimal-scaled (token units); the
cluster marker applies the NXR external price per token. Output: packed '<q d d d'
records (ts_ms i64, a0 f64, a1 f64, liq f64) — 32 B/swap.

Usage: pull_swaps.py <chain> <pool> <d0> <d1> <start_block> <end_block> <out.bin>
"""
import asyncio, sys, struct
from pathlib import Path
from hypersync import HypersyncClient, ClientConfig, Query, LogSelection, FieldSelection, LogField, BlockField
import hs_pull

# Aerodrome Slipstream Swap has the SAME 7-field layout + topic as Uni-v3 (it's a
# v3 fork) — covered by the uni topic0 in hs_pull.SWAP_T0. Velodrome/Aero use the
# same event signature for the CL "Slipstream" pools.


async def run(chain, pool, d0, d1, start_block, end_block, out_path):
    client = HypersyncClient(ClientConfig(url=hs_pull.ENDPOINTS[chain], bearer_token=hs_pull.TOKEN,
                                          proactive_rate_limit_sleep=True))
    f = open(out_path, "wb")
    blk = start_block
    reqs = n = 0
    while blk < end_block:
        q = Query(from_block=blk, to_block=end_block,
                  logs=[LogSelection(address=[pool], topics=[hs_pull.SWAP_T0])],
                  field_selection=FieldSelection(block=[BlockField.NUMBER, BlockField.TIMESTAMP],
                                                 log=[LogField.BLOCK_NUMBER, LogField.DATA]))
        res = await client.get(q)
        reqs += 1
        ts_of = {b.number: int(b.timestamp, 16) for b in (res.data.blocks or [])}
        buf = bytearray()
        for lg in res.data.logs:
            dd = hs_pull.decode_swap_data(lg.data)
            if dd is None:
                continue
            ts_ms = ts_of.get(lg.block_number, 0) * 1000
            a0 = dd["amount0"] / 10 ** d0
            a1 = dd["amount1"] / 10 ** d1
            liq = float(dd["liquidity"])
            buf += struct.pack("<qddd", ts_ms, a0, a1, liq)
            n += 1
        f.write(buf)
        nb = res.next_block
        if nb <= blk:
            break
        blk = nb
        if reqs % 50 == 0:
            print(f"  [{pool[:10]}] req {reqs}, blk {blk:,}/{end_block:,}, swaps {n:,}", flush=True)
    f.close()
    print(f"DONE {pool}: {n:,} swaps → {out_path} ({Path(out_path).stat().st_size/1e6:.0f} MB)")


if __name__ == "__main__":
    _, chain, pool, d0, d1, sb, eb, out = sys.argv
    asyncio.run(run(chain, pool, int(d0), int(d1), int(sb), int(eb), out))
