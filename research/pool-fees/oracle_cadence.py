#!/usr/bin/env python3
"""Estimate ExternalOracle update cadence from historical NXR marks.

The simulator mirrors keepers/src/oracle/mod.rs:
  heartbeat -> absolute deviation from last pushed mark -> CI spike.

It reports both per-feed updates and batched transactions. NXR bars are sampled
at their native timestamps; flat-filled bars (tick_count == 0) are ignored and
the latest real bar may be reused for at most mark_max_age_s.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import statistics
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone

BPS = 10_000.0
CI_SCALE = 16.0
CI_TRIGGER_BPS = 25


@dataclass(frozen=True)
class Bar:
    ts: int
    close: float
    confidence_bps: float


@dataclass(frozen=True)
class Feed:
    name: str
    symbols: tuple[str, ...]
    group: str


FEEDS = (
    Feed("USDC-USDC", ("USDC-USDT", "USDT-USDC"), "stable"),
    Feed("USDT-USDC", ("USDT-USDC",), "stable"),
    Feed("USD1-USDC", ("USD1-USDC",), "stable"),
    Feed("USDE-USDC", ("USDE-USDC",), "stable"),
    Feed("FDUSD-USDC", ("FDUSD-USDC",), "stable"),
    Feed("BTCB-USDC", ("BTC-USDT", "USDT-USDC"), "volatile"),
    Feed("ETH-USDC", ("ETH-USDT", "USDT-USDC"), "volatile"),
    Feed("WBNB-USDC", ("BNB-USDT", "USDT-USDC"), "volatile"),
    Feed("CAKE-USDC", ("CAKE-USDT", "USDT-USDC"), "volatile"),
    Feed("XAUT-USDC", ("XAUT-USDT", "USDT-USDC"), "volatile"),
)


def percentile(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[round((len(ordered) - 1) * q)]


def decode_confidence(encoded: int) -> float:
    x = encoded / CI_SCALE
    return (x * x) / 10_000.0


def fetch_bars(
    symbol: str,
    start_ms: int,
    end_ms: int,
    timeframe_s: int,
    api_key: str,
) -> list[Bar]:
    rows: dict[int, Bar] = {}
    cursor = start_ms
    max_window_ms = 9_500 * timeframe_s * 1_000
    while cursor < end_ms:
        window_end = min(cursor + max_window_ms, end_ms)
        query = urllib.parse.urlencode(
            {
                "tf": timeframe_s,
                "from": cursor,
                "to": window_end,
                "limit": 10_000,
            }
        )
        request = urllib.request.Request(
            f"https://api.nxrates.com/v1/ohlc/{symbol}?{query}",
            headers={
                "Authorization": f"Bearer {api_key}",
                "User-Agent": "btr-oracle-cadence/1",
                "Accept": "application/json",
            },
        )
        with urllib.request.urlopen(request, timeout=40) as response:
            payload = json.loads(response.read())
        for raw in payload:
            if raw.get("tick_count", 0) <= 0:
                continue
            close = float(raw["close"])
            if not math.isfinite(close) or close <= 0:
                continue
            ts = int(raw["ts"])
            rows[ts] = Bar(
                ts=ts,
                close=close,
                confidence_bps=decode_confidence(int(raw.get("avg_ci_ubp", 0))),
            )
        cursor = window_end + timeframe_s * 1_000
        time.sleep(0.05)
    return sorted(rows.values(), key=lambda bar: bar.ts)


def asof_marks(
    feed: Feed,
    series: dict[str, list[Bar]],
    timestamps: list[int],
    max_age_ms: int,
) -> dict[int, tuple[float, int]]:
    indices = {symbol: 0 for symbol in feed.symbols}
    latest: dict[str, Bar] = {}
    marks: dict[int, tuple[float, int]] = {}
    for ts in timestamps:
        valid = True
        mark = 1.0
        conf_sq = 0.0
        for symbol in feed.symbols:
            bars = series[symbol]
            idx = indices[symbol]
            while idx < len(bars) and bars[idx].ts <= ts:
                latest[symbol] = bars[idx]
                idx += 1
            indices[symbol] = idx
            bar = latest.get(symbol)
            if bar is None or ts - bar.ts > max_age_ms:
                valid = False
                break
            mark *= bar.close
            conf_sq += bar.confidence_bps * bar.confidence_bps
        if valid:
            marks[ts] = (mark, max(1, min(65_535, round(math.sqrt(conf_sq)))))
    return marks


def simulate(
    feed: Feed,
    marks: dict[int, tuple[float, int]],
    theta_bps: float,
    heartbeat_s: int,
    max_deviation_bps: float,
    ttl_s: int,
) -> dict:
    last_price: float | None = None
    last_confidence: int | None = None
    last_push_ms = 0
    events: list[tuple[int, str]] = []
    jumps: list[float] = []
    reasons = {"cold-start": 0, "heartbeat": 0, "deviation": 0, "ci-spike": 0}
    rejected = 0
    for ts, (mark, confidence) in marks.items():
        reason: str | None = None
        if last_price is None:
            reason = "cold-start"
        elif ts - last_push_ms >= heartbeat_s * 1_000:
            reason = "heartbeat"
        elif abs(mark - last_price) / last_price * BPS > theta_bps:
            reason = "deviation"
        elif (
            last_confidence is not None
            and confidence > last_confidence + CI_TRIGGER_BPS
        ):
            reason = "ci-spike"
        if reason is None:
            continue
        if last_price is not None:
            jump_bps = abs(mark - last_price) / last_price * BPS
            dt_s = max(0.0, (ts - last_push_ms) / 1_000.0)
            allowed_bps = min(
                65_000.0,
                max_deviation_bps * (1.0 + dt_s / ttl_s),
            )
            # Mirrors ExternalOracle._pushInternal: an outlier is attempted but the
            # on-chain mark stays unchanged. The keeper may retry on the next poll.
            if jump_bps > allowed_bps:
                rejected += 1
                continue
            jumps.append(jump_bps)
        events.append((ts, reason))
        reasons[reason] += 1
        last_price = mark
        last_confidence = confidence
        last_push_ms = ts
    return {
        "feed": feed.name,
        "group": feed.group,
        "theta_bps": theta_bps,
        "heartbeat_s": heartbeat_s,
        "events": events,
        "reasons": reasons,
        "rejected_attempts": rejected,
        "jumps_bps": jumps,
    }


def summarize(name: str, runs: list[dict], days: float) -> dict:
    batch_timestamps = {ts for run in runs for ts, _ in run["events"]}
    feeds = []
    for run in runs:
        jumps = run["jumps_bps"]
        feeds.append(
            {
                "feed": run["feed"],
                "group": run["group"],
                "theta_bps": run["theta_bps"],
                "heartbeat_s": run["heartbeat_s"],
                "updates": len(run["events"]),
                "updates_per_day": len(run["events"]) / days,
                "reasons": run["reasons"],
                "rejected_attempts": run["rejected_attempts"],
                "jump_bps": {
                    "mean": statistics.fmean(jumps) if jumps else 0.0,
                    "p50": percentile(jumps, 0.50),
                    "p95": percentile(jumps, 0.95),
                    "p99": percentile(jumps, 0.99),
                    "max": max(jumps, default=0.0),
                },
            }
        )
    return {
        "scenario": name,
        "feed_updates": sum(len(run["events"]) for run in runs),
        "feed_updates_per_day": sum(len(run["events"]) for run in runs) / days,
        "batched_transactions": len(batch_timestamps),
        "batched_transactions_per_day": len(batch_timestamps) / days,
        "feeds": feeds,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--timeframe", type=int, default=30)
    parser.add_argument("--mark-max-age", type=int, default=120)
    args = parser.parse_args()

    api_key = os.environ.get("NXR_API_KEY", "").strip()
    if not api_key:
        raise SystemExit("NXR_API_KEY is required")

    end_ms = int(time.time() * 1_000)
    start_ms = end_ms - args.days * 86_400_000
    symbols = sorted({symbol for feed in FEEDS for symbol in feed.symbols})
    series: dict[str, list[Bar]] = {}
    unavailable: dict[str, str] = {}
    for symbol in symbols:
        try:
            series[symbol] = fetch_bars(
                symbol, start_ms, end_ms, args.timeframe, api_key
            )
            if not series[symbol]:
                unavailable[symbol] = "no real-tick bars"
        except Exception as error:  # report partial coverage instead of losing the run
            unavailable[symbol] = str(error)

    available_feeds = [
        feed
        for feed in FEEDS
        if all(symbol in series and series[symbol] for symbol in feed.symbols)
    ]
    timestamps = list(
        range(
            start_ms - (start_ms % (args.timeframe * 1_000)),
            end_ms + 1,
            args.timeframe * 1_000,
        )
    )
    marks = {
        feed.name: asof_marks(
            feed,
            series,
            timestamps,
            args.mark_max_age * 1_000,
        )
        for feed in available_feeds
    }

    scenarios = {
        "current_chapel": {
            "stable": (0.5, 1_800, 100.0, 7_200),
            "volatile": (5.0, 300, 500.0, 600),
        },
        "candidate": {
            "stable": (0.1, 1_800, 100.0, 7_200),
            "volatile": (10.0, 300, 500.0, 600),
        },
        "volatile_10_stable_current": {
            "stable": (0.5, 1_800, 100.0, 7_200),
            "volatile": (10.0, 300, 500.0, 600),
        },
        "volatile_10_stable_0_3": {
            "stable": (0.3, 1_800, 100.0, 7_200),
            "volatile": (10.0, 300, 500.0, 600),
        },
    }
    output = {
        "source": {
            "provider": "NXR",
            "start": datetime.fromtimestamp(
                start_ms / 1_000, tz=timezone.utc
            ).isoformat(),
            "end": datetime.fromtimestamp(
                end_ms / 1_000, tz=timezone.utc
            ).isoformat(),
            "timeframe_s": args.timeframe,
            "mark_max_age_s": args.mark_max_age,
            "requested_days": args.days,
            "available_feeds": [feed.name for feed in available_feeds],
            "unavailable_symbols": unavailable,
        },
        "scenarios": [],
    }
    for name, policy in scenarios.items():
        runs = []
        for feed in available_feeds:
            theta, heartbeat, max_deviation, ttl = policy[feed.group]
            runs.append(
                simulate(
                    feed,
                    marks[feed.name],
                    theta,
                    heartbeat,
                    max_deviation,
                    ttl,
                )
            )
        output["scenarios"].append(summarize(name, runs, float(args.days)))
    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
