#!/usr/bin/env python3
"""Aggregate real v3 swap direction into 30-second buy/sell flow bars."""

from __future__ import annotations

import argparse
import asyncio
import csv
import math
import os
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).parent
POOL_FEES = HERE.parent / "pool-fees"
sys.path.insert(0, str(POOL_FEES))

from hypersync import (  # type: ignore  # imported through uv --with hypersync
    BlockField,
    ClientConfig,
    FieldSelection,
    HypersyncClient,
    LogField,
    LogSelection,
    Query,
)

import hs_pull  # type: ignore


@dataclass(frozen=True)
class Pool:
    symbol: str
    chain: str
    address: str
    asset_index: int
    asset_decimals: int
    block_time_s: float


POOLS = {
    "BTC-USDT": Pool(
        "BTC-USDT",
        "base",
        "0x4e962bb3889bf030368f56810a9c96b83cb3e778",
        1,  # USDC token0, cbBTC token1
        8,
        2.0,
    ),
    "ETH-USDT": Pool(
        "ETH-USDT",
        "base",
        "0xb2cc224c1c9fee385f8ad6a55b4d94e92359dc59",
        0,  # WETH token0, USDC token1
        18,
        2.0,
    ),
    "BNB-USDT": Pool(
        "BNB-USDT",
        "bsc",
        "0x172fcd41e0913e95784454622d1c3724f546f849",
        1,  # USDT token0, WBNB token1
        18,
        3.0,
    ),
}


def nxr_bounds(path: Path) -> tuple[int, int]:
    with path.open() as handle:
        reader = csv.DictReader(handle)
        rows = list(reader)
    return int(rows[0]["ts"]), int(rows[-1]["ts"])


async def fetch(pool: Pool, start_ms: int, end_ms: int, output: Path) -> None:
    client = HypersyncClient(
        ClientConfig(
            url=hs_pull.ENDPOINTS[pool.chain],
            bearer_token=hs_pull.TOKEN,
            proactive_rate_limit_sleep=True,
        )
    )
    head = await client.get_height()
    span_s = max(86_400.0, (end_ms - start_ms) / 1_000.0)
    from_block = max(0, head - math.ceil(span_s / pool.block_time_s * 1.20))
    query = Query(
        from_block=from_block,
        to_block=head,
        logs=[LogSelection(address=[pool.address], topics=[hs_pull.SWAP_T0])],
        field_selection=FieldSelection(
            block=[BlockField.NUMBER, BlockField.TIMESTAMP],
            log=[LogField.BLOCK_NUMBER, LogField.DATA],
        ),
    )
    buckets: dict[int, list[float]] = defaultdict(lambda: [0.0, 0.0, 0.0])
    pages = swaps = 0
    while query.from_block < head:
        response = await client.get(query)
        pages += 1
        timestamps = {
            block.number: int(block.timestamp, 16) * 1_000
            for block in (response.data.blocks or [])
        }
        for log in response.data.logs:
            ts_ms = timestamps.get(log.block_number, 0)
            if ts_ms < start_ms or ts_ms > end_ms:
                continue
            decoded = hs_pull.decode_swap_data(log.data)
            if decoded is None:
                continue
            raw = decoded[f"amount{pool.asset_index}"]
            quantity = abs(raw) / 10 ** pool.asset_decimals
            if quantity <= 0.0:
                continue
            bucket = ts_ms // 30_000 * 30_000
            if raw < 0:
                buckets[bucket][0] += quantity  # asset leaves pool: trader buys
            else:
                buckets[bucket][1] += quantity  # asset enters pool: trader sells
            buckets[bucket][2] += 1
            swaps += 1
        next_block = response.next_block
        if next_block <= query.from_block:
            break
        query.from_block = next_block
        if pages % 20 == 0:
            print(
                f"{pool.symbol}: page {pages}, block {next_block:,}/{head:,}, swaps {swaps:,}",
                file=sys.stderr,
                flush=True,
            )
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".tmp")
    with temporary.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(("ts", "buy_qty", "sell_qty", "swaps"))
        for ts in sorted(buckets):
            writer.writerow((ts, *buckets[ts]))
    temporary.replace(output)
    print(f"wrote {len(buckets):,} flow bars / {swaps:,} swaps to {output}", file=sys.stderr)


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--symbols",
        nargs="+",
        default=["BTC-USDT", "ETH-USDT", "BNB-USDT"],
    )
    parser.add_argument("--data-dir", type=Path, default=HERE / "data")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    for symbol in args.symbols:
        pool = POOLS[symbol]
        nxr = next(args.data_dir.glob(f"{symbol}_30s_21d.csv"))
        output = args.data_dir / f"{symbol}_flows_30s_21d.csv"
        if output.exists() and not args.force:
            print(f"skip existing {output}", file=sys.stderr)
            continue
        start_ms, end_ms = nxr_bounds(nxr)
        await fetch(pool, start_ms, end_ms, output)


if __name__ == "__main__":
    asyncio.run(main())
