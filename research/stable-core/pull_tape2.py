"""Family-batched BSC stable-pool tape puller (stable-core study).

Same decode + output as pull_tape.py, but ONE HyperSync scan per family:
multi-address (discrete pools) or multi-topic1 (univ4/pcs-infinity singletons),
routing each log to its pool's parquet. Cuts 45 full-range scans to 9.

Run: uv run --with hypersync --with pyarrow python pull_tape2.py <FAMILY|LABEL ...>
Families: pcsv3 univ3 univ4 pcs-infinity-cl pcs-stable curve solidly wombat dodo
"""
import asyncio
import json
import os
import sys
import time
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE.parent / "pool-fees"))
import hs_pull  # noqa: E402
from hypersync import (  # noqa: E402
    HypersyncClient, ClientConfig, Query, LogSelection, FieldSelection,
    LogField, BlockField,
)
from pull_tape import DECODERS, EVENTS, REG, SCHEMA, ctx_for  # noqa: E402

FLUSH_ROWS = 200_000
SINGLETON = {"univ4", "pcs-infinity-cl"}


class PoolSink:
    def __init__(self, pool, out_dir):
        self.pool = pool
        self.ctx = ctx_for(pool)
        self.path = out_dir / f"{pool['label']}.parquet"
        self.writer = pq.ParquetWriter(self.path, SCHEMA, compression="zstd")
        self.cols = ([], [], [], [], [])
        self.n = self.skipped = 0
        self.first_ts = self.last_ts = None

    def add(self, decode, dh, ts_ms, dec):
        r = decode(dh, self.ctx)
        if r is None:
            self.skipped += 1
            return
        tin, tout, ain, aout = r
        c = self.cols
        c[0].append(ts_ms)
        c[1].append(tin)
        c[2].append(tout)
        c[3].append(ain / 10 ** dec[tin])
        c[4].append(aout / 10 ** dec[tout])
        self.n += 1
        if self.first_ts is None:
            self.first_ts = ts_ms
        self.last_ts = ts_ms
        if len(c[0]) >= FLUSH_ROWS:
            self.flush()

    def flush(self):
        if self.cols[0]:
            self.writer.write_table(
                pa.table(dict(zip(SCHEMA.names, self.cols)), schema=SCHEMA))
            self.cols = ([], [], [], [], [])

    def close(self):
        self.flush()
        self.writer.close()
        note = " ⚠ <100 swaps/6mo — thin" if self.n < 100 else ""
        print(f"DONE {self.pool['label']}: {self.n:,} rows ({self.skipped} undecoded) "
              f"→ {self.path}{note}", flush=True)
        return {"label": self.pool["label"], "rows": self.n, "first_ts": self.first_ts,
                "last_ts": self.last_ts, "file": str(self.path)}


async def pull_family(client, fam, pools, start_block, end_block, out_dir):
    decode = DECODERS[fam]
    dec = {k: v["decimals"] for k, v in REG["tokens"].items()}
    singleton = fam in SINGLETON
    if singleton:
        addr = [pools[0]["address"]]
        topics = [[EVENTS[fam]["topic0"]], [p["pool_id"] for p in pools]]
        route = {p["pool_id"].lower(): PoolSink(p, out_dir) for p in pools}
    else:
        addr = [p["address"] for p in pools]
        topics = [[EVENTS[fam]["topic0"]]]
        route = {p["address"].lower(): PoolSink(p, out_dir) for p in pools}
    log_fields = [LogField.BLOCK_NUMBER, LogField.DATA, LogField.ADDRESS,
                  LogField.TOPIC0, LogField.TOPIC1]
    n = reqs = 0
    blk = start_block
    t0 = time.time()
    while blk < end_block:
        q = Query(from_block=blk, to_block=end_block,
                  logs=[LogSelection(address=addr, topics=topics)],
                  field_selection=FieldSelection(
                      block=[BlockField.NUMBER, BlockField.TIMESTAMP], log=log_fields))
        res = await client.get(q)
        reqs += 1
        ts_of = {b.number: int(b.timestamp, 16) for b in (res.data.blocks or [])}
        for lg in res.data.logs:
            key = (lg.topics[1] if singleton else lg.address).lower()
            sink = route.get(key)
            if sink is None:
                continue
            sink.add(decode, lg.data, ts_of.get(lg.block_number, 0) * 1000, dec)
            n += 1
        nb = res.next_block
        if nb <= blk:
            break
        blk = nb
        if reqs % 50 == 0:
            print(f"  [{fam}] req {reqs}, blk {blk:,}/{end_block:,}, swaps {n:,}", flush=True)
    manifest = [s.close() for s in route.values()]
    print(f"FAMILY-DONE {fam}: {n:,} swaps, {reqs} reqs, {time.time() - t0:.0f}s", flush=True)
    return manifest


async def main(args):
    by_fam = {}
    for p in REG["pools"]:
        if p["family"] in args or p["label"] in args:
            by_fam.setdefault(p["family"], []).append(p)
    if not by_fam:
        sys.exit(f"nothing matched {args}")
    start = int(os.environ.get("START_BLOCK", REG["block_range"]["block_6mo"]))
    client = HypersyncClient(ClientConfig(url=REG["endpoint"], bearer_token=hs_pull.TOKEN,
                                          proactive_rate_limit_sleep=True))
    end = int(os.environ.get("END_BLOCK", 0)) or await client.get_height()
    npools = sum(len(v) for v in by_fam.values())
    print(f"BSC head={end:,}, {len(by_fam)} family scans / {npools} pools "
          f"from block {start:,}", flush=True)
    out_dir = HERE / "data"
    out_dir.mkdir(exist_ok=True)
    manifest = []
    for fam, pools in by_fam.items():
        manifest += await pull_family(client, fam, pools, start, end, out_dir)
    mf = out_dir / "manifest.json"
    merged = {m["label"]: m for m in (json.loads(mf.read_text()) if mf.exists() else [])}
    merged.update({m["label"]: m for m in manifest})
    mf.write_text(json.dumps(list(merged.values()), indent=1))
    print("MANIFEST:", json.dumps(manifest), flush=True)


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:]))
