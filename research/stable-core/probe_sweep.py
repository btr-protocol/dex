"""stable-core registry probe (one-shot).

1. Measure BSC block time empirically (two block timestamps) + binary-search the block ~6mo ago.
2. Chain-wide topic0 sweeps (recent window) for low-volume families — wombat Swap, DODOSwap,
   curve TokenExchange int128/uint256 — to discover ALL active pool addresses per family.
3. Singleton sweeps (uni-v4 / PCS-infinity Swap) to find PoolManager addresses + top stable poolIds.

Token loaded from ../pool-fees/hypersync.env (never printed). Run:
  uv run --with hypersync python probe_sweep.py sweep
"""
import asyncio, os, sys, time, json
from collections import Counter
from pathlib import Path

import hypersync
from hypersync import (HypersyncClient, ClientConfig, Query, LogSelection,
                       FieldSelection, LogField, BlockField)

HERE = Path(__file__).parent
for line in (HERE.parent / "pool-fees" / "hypersync.env").read_text().splitlines():
    if line.startswith("HYPERSYNC_BEARER_TOKEN="):
        os.environ["HYPERSYNC_BEARER_TOKEN"] = line.split("=", 1)[1].strip()

URL = "https://bsc.hypersync.xyz"
T0 = {
    "univ3": "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67",
    "pcsv3": "0x19b47279256b2a23a1665c810c8d55a1758940ee09377d4f8d26497a3577dc83",
    "curve_i128": "0x8b3e96f2b889fa771c53c981b40daf005f63f637f1869f707052d15a3dd97140",
    "curve_u256": "0xb2e76ae99761dc136e598d4a629bb347eccb9532a5f8bbd72e18467c3c34cc98",
    "solidly_v2": "0xd78ad95fa46c994b6551d0da85fc275fe613ce37657fb8d5e3d130840159d822",
    "wombat": "0x54787c404bb33c88e86f4baf88183a3b0141d0a848e6a9f7a13b66ae3a9b73d1",  # cast keccak "Swap(address,address,address,uint256,uint256,address)"
    "dodo": "0xc2c0245e056d5fb095f04cd6373bc770802ebd1e6c918eb78fdef843cdb37b0f",
    "univ4": "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f",
    "pcs_infi": "0x04206ad2b7c0f463bff3dd4f33c5735b0f2957a351e4f79763a4fa9e775dd237",
}


def client():
    return HypersyncClient(ClientConfig(url=URL, bearer_token=os.environ["HYPERSYNC_BEARER_TOKEN"],
                                        proactive_rate_limit_sleep=True))


async def block_ts(c, n):
    q = Query(from_block=n, to_block=n + 1, include_all_blocks=True,
              field_selection=FieldSelection(block=[BlockField.NUMBER, BlockField.TIMESTAMP]))
    r = await c.get(q)
    b = r.data.blocks[0]
    return int(b.timestamp, 16)


async def blockmeta():
    c = client()
    h = await c.get_height()
    a, b = h - 1000, h - 1000 - 115_200  # ~1 day apart at 0.75s
    ta, tb = await block_ts(c, a), await block_ts(c, b)
    bt = (ta - tb) / (a - b)
    target = int(time.time()) - int(182.5 * 86400)
    lo, hi = 1, h - 1
    # seed with linear estimate then binary search on timestamp
    while lo < hi:
        mid = (lo + hi) // 2
        tm = await block_ts(c, mid)
        if tm < target:
            lo = mid + 1
        else:
            hi = mid
    t6 = await block_ts(c, lo)
    print(json.dumps({"height": h, "block_time_s": round(bt, 4),
                      "ts_head": ta, "block_6mo": lo, "ts_6mo": t6,
                      "target_ts": target}))
    return h


async def sweep(name, t0, from_block, to_block, with_topic1=False):
    """Chain-wide: all logs with topic0=t0; count per address (and topic1 if singleton)."""
    c = client()
    cnt = Counter()
    blk = from_block
    fields = [LogField.ADDRESS, LogField.TOPIC0] + ([LogField.TOPIC1] if with_topic1 else [])
    reqs = 0
    while blk < to_block:
        q = Query(from_block=blk, to_block=to_block,
                  logs=[LogSelection(topics=[[t0]])],
                  field_selection=FieldSelection(log=fields))
        r = await c.get(q)
        reqs += 1
        for lg in r.data.logs:
            key = (lg.address.lower(), (lg.topics[1] if with_topic1 and len(lg.topics) > 1 else ""))
            cnt[key] += 1
        nb = r.next_block
        if nb <= blk:
            break
        blk = nb
    out = [{"address": a, "topic1": t1, "n": n} for (a, t1), n in cnt.most_common(40)]
    print(json.dumps({"family": name, "reqs": reqs, "n_addrs": len(cnt), "top": out}))


async def probe(addrs, from_block, to_block):
    """ONE pass: count Swap-family logs per (address, topic0) for all addrs together."""
    c = client()
    all_t0 = [v for v in T0.values() if v]
    cnt = Counter()
    blk = from_block
    reqs = 0
    while blk < to_block:
        q = Query(from_block=blk, to_block=to_block,
                  logs=[LogSelection(address=addrs, topics=[all_t0])],
                  field_selection=FieldSelection(log=[LogField.ADDRESS, LogField.TOPIC0]))
        r = await c.get(q)
        reqs += 1
        for lg in r.data.logs:
            cnt[(lg.address.lower(), lg.topics[0] if lg.topics else "none")] += 1
        nb = r.next_block
        if nb <= blk:
            break
        blk = nb
        print(f"# req {reqs} -> block {blk:,}/{to_block:,} ({100*(blk-from_block)/(to_block-from_block):.0f}%)",
              file=sys.stderr, flush=True)
    fam = {v: k for k, v in T0.items() if v}
    per = {}
    for (a, t), n in cnt.items():
        per.setdefault(a, {})[t] = {"n": n, "fam": fam.get(t, "?")}
    for a in addrs:
        print(json.dumps({"address": a, "topics": per.get(a, {})}))


async def main():
    mode = sys.argv[1]
    if mode == "meta":
        await blockmeta()
        return
    c = client()
    h = await c.get_height()
    days = float(sys.argv[2]) if len(sys.argv) > 2 else 14.0
    # empirical BSC block time ~0.45s (post-Fermi); FB env overrides start block
    fb = int(os.environ["FB"]) if "FB" in os.environ else h - int(days * 86400 / 0.45)
    if mode == "sweep":
        import subprocess
        wombat = subprocess.run(["cast", "keccak", "Swap(address,address,address,uint256,uint256,address)"],
                                capture_output=True, text=True).stdout.strip()
        T0["wombat"] = wombat
        print(json.dumps({"wombat_t0": wombat, "from_block": fb, "head": h}))
        fams = sys.argv[3].split(",") if len(sys.argv) > 3 else \
            ["wombat", "dodo", "curve_i128", "curve_u256", "univ4", "pcs_infi"]
        for name, t1 in [(f, f in ("univ4", "pcs_infi")) for f in fams]:
            await sweep(name, T0[name], fb, h, with_topic1=t1)
    elif mode == "probe":
        await probe([a.lower() for a in sys.argv[3].split(",")], fb, h)

asyncio.run(main())
