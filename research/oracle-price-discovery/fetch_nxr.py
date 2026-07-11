#!/usr/bin/env python3
"""Cache real-tick NXR bars for the oracle policy evaluator."""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

FIELDS = (
    "ts",
    "open",
    "high",
    "low",
    "close",
    "vbid",
    "vask",
    "tick_count",
    "avg_ci_ubp",
)


def fetch_window(
    symbol: str,
    start_ms: int,
    end_ms: int,
    timeframe_s: int,
    api_key: str,
) -> list[dict]:
    query = urllib.parse.urlencode(
        {
            "tf": timeframe_s,
            "from": start_ms,
            "to": end_ms,
            "limit": 10_000,
        }
    )
    request = urllib.request.Request(
        f"https://api.nxrates.com/v1/ohlc/{symbol}?{query}",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Accept": "application/json",
            "User-Agent": "btr-oracle-policy-study/1",
        },
    )
    last_error: Exception | None = None
    for attempt in range(8):
        try:
            with urllib.request.urlopen(request, timeout=40) as response:
                payload = json.loads(response.read())
            if not isinstance(payload, list):
                raise ValueError(f"unexpected NXR response for {symbol}")
            return payload
        except Exception as error:
            last_error = error
            if attempt < 7:
                time.sleep(min(2 ** attempt, 20))
    raise RuntimeError(f"NXR fetch failed for {symbol}: {last_error}")


def fetch_symbol(
    symbol: str,
    start_ms: int,
    end_ms: int,
    timeframe_s: int,
    api_key: str,
) -> list[dict]:
    rows: dict[int, dict] = {}
    cursor = start_ms
    max_window_ms = 9_500 * timeframe_s * 1_000
    while cursor < end_ms:
        window_end = min(cursor + max_window_ms, end_ms)
        payload = fetch_window(symbol, cursor, window_end, timeframe_s, api_key)
        for raw in payload:
            if int(raw.get("tick_count", 0)) <= 0:
                continue
            close = float(raw.get("close", 0.0))
            if close <= 0.0:
                continue
            ts = int(raw["ts"])
            rows[ts] = {field: raw.get(field, 0) for field in FIELDS}
        cursor = window_end + timeframe_s * 1_000
        print(
            f"{symbol}: {len(rows):,} real bars through {window_end}",
            file=sys.stderr,
            flush=True,
        )
        time.sleep(0.05)
    return [rows[ts] for ts in sorted(rows)]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--symbols",
        nargs="+",
        default=["BTC-USDT", "ETH-USDT", "BNB-USDT", "CAKE-USDT", "XAUT-USDT"],
    )
    parser.add_argument("--days", type=int, default=21)
    parser.add_argument("--timeframe", type=int, default=30)
    parser.add_argument("--end-ms", type=int)
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path(__file__).parent / "data",
    )
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    api_key = os.environ.get("NXR_API_KEY", "").strip()
    if not api_key:
        raise SystemExit("NXR_API_KEY is required")
    end_ms = args.end_ms or int(time.time() * 1_000)
    start_ms = end_ms - args.days * 86_400_000
    args.out_dir.mkdir(parents=True, exist_ok=True)

    for symbol in args.symbols:
        output = args.out_dir / f"{symbol}_{args.timeframe}s_{args.days}d.csv"
        if output.exists() and not args.force:
            print(f"skip existing {output}", file=sys.stderr)
            continue
        rows = fetch_symbol(
            symbol,
            start_ms,
            end_ms,
            args.timeframe,
            api_key,
        )
        temporary = output.with_suffix(".tmp")
        with temporary.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=FIELDS)
            writer.writeheader()
            writer.writerows(rows)
        temporary.replace(output)
        print(f"wrote {len(rows):,} rows to {output}", file=sys.stderr)


if __name__ == "__main__":
    main()
