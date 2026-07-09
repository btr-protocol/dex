"""Pull every v3 Mint + Burn (and a light Swap tick/liquidity stream) for a pool
→ compact binaries, for EXACT tick-liquidity reconstruction of V_active.

Mint(address sender, address indexed owner, int24 indexed tickLower,
     int24 indexed tickUpper, uint128 amount, uint256 amount0, uint256 amount1)
  topics[2]=tickLower, topics[3]=tickUpper; data words = [sender, amount, amt0, amt1]
  → amount is data word #1 (0-indexed). Adds liquidity: net[lower]+=amount, net[upper]-=amount.
Burn(address indexed owner, int24 indexed tickLower, int24 indexed tickUpper,
     uint128 amount, uint256 amount0, uint256 amount1)
  topics[1]=owner, topics[2]=tickLower, topics[3]=tickUpper; data = [amount, amt0, amt1]
  → amount is data word #0. Removes: net[lower]-=amount, net[upper]+=amount.

`amount` is uint128 (always ≥0). SIGN lives in the Mint/Burn distinction + the
lower/upper placement, NOT in the field. We emit a SIGNED net-delta per tick edge
so the reconstructor just sums.

Outputs (both little-endian packed; liquidity kept as EXACT u128 = 16 raw bytes LE,
since BSC 18/18-dec pools have L ~1e23 >> f64's 2^53 exact-int range → f64 would
lose ~7 digits and break the prefix-sum cancellation; ints are exact):
  <pool>_lp.bin   : records '<q i i 16s b' = (ts_ms i64, tickLower i32, tickUpper i32,
                    liq_amount u128-LE, is_mint i8) — 37 B/record. One per Mint/Burn.
  <pool>_swtick.bin: records '<q i 16s' = (ts_ms i64, tick i32, liquidity u128-LE) — 28 B.
                    Light Swap stream for the L-reconciliation ground-truth.

Usage: pull_mintburn.py <chain> <pool> <start_block> <end_block> <out_prefix>
"""
import asyncio, sys, struct
from pathlib import Path
from hypersync import (HypersyncClient, ClientConfig, Query, LogSelection,
                       FieldSelection, LogField, BlockField)
import hs_pull

MINT_T0 = "0x7a53080ba414158be7ec69b987b5fb7d07dee101fe85488f0853ae16239d0bde"
BURN_T0 = "0x0c396cd989a39f4459b5fa1aed6a9a8dcdbc45908acfd67e028cd568da98982c"


def s24(htopic: str) -> int:
    """int24 from a 32-byte (sign-extended) topic hex."""
    v = int(htopic, 16)
    return v - (1 << 256) if v >= (1 << 255) else v


async def pull_lp(client, pool, start_block, end_block, out_path):
    """Mint+Burn → <q i i d b. Query both topics in one selection."""
    f = open(out_path, "wb")
    blk, reqs, n = start_block, 0, 0
    while blk < end_block:
        q = Query(from_block=blk, to_block=end_block,
                  logs=[LogSelection(address=[pool], topics=[[MINT_T0, BURN_T0]])],
                  field_selection=FieldSelection(
                      block=[BlockField.NUMBER, BlockField.TIMESTAMP],
                      log=[LogField.BLOCK_NUMBER, LogField.DATA, LogField.TOPIC0,
                           LogField.TOPIC2, LogField.TOPIC3]))
        res = await client.get(q)
        reqs += 1
        ts_of = {b.number: int(b.timestamp, 16) for b in (res.data.blocks or [])}
        buf = bytearray()
        for lg in res.data.logs:
            t0 = lg.topics[0].lower()
            is_mint = 1 if t0 == MINT_T0 else 0
            tl = s24(lg.topics[2])
            tu = s24(lg.topics[3])
            data = lg.data[2:] if lg.data.startswith("0x") else lg.data
            amt_word = 1 if is_mint else 0          # Mint: amount is 2nd word; Burn: 1st
            amt = int(data[amt_word * 64:(amt_word + 1) * 64], 16)
            ts_ms = ts_of.get(lg.block_number, 0) * 1000
            buf += struct.pack("<qii16sb", ts_ms, tl, tu, amt.to_bytes(16, "little"), is_mint)
            n += 1
        f.write(buf)
        nb = res.next_block
        if nb <= blk:
            break
        blk = nb
        if reqs % 50 == 0:
            print(f"  [LP {pool[:10]}] req {reqs}, blk {blk:,}/{end_block:,}, evts {n:,}", flush=True)
    f.close()
    print(f"DONE LP {pool}: {n:,} mint/burn → {out_path} ({Path(out_path).stat().st_size/1e6:.1f} MB)")
    return n


async def pull_swtick(client, pool, start_block, end_block, out_path):
    """Light Swap stream (ts_ms, tick, liquidity) for L-reconciliation ground truth."""
    f = open(out_path, "wb")
    blk, reqs, n = start_block, 0, 0
    while blk < end_block:
        q = Query(from_block=blk, to_block=end_block,
                  logs=[LogSelection(address=[pool], topics=[hs_pull.SWAP_T0])],
                  field_selection=FieldSelection(
                      block=[BlockField.NUMBER, BlockField.TIMESTAMP],
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
            buf += struct.pack("<qi16s", ts_ms, int(dd["tick"]), int(dd["liquidity"]).to_bytes(16, "little"))
            n += 1
        f.write(buf)
        nb = res.next_block
        if nb <= blk:
            break
        blk = nb
        if reqs % 100 == 0:
            print(f"  [SW {pool[:10]}] req {reqs}, blk {blk:,}/{end_block:,}, sw {n:,}", flush=True)
    f.close()
    print(f"DONE SW {pool}: {n:,} swaps → {out_path} ({Path(out_path).stat().st_size/1e6:.1f} MB)")
    return n


async def run(chain, pool, start_block, end_block, prefix):
    client = HypersyncClient(ClientConfig(url=hs_pull.ENDPOINTS[chain], bearer_token=hs_pull.TOKEN,
                                          proactive_rate_limit_sleep=True))
    await pull_lp(client, pool, start_block, end_block, f"{prefix}_lp.bin")
    await pull_swtick(client, pool, start_block, end_block, f"{prefix}_swtick.bin")


if __name__ == "__main__":
    _, chain, pool, sb, eb, prefix = sys.argv
    asyncio.run(run(chain, pool, int(sb), int(eb), prefix))
