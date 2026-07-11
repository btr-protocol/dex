#!/usr/bin/env python3
"""Causal train/test/break/holdout orchestration for oracle policy policies."""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import statistics
import subprocess
from pathlib import Path

HERE = Path(__file__).parent
DEX = HERE.parents[1]
SIM = DEX / "sim"
BINARY = SIM / "target/release/examples/oracle_policy_eval"
RESULTS = HERE / "results"


def config_id(config: dict) -> str:
    encoded = json.dumps(config, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha1(encoded).hexdigest()[:12]


def deck() -> list[dict]:
    configs: list[dict] = []
    for theta in (5, 10, 20):
        configs.append({"policy": "hard", "theta-bp": theta, "heartbeat-s": 300})
    for half_life in (30, 60, 120, 300):
        for breaker in (25, 100):
            configs.append(
                {
                    "policy": "smooth",
                    "theta-bp": 10,
                    "heartbeat-s": 300,
                    "smooth-half-life-s": half_life,
                    "breaker-bp": breaker,
                }
            )
    for gain in (0.1, 0.25, 0.5, 1.0):
        for half_life in (30, 150):
            for cap in (2, 5, 10):
                configs.append(
                    {
                        "policy": "offset",
                        "theta-bp": 10,
                        "heartbeat-s": 300,
                        "offset-gain": gain,
                        "offset-half-life-s": half_life,
                        "offset-cap-bp": cap,
                    }
                )
    for floor in (1, 5):
        for cap in (10, 20, 30):
            for age_z in (50, 100, 200):
                configs.append(
                    {
                        "policy": "adaptive",
                        "theta-floor-bp": floor,
                        "theta-cap-bp": cap,
                        "heartbeat-s": 300,
                        "age-z": age_z,
                        "latency-z": 2,
                        "latency-s": 12,
                        "gas-usd": 0.003,
                    }
                )
    for config in configs:
        config["id"] = config_id(config)
    return configs


def build() -> None:
    subprocess.run(
        ["cargo", "build", "--release", "--example", "oracle_policy_eval"],
        cwd=SIM,
        check=True,
    )
    calibrated = subprocess.run(
        [str(BINARY), "--calibrate"],
        cwd=SIM,
        check=True,
        capture_output=True,
        text=True,
    )
    result = json.loads(calibrated.stdout)
    if not result.get("calibrated"):
        raise RuntimeError(f"evaluator calibration failed: {result}")


def invoke(task: tuple[dict, Path, str, dict]) -> dict:
    config, data, segment, scenario = task
    symbol = data.name.split("_30s_", 1)[0]
    flow_data = data.with_name(f"{symbol}_flows_30s_21d.csv")
    flow_source = "swaps" if flow_data.exists() else "neutral"
    command = [
        str(BINARY),
        "--data",
        str(data),
        "--segment",
        segment,
        "--timeframe-s",
        "30",
        "--min-fee-bp",
        str(scenario.get("min-fee-bp", 0.01)),
        "--tvl-usd",
        str(scenario.get("tvl-usd", 10_000_000)),
        "--daily-turnover",
        str(scenario.get("daily-turnover", 0.5)),
        "--flow-model",
        str(scenario.get("flow-model", "gross")),
        "--flow-sign",
        str(scenario.get("flow-sign", 1)),
        "--flow-source",
        flow_source,
        "--latency-s",
        str(scenario.get("latency-s", config.get("latency-s", 12))),
        "--inclusion-latency-s",
        str(scenario.get("inclusion-latency-s", 12)),
        "--min-disp-pbps",
        str(scenario.get("min-disp-pbps", 1_000)),
    ]
    if flow_source == "swaps":
        command.extend(("--flow-data", str(flow_data)))
    for key, value in config.items():
        if key != "id" and key not in scenario:
            command.extend((f"--{key}", str(value)))
    completed = subprocess.run(command, cwd=SIM, capture_output=True, text=True)
    if completed.returncode != 0:
        return {
            "config_id": config["id"],
            "config": config,
            "scenario": scenario["name"],
            "data": data.name,
            "error": completed.stderr[-2_000:],
            "physical_bounds": False,
        }
    record = json.loads(completed.stdout)
    record.update(
        {
            "config_id": config["id"],
            "config": config,
            "scenario": scenario["name"],
            "data": data.name,
        }
    )
    return record


def fitness(record: dict) -> float:
    if not record.get("physical_bounds", False):
        return -1e9
    return (
        record["net_after_gas_apr"]
        - 0.5 * max(0.0, record["lvr_apr"])
        - 0.10 * (1.0 - record["organic_fill_rate"])
        - 0.0001 * record["center_error_p95_bps"]
        - 0.05 * record["time_outside_band"]
        - max(0.0, record["coverage_max_dev"] - 0.25)
    )


def aggregate(records: list[dict], configs: list[dict], break_stage: bool = False) -> list[dict]:
    by_config: dict[str, list[dict]] = {}
    for record in records:
        by_config.setdefault(record["config_id"], []).append(record)
    config_by_id = {config["id"]: config for config in configs}
    output = []
    keys = (
        "net_after_gas_apr",
        "lvr_apr",
        "push_oev_apr",
        "pushes_per_day",
        "gas_usd_per_day",
        "organic_fill_rate",
        "organic_cost_bps",
        "user_cost_p95_bps",
        "spot_error_p95_bps",
        "center_error_p95_bps",
        "push_jump_p95_bps",
        "time_outside_band",
        "coverage_max_dev",
    )
    for identifier, group in by_config.items():
        valid = [record for record in group if record.get("physical_bounds", False)]
        summary = {
            "config_id": identifier,
            "config": config_by_id[identifier],
            "runs": len(group),
            "valid_runs": len(valid),
            "fitness_median": statistics.median(fitness(record) for record in group),
            "fitness_worst": min(fitness(record) for record in group),
        }
        for key in keys:
            values = [record[key] for record in valid if key in record]
            summary[f"{key}_median"] = statistics.median(values) if values else None
            if break_stage and values:
                summary[f"{key}_worst"] = (
                    max(values)
                    if key
                    in {
                        "lvr_apr",
                        "push_oev_apr",
                        "user_cost_p95_bps",
                        "spot_error_p95_bps",
                        "center_error_p95_bps",
                        "push_jump_p95_bps",
                        "time_outside_band",
                        "coverage_max_dev",
                        "gas_usd_per_day",
                    }
                    else min(values)
                )
        output.append(summary)
    rank_key = "fitness_worst" if break_stage else "fitness_median"
    return sorted(output, key=lambda item: item[rank_key], reverse=True)


def select_per_policy(summaries: list[dict], count: int) -> list[dict]:
    selected = []
    for policy in ("hard", "smooth", "offset", "adaptive"):
        matches = [item for item in summaries if item["config"]["policy"] == policy]
        selected.extend(item["config"] for item in matches[:count])
    return selected


def scenarios(stage: str) -> list[dict]:
    if stage != "break":
        return [{"name": "base"}]
    return [
        {"name": "base"},
        {"name": "net-flow", "flow-model": "net"},
        {"name": "reverse-flow", "flow-sign": -1},
        {"name": "fee-5bp", "min-fee-bp": 5},
        {"name": "fee-10bp", "min-fee-bp": 10},
        {"name": "tvl-1m", "tvl-usd": 1_000_000},
        {"name": "tvl-100m", "tvl-usd": 100_000_000},
        {"name": "turnover-10pct", "daily-turnover": 0.1},
        {"name": "turnover-100pct", "daily-turnover": 1.0},
        {"name": "wide-dispersion", "min-disp-pbps": 2_000},
        {"name": "latency-0s", "latency-s": 0, "inclusion-latency-s": 0},
        {"name": "latency-60s", "latency-s": 60, "inclusion-latency-s": 60},
    ]


def load_summary(stage: str) -> list[dict]:
    path = RESULTS / f"{stage}_summary.json"
    return json.loads(path.read_text())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", choices=("train", "test", "break", "holdout"), required=True)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--data-dir", type=Path, default=HERE / "data")
    parser.add_argument("--champion")
    args = parser.parse_args()

    build()
    RESULTS.mkdir(parents=True, exist_ok=True)
    all_data = sorted(
        path
        for path in args.data_dir.glob("*_30s_21d.csv")
        if "_flows_" not in path.name
    )
    if len(all_data) < 3:
        raise SystemExit(f"need at least three cached assets, found {len(all_data)}")
    core = [
        path
        for symbol in ("BTC-USDT", "ETH-USDT", "BNB-USDT")
        for path in all_data
        if path.name.startswith(symbol)
    ]
    full = all_data
    full_deck = deck()

    if args.stage == "train":
        configs = full_deck
        data = core
        segment = "train"
    elif args.stage == "test":
        configs = select_per_policy(load_summary("train"), 3)
        data = full
        segment = "test"
    elif args.stage == "break":
        configs = select_per_policy(load_summary("test"), 1)
        data = full
        segment = "test"
    else:
        break_summary = load_summary("break")
        champion_id = args.champion or break_summary[0]["config_id"]
        champion = next(
            item["config"] for item in break_summary if item["config_id"] == champion_id
        )
        baseline = next(
            config
            for config in full_deck
            if config["policy"] == "hard" and config["theta-bp"] == 10
        )
        configs = [champion] if champion["id"] == baseline["id"] else [champion, baseline]
        data = full
        segment = "holdout"

    tasks = [
        (config, path, segment, scenario)
        for config in configs
        for path in data
        for scenario in scenarios(args.stage)
    ]
    records: list[dict] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
        for index, record in enumerate(executor.map(invoke, tasks), start=1):
            records.append(record)
            if index % 20 == 0 or index == len(tasks):
                print(f"{args.stage}: {index}/{len(tasks)} runs", flush=True)

    raw_path = RESULTS / f"{args.stage}.jsonl"
    raw_path.write_text("".join(json.dumps(record, sort_keys=True) + "\n" for record in records))
    summaries = aggregate(
        records,
        configs,
        break_stage=args.stage in {"break", "holdout"},
    )
    summary_path = RESULTS / f"{args.stage}_summary.json"
    summary_path.write_text(json.dumps(summaries, indent=2, sort_keys=True) + "\n")
    print(json.dumps(summaries[:8], indent=2))


if __name__ == "__main__":
    main()
