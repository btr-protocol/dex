"""Generic BSC stable-pool swap-tape puller (stable-core study).

Pulls ~6mo of swap events per pool via HyperSync, decodes per family, writes
data/<label>.parquet with (ts_ms, token_in, token_out, amount_in, amount_out)
in HUMAN token units. Sequential pools (16GB Mac). Registry = stable-pools.json.

Run: uv run --with hypersync --with pyarrow python pull_tape.py [LABEL ...]
"""
import asyncio
import json
import sys
import time
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE.parent / "pool-fees"))
import hs_pull  # noqa: E402  (client cfg + token; token loaded from gitignored env)
from hypersync import (  # noqa: E402
    HypersyncClient, ClientConfig, Query, LogSelection, FieldSelection,
    LogField, BlockField,
)

REG = json.loads((HERE / "stable-pools.json").read_text())
TOKENS = REG["tokens"]
ADDR2SYM = {v["address"].lower(): k for k, v in TOKENS.items()}
DEC = {k: v["decimals"] for k, v in TOKENS.items()}
EVENTS = REG["swap_events"]

# Pools mandated for the 6mo tape pull (subset of registry).
PULL_LABELS = [
    "PCSv3_USDT_USDC_100", "PCSv3_USDT_USDC_500", "PCSv3_USD1_USDT_100",
    "PCSv3_USD1_USDC_100", "PCSv3_FDUSD_USDT_100", "PCSv3_FDUSD_USDC_100",
    "PCSv3_DAI_USDT_100", "PCSv3_DAI_USDC_100", "PCSv3_USDe_USDT_2500",
    "PCSv3_USDe_USDT_100", "PCSv3_TUSD_USDT_100",
    "UNIv4_USDT_USDC_A", "UNIv4_USDT_USDC_B", "UNIv4_USDT_USDC_C",
    "UNIv4_USD1_USDT_003", "UNIv4_USD1_USDT_001", "UNIv4_USD1_USDC_001",
    "PCSSS_USDT_BUSD", "PCSSS_USDT_USDC", "PCSSS_USDC_BUSD",
    "PCSSS_USD1_USDT", "PCSSS_USD1_USDC",
    "WOMBAT_main",
    "CURVE_3pool_FDUSD", "CURVE_3pool_BUSD", "CURVE_busd_usdt_dai",
    "ELLIPSIS_3EPS",
]

SCHEMA = pa.schema([
    ("ts_ms", pa.int64()), ("token_in", pa.string()), ("token_out", pa.string()),
    ("amount_in", pa.float64()), ("amount_out", pa.float64()),
])
FLUSH_ROWS = 500_000


def words(data_hex):
    h = data_hex[2:] if data_hex.startswith("0x") else data_hex
    return [h[i:i + 64] for i in range(0, len(h) - 63, 64)]


def _i(w, signed=False):
    v = int(w, 16)
    if signed and v >= 1 << 255:
        v -= 1 << 256
    return v


def _addr(w):
    return "0x" + w[24:]


# ── per-family decoders → (token_in, token_out, amount_in_raw, amount_out_raw) ──
# ctx: {"pair": [tok0_sym, tok1_sym], "coins": [sym,...]} as relevant.

def dec_v3(dh, ctx):
    """univ3/pcsv3: amount0/amount1 int256, positive = INTO pool."""
    w = words(dh)
    a0, a1 = _i(w[0], True), _i(w[1], True)
    t0, t1 = ctx["pair"]
    if a0 > 0 and a1 < 0:
        return t0, t1, a0, -a1
    if a1 > 0 and a0 < 0:
        return t1, t0, a1, -a0
    return None


def dec_v4(dh, ctx):
    """univ4/pcs-infinity: amount0/amount1 int128, SWAPPER perspective (neg = into pool)."""
    w = words(dh)
    a0, a1 = _i(w[0], True), _i(w[1], True)
    t0, t1 = ctx["pair"]
    if a0 < 0 and a1 > 0:
        return t0, t1, -a0, a1
    if a1 < 0 and a0 > 0:
        return t1, t0, -a1, a0
    return None


def dec_curve(dh, ctx):
    """curve int128 + pcs-stable uint256 TokenExchange: sold_id, tokens_sold, bought_id, tokens_bought."""
    w = words(dh)
    si, sold, bi, bought = _i(w[0], True), _i(w[1]), _i(w[2], True), _i(w[3])
    coins = ctx["coins"]
    if not (0 <= si < len(coins) and 0 <= bi < len(coins)):
        return None
    return coins[si], coins[bi], sold, bought


def dec_wombat(dh, ctx):
    """wombat: fromToken, toToken, fromAmount, toAmount (addresses in data)."""
    w = words(dh)
    ti, to = ADDR2SYM.get(_addr(w[0])), ADDR2SYM.get(_addr(w[1]))
    if ti is None or to is None:
        return None
    return ti, to, _i(w[2]), _i(w[3])


def dec_solidly(dh, ctx):
    """solidly/v2: amount0In, amount1In, amount0Out, amount1Out."""
    w = words(dh)
    a0i, a1i, a0o, a1o = (_i(x) for x in w[:4])
    t0, t1 = ctx["pair"]
    if a0i > 0 and a1o > 0:
        return t0, t1, a0i, a1o
    if a1i > 0 and a0o > 0:
        return t1, t0, a1i, a0o
    return None


def dec_dodo(dh, ctx):
    """dodo DODOSwap: fromToken, toToken, fromAmount, toAmount, trader, receiver."""
    return dec_wombat(dh, ctx)


DECODERS = {
    "univ3": dec_v3, "pcsv3": dec_v3,
    "univ4": dec_v4, "pcs-infinity-cl": dec_v4,
    "pcs-stable": dec_curve, "curve": dec_curve,
    "wombat": dec_wombat, "solidly": dec_solidly, "dodo": dec_dodo,
}


def ctx_for(pool):
    syms = pool["tokens"]
    fam = pool["family"]
    if fam in ("univ3", "pcsv3", "univ4", "pcs-infinity-cl", "solidly"):
        # canonical token0/token1 = ascending address
        pair = sorted(syms, key=lambda s: TOKENS[s]["address"].lower())
        return {"pair": pair}
    return {"coins": syms}  # curve/pcs-stable: registry order = verified coins order


async def pull_pool(client, pool, start_block, end_block, out_path):
    fam = pool["family"]
    decode = DECODERS[fam]
    ctx = ctx_for(pool)
    topics = [[EVENTS[fam]["topic0"]]]
    if pool.get("pool_id"):
        topics.append([pool["pool_id"]])
    writer = pq.ParquetWriter(out_path, SCHEMA, compression="zstd")
    cols = ([], [], [], [], [])
    n = reqs = skipped = 0
    first_ts = last_ts = None
    blk = start_block
    t_start = time.time()

    def flush():
        nonlocal cols
        if cols[0]:
            writer.write_table(pa.table(dict(zip(SCHEMA.names, cols)), schema=SCHEMA))
            cols = ([], [], [], [], [])

    while blk < end_block:
        q = Query(from_block=blk, to_block=end_block,
                  logs=[LogSelection(address=[pool["address"]], topics=topics)],
                  field_selection=FieldSelection(
                      block=[BlockField.NUMBER, BlockField.TIMESTAMP],
                      log=[LogField.BLOCK_NUMBER, LogField.DATA]))
        res = await client.get(q)
        reqs += 1
        ts_of = {b.number: int(b.timestamp, 16) for b in (res.data.blocks or [])}
        for lg in res.data.logs:
            r = decode(lg.data, ctx)
            if r is None:
                skipped += 1
                continue
            tin, tout, ain, aout = r
            ts_ms = ts_of.get(lg.block_number, 0) * 1000
            cols[0].append(ts_ms)
            cols[1].append(tin)
            cols[2].append(tout)
            cols[3].append(ain / 10 ** DEC[tin])
            cols[4].append(aout / 10 ** DEC[tout])
            n += 1
            if first_ts is None:
                first_ts = ts_ms
            last_ts = ts_ms
        if len(cols[0]) >= FLUSH_ROWS:
            flush()
        nb = res.next_block
        if nb <= blk:
            break
        blk = nb
        if reqs % 50 == 0:
            print(f"  [{pool['label']}] req {reqs}, blk {blk:,}/{end_block:,}, swaps {n:,}", flush=True)
    flush()
    writer.close()
    dt = time.time() - t_start
    note = " ⚠ <100 swaps/6mo — thin, noted" if n < 100 else ""
    print(f"DONE {pool['label']}: {n:,} rows ({skipped} undecoded), {reqs} reqs, "
          f"{dt:.0f}s → {out_path}{note}", flush=True)
    return {"label": pool["label"], "rows": n, "first_ts": first_ts, "last_ts": last_ts,
            "file": str(out_path)}


async def main(labels):
    by_label = {p["label"]: p for p in REG["pools"]}
    start = REG["block_range"]["block_6mo"]
    client = HypersyncClient(ClientConfig(url=REG["endpoint"], bearer_token=hs_pull.TOKEN,
                                          proactive_rate_limit_sleep=True))
    end = await client.get_height()
    print(f"BSC head={end:,}, pulling {len(labels)} pools from block {start:,} (~6mo)", flush=True)
    out_dir = HERE / "data"
    out_dir.mkdir(exist_ok=True)
    manifest = []
    for lb in labels:
        pool = by_label[lb]
        manifest.append(await pull_pool(client, pool, start, end, out_dir / f"{lb}.parquet"))
    mf = out_dir / "manifest.json"  # merge by label: parallel runs cover disjoint pools
    merged = {m["label"]: m for m in (json.loads(mf.read_text()) if mf.exists() else [])}
    merged.update({m["label"]: m for m in manifest})
    mf.write_text(json.dumps(list(merged.values()), indent=1))
    print("MANIFEST:", json.dumps(manifest))


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:] or PULL_LABELS))
