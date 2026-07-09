"""Microstructure analysis of the BSC stable-pool tape (stable-core study).

Reads data/<label>.parquet (ts_ms, token_in, token_out, amount_in, amount_out —
human units, all stables ≈ $1) + stable-pools.json registry. Per venue / pair /
venue×pair over the tape window:
  volume (total, daily, 30d), swap count, trade-size dist (p50/p90/p99 +
  $1/10/100/1k/10k/100k/1M histogram), effective exec px (out/in oriented to
  common quote = alphabetically-later token), and per size-bucket EFFECTIVE COST
  in bps vs the contemporaneous cross-venue volume-weighted mid (trailing 10min
  VW mean of ALL venues' exec prices, strictly-before-ts so the trade and its
  block never price themselves; fallback 1h → 24h → pair-global VW mean).
  Cost = fee + slippage actually paid: buy base → (px/mid−1)e4, sell → (1−px/mid)e4.
TVL: eth_call ERC20 balanceOf(pool) now (discrete pools); registry GT snapshot
for singleton-manager (univ4/pcs-infinity) + asset-wrapper (wombat) venues.
Utilization = daily vol / TVL. Outputs out/micro_summary.json + out/micro_report.md.

Run: uv run --with pyarrow --with pandas --with numpy python analyze_micro.py
"""
import itertools
import json
import sys
import urllib.request
from pathlib import Path

import numpy as np
import pandas as pd
import pyarrow.parquet as pq

HERE = Path(__file__).parent
DATA = HERE / "data"
OUT = HERE / "out"
OUT.mkdir(exist_ok=True)
REG = json.loads((HERE / "stable-pools.json").read_text())
POOLS = {p["label"]: p for p in REG["pools"]}

LABELS = list(POOLS)
VENUES = sorted({p["venue"] for p in POOLS.values()})
PAIRS = sorted({"/".join(sorted(c)) for p in POOLS.values()
                for c in itertools.combinations(p["tokens"], 2)})
L_CODE = {x: i for i, x in enumerate(LABELS)}
V_CODE = {x: i for i, x in enumerate(VENUES)}
P_CODE = {x: i for i, x in enumerate(PAIRS)}

EDGES = np.array([0, 1, 10, 100, 1e3, 1e4, 1e5, 1e6, np.inf])
BUCKETS = ["<$1", "$1-10", "$10-100", "$100-1k", "$1k-10k", "$10k-100k", "$100k-1M", ">$1M"]
SNAPSHOT_TVL_FAMS = {"univ4", "pcs-infinity-cl", "wombat"}  # commingled / asset-wrapper balances
RPCS = ["https://bsc-dataseed.binance.org", "https://bsc-dataseed1.defibit.io",
        "https://rpc.ankr.com/bsc", "https://binance.llamarpc.com"]
DAY_MS = 86_400_000


def load_label(label):
    f = DATA / f"{label}.parquet"
    if not f.exists():
        return None
    try:
        t = pq.read_table(f)
    except Exception as e:  # partial/corrupt write
        print(f"  skip {label}: unreadable ({e})", file=sys.stderr)
        return None
    if t.num_rows == 0:
        return None
    ts = t["ts_ms"].to_numpy()
    tin = t["token_in"].to_numpy(zero_copy_only=False)
    tout = t["token_out"].to_numpy(zero_copy_only=False)
    ain = t["amount_in"].to_numpy()
    aout = t["amount_out"].to_numpy()
    base = np.minimum(tin, tout)  # alphabetical: base = earlier symbol
    sell = tin == base            # trader sells base for quote
    with np.errstate(divide="ignore", invalid="ignore"):
        px = np.where(sell, aout / ain, ain / aout)  # quote per base
    ok = (ain > 1e-9) & (aout > 1e-9) & (px > 0.5) & (px < 2.0) & (ts > 0)
    n = int(ok.sum())
    if n == 0:
        return None
    toks = POOLS[label]["tokens"]
    if len(toks) == 2:  # constant pair
        pair_c = np.full(n, P_CODE["/".join(sorted(toks))], np.int16)
    else:               # multi-asset pool: per-row pair
        keys = pd.Series(base[ok]).str.cat(np.maximum(tin, tout)[ok], sep="/")
        pair_c = keys.map(P_CODE).to_numpy(np.int16)
    return pd.DataFrame({
        "ts": ts[ok], "pair_c": pair_c, "sell": sell[ok],
        "size": ain[ok],  # USD ≈ token units (all stables ≈ $1)
        "px": px[ok],
        "label_c": np.full(n, L_CODE[label], np.int16),
        "venue_c": np.full(n, V_CODE[POOLS[label]["venue"]], np.int16),
    })


def rolling_vw_mid(ts, px, vol):
    """Trailing VW mean of exec px, strictly before each trade's ts (same-block
    trades excluded → no self/bundle pricing). 10min → 1h → 24h → global."""
    cs_v = np.concatenate(([0.0], np.cumsum(vol)))
    cs_pv = np.concatenate(([0.0], np.cumsum(px * vol)))
    hi = np.searchsorted(ts, ts, "left")

    def win(w_ms, min_v, min_n):
        lo = np.searchsorted(ts, ts - w_ms, "left")
        v = cs_v[hi] - cs_v[lo]
        n = hi - lo
        with np.errstate(divide="ignore", invalid="ignore"):
            m = (cs_pv[hi] - cs_pv[lo]) / v
        return np.where((v >= min_v) & (n >= min_n), m, np.nan)

    mid = win(600e3, 500.0, 5)
    for w, mv, mn in ((3600e3, 100.0, 3), (86400e3, 0.0, 1)):
        nan = np.isnan(mid)
        if not nan.any():
            break
        mid[nan] = win(w, mv, mn)[nan]
    g = cs_pv[-1] / max(cs_v[-1], 1e-12)
    mid[np.isnan(mid)] = g
    return mid


def agg(pos, A, days, days30_cut):
    """Metrics for row positions pos over column arrays A."""
    size, cost = A["size"][pos], A["cost"][pos]
    sell, px, ts = A["sell"][pos], A["px"][pos], A["ts"][pos]
    vol = float(size.sum())
    b = np.digitize(size, EDGES[1:-1])  # 0..7
    hist = []
    for i, name in enumerate(BUCKETS):
        m = b == i
        nb = int(m.sum())
        bv = float(size[m].sum())
        hist.append({
            "bucket": name, "n": nb, "vol_usd": round(bv, 2),
            "vol_share": round(bv / vol, 4) if vol else 0,
            "cost_bps_vw": round(float((cost[m] * size[m]).sum() / bv), 3) if bv else None,
            "cost_bps_med": round(float(np.median(cost[m])), 3) if nb else None,
        })
    v30 = float(size[ts >= days30_cut].sum())

    def vw_px(side):
        m = sell == side
        v = size[m]
        return round(float((px[m] * v).sum() / v.sum()), 6) if v.sum() > 0 else None

    return {
        "swaps": int(len(pos)),
        "vol_usd": round(vol, 0),
        "vol_daily_usd": round(vol / days, 0),
        "vol_30d_usd": round(v30, 0),
        "vol_30d_daily_usd": round(v30 / 30, 0),
        "size_p50": round(float(np.percentile(size, 50)), 2),
        "size_p90": round(float(np.percentile(size, 90)), 2),
        "size_p99": round(float(np.percentile(size, 99)), 2),
        "cost_bps_vw": round(float((cost * size).sum() / vol), 3) if vol else None,
        "cost_bps_med": round(float(np.median(cost)), 3),
        "px_vw_sell": vw_px(True),
        "px_vw_buy": vw_px(False),
        "buckets": hist,
    }


# ── TVL via eth_call ──
def eth_call(to, data):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_call",
                       "params": [{"to": to, "data": data}, "latest"]}).encode()
    for rpc in RPCS:
        try:
            req = urllib.request.Request(rpc, body, {"Content-Type": "application/json"})
            r = json.loads(urllib.request.urlopen(req, timeout=10).read())
            if "result" in r and r["result"] not in (None, "0x"):
                return int(r["result"], 16)
        except Exception:
            continue
    return None


def pool_tvl(pool):
    if pool["family"] in SNAPSHOT_TVL_FAMS:
        return pool["tvl_usd"], "registry_snapshot"
    total = 0.0
    for sym in pool["tokens"]:
        tk = REG["tokens"][sym]
        bal = eth_call(tk["address"], "0x70a08231" + pool["address"][2:].lower().rjust(64, "0"))
        if bal is None:
            return pool["tvl_usd"], "registry_snapshot(rpc_fail)"
        total += bal / 10 ** tk["decimals"]
    return round(total, 0), "eth_call"


def main():
    frames, missing = [], []
    for label in POOLS:
        df = load_label(label)
        (frames.append(df) if df is not None else missing.append(label))
    if not frames:
        sys.exit("no tape in data/")
    all_df = pd.concat(frames, ignore_index=True)
    del frames
    all_df.sort_values("ts", inplace=True, kind="stable", ignore_index=True)
    print(f"{len(all_df):,} trades loaded", flush=True)

    t0, t1 = int(all_df["ts"].iloc[0]), int(all_df["ts"].iloc[-1])
    days = (t1 - t0) / DAY_MS
    days30_cut = t1 - 30 * DAY_MS

    A = {c: all_df[c].to_numpy() for c in ("ts", "sell", "size", "px")}
    A["ts"] = A["ts"].astype(float)

    # truth mid per pair from ALL venues → per-trade effective cost
    cost = np.zeros(len(all_df))
    pair_groups = all_df.groupby("pair_c", sort=False).indices
    for pc, pos in pair_groups.items():
        mid = rolling_vw_mid(A["ts"][pos], A["px"][pos], A["size"][pos])
        dev = (A["px"][pos] / mid - 1) * 1e4
        cost[pos] = np.where(A["sell"][pos], -dev, dev)
    A["cost"] = cost

    # TVL
    tvl_by_label = {}
    for label in POOLS:
        if label in missing:
            continue
        tvl, src = pool_tvl(POOLS[label])
        tvl_by_label[label] = {"tvl_usd": tvl, "source": src}

    summary = {
        "window": {"from_ts_ms": t0, "to_ts_ms": t1, "days": round(days, 1)},
        "pools_analyzed": len(POOLS) - len(missing), "pools_missing": missing,
        "method": {
            "mid": "rolling trailing VW mean of all-venue exec px, strictly pre-trade-ts; "
                   "10min(≥$500,≥5 trades)→1h(≥$100,≥3)→24h(≥1)→pair-global",
            "cost_bps": "buy base:(px/mid-1)e4, sell base:(1-px/mid)e4 = fee+slippage paid",
            "volume": "USD, all stables treated as $1 (amount_in)",
            "sanity_filter": "amounts>1e-9, 0.5<px<2.0",
        },
        "venues": {}, "pairs": {}, "venue_pools": {},
    }

    for vc, pos in all_df.groupby("venue_c", sort=False).indices.items():
        venue = VENUES[vc]
        a = agg(pos, A, days, days30_cut)
        labels = [lb for lb, p in POOLS.items() if p["venue"] == venue and lb not in missing]
        tvl = sum(tvl_by_label[lb]["tvl_usd"] for lb in labels)
        a["tvl_usd"] = round(tvl, 0)
        a["tvl_sources"] = {lb: tvl_by_label[lb]["source"] for lb in labels}
        a["util_6mo"] = round(a["vol_daily_usd"] / tvl, 3) if tvl else None
        a["util_30d"] = round(a["vol_30d_daily_usd"] / tvl, 3) if tvl else None
        summary["venues"][venue] = a
    for pc, pos in pair_groups.items():
        a = agg(pos, A, days, days30_cut)
        a["venues_active"] = sorted({VENUES[v] for v in
                                     np.unique(all_df["venue_c"].to_numpy()[pos])})
        summary["pairs"][PAIRS[pc]] = a
    for lc, pos in all_df.groupby("label_c", sort=False).indices.items():
        label = LABELS[lc]
        p = POOLS[label]
        a = agg(pos, A, days, days30_cut)
        a.update(venue=p["venue"],
                 pair="/".join(sorted(p["tokens"])) if len(p["tokens"]) == 2 else "multi",
                 fee_bps=p["fee_bps"], tvl_usd=tvl_by_label[label]["tvl_usd"],
                 tvl_source=tvl_by_label[label]["source"])
        a["util_30d"] = round(a["vol_30d_daily_usd"] / a["tvl_usd"], 3) if a["tvl_usd"] else None
        summary["venue_pools"][label] = a

    (OUT / "micro_summary.json").write_text(json.dumps(summary, indent=1))
    write_report(summary)
    print(f"OK {len(all_df):,} trades, {days:.0f}d, {len(summary['venues'])} venues → out/")


def _fmt(v, d=0):
    return "-" if v is None else (f"{v:,.{d}f}")


def write_report(s):
    L = ["# BSC stable-pool microstructure — 6mo tape",
         f"\nWindow: {pd.Timestamp(s['window']['from_ts_ms'], unit='ms', tz='UTC'):%Y-%m-%d} → "
         f"{pd.Timestamp(s['window']['to_ts_ms'], unit='ms', tz='UTC'):%Y-%m-%d} "
         f"({s['window']['days']}d) · pools: {s['pools_analyzed']} analyzed"
         + (f", missing: {', '.join(s['pools_missing'])}" if s["pools_missing"] else "") + "\n",
         "Truth px = " + s["method"]["mid"] + ". Cost = " + s["method"]["cost_bps"] + ".\n"]

    L.append("## Venue ranking (6mo stable volume)\n")
    L.append("| # | venue | 6mo vol $ | daily $ | 30d daily $ | swaps | TVL $ | util 30d | "
             "vw cost bps | med cost bps | size p50/p90/p99 $ |")
    L.append("|--:|---|--:|--:|--:|--:|--:|--:|--:|--:|---|")
    rank = sorted(s["venues"].items(), key=lambda kv: -kv[1]["vol_usd"])
    for i, (v, a) in enumerate(rank, 1):
        L.append(f"| {i} | {v} | {_fmt(a['vol_usd'])} | {_fmt(a['vol_daily_usd'])} | "
                 f"{_fmt(a['vol_30d_daily_usd'])} | {a['swaps']:,} | {_fmt(a['tvl_usd'])} | "
                 f"{_fmt(a['util_30d'], 2)}x | {_fmt(a['cost_bps_vw'], 2)} | {_fmt(a['cost_bps_med'], 2)} | "
                 f"{_fmt(a['size_p50'])}/{_fmt(a['size_p90'])}/{_fmt(a['size_p99'])} |")

    L.append("\n## Effective cost (bps, VW mean) per venue × size bucket\n")
    L.append("| venue | " + " | ".join(BUCKETS) + " |")
    L.append("|---|" + "--:|" * len(BUCKETS))
    for v, a in rank:
        cells = [("-" if b["cost_bps_vw"] is None else f"{b['cost_bps_vw']:.2f}") for b in a["buckets"]]
        L.append(f"| {v} | " + " | ".join(cells) + " |")
    L.append("\n(bucket swap counts + volume shares in micro_summary.json)")

    L.append("\n## Pairs\n")
    L.append("| pair | 6mo vol $ | daily $ | swaps | vw cost bps | med bps | venues |")
    L.append("|---|--:|--:|--:|--:|--:|---|")
    for p, a in sorted(s["pairs"].items(), key=lambda kv: -kv[1]["vol_usd"]):
        L.append(f"| {p} | {_fmt(a['vol_usd'])} | {_fmt(a['vol_daily_usd'])} | {a['swaps']:,} | "
                 f"{_fmt(a['cost_bps_vw'], 2)} | {_fmt(a['cost_bps_med'], 2)} | "
                 f"{len(a['venues_active'])}: {', '.join(a['venues_active'])} |")

    L.append("\n## Pool detail (venue × pair)\n")
    L.append("| pool | pair | fee bps | 6mo vol $ | 30d daily $ | swaps | TVL $ (src) | util 30d | "
             "vw cost bps | px vw sell/buy |")
    L.append("|---|---|--:|--:|--:|--:|---|--:|--:|---|")
    for lb, a in sorted(s["venue_pools"].items(), key=lambda kv: -kv[1]["vol_usd"]):
        L.append(f"| {lb} | {a['pair']} | {a['fee_bps']} | {_fmt(a['vol_usd'])} | "
                 f"{_fmt(a['vol_30d_daily_usd'])} | {a['swaps']:,} | "
                 f"{_fmt(a['tvl_usd'])} ({a['tvl_source']}) | {_fmt(a['util_30d'], 2)}x | "
                 f"{_fmt(a['cost_bps_vw'], 2)} | {_fmt(a['px_vw_sell'], 6)}/{_fmt(a['px_vw_buy'], 6)} |")

    L.append("\n## Caveats\n"
             "- Mid = trailing VW of trade prints (both sides) → centers between effective bid/ask; "
             "one-sided flow bursts bias it toward the heavy side (sub-bp for majors).\n"
             "- Singleton-manager (uni-v4 / PCS-Infinity) + wombat TVL = registry GT/llama snapshot, "
             "not eth_call (commingled/wrapper balances).\n"
             "- Volume = amount_in with every stable at $1; depegs (BUSD wind-down, TUSD) not re-marked.\n"
             "- Costs are venue-realized: includes fee + slippage + any same-block price impact "
             "already in the pool, but NOT gas.\n")
    (OUT / "micro_report.md").write_text("\n".join(L))


if __name__ == "__main__":
    main()
