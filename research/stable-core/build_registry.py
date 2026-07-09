"""Assemble stable-pools.json from probe/sweep outputs + API metadata gathered 2026-07-07.
Run: python3 build_registry.py <scratchpad_dir>"""
import json, sys
from pathlib import Path

SCRATCH = Path(sys.argv[1])
HERE = Path(__file__).parent

# ---- per-address 14d-window swap counts from probes.json (family-confirming topic0s) ----
probe_counts = {}
probe_topics = {}
for line in (SCRATCH / "probes.json").read_text().splitlines():
    line = line.strip()
    if not line.startswith('{"address"'):
        continue
    d = json.loads(line)
    probe_topics[d["address"]] = d["topics"]

SWAP_FAMS = {"univ3", "pcsv3", "curve_i128", "curve_u256", "solidly_v2", "wombat", "dodo", "univ4", "pcs_infi"}


def swap_count(addr):
    t = probe_topics.get(addr.lower(), {})
    return sum(v["n"] for v in t.values() if v["fam"] in SWAP_FAMS)


def dom_family(addr):
    t = probe_topics.get(addr.lower(), {})
    best, n = None, -1
    for _, v in t.items():
        if v["fam"] in SWAP_FAMS and v["n"] > n:
            best, n = v["fam"], v["n"]
    return best


# ---- singleton (univ4 / pcs-infinity) poolId counts from sweep_v4.json ----
v4 = {}   # (manager, poolId) -> n
managers = {}
for line in (SCRATCH / "sweep_v4.json").read_text().splitlines():
    line = line.strip()
    if not line.startswith('{"family"'):
        continue
    d = json.loads(line)
    if d.get("family") not in ("univ4", "pcs_infi"):
        continue
    for t in d["top"]:
        v4[(d["family"], t["topic1"])] = {"manager": t["address"], "n": t["n"]}
        managers.setdefault(d["family"], {})
        managers[d["family"]][t["address"]] = managers[d["family"]].get(t["address"], 0) + t["n"]

WINDOW_BLOCKS = 2_688_000          # probe lookback: 14d at 0.45s
WINDOW_DAYS = 14
V4_WINDOW_DAYS = 3                 # singleton sweep lookback

registry = json.loads((HERE / "registry_base.json").read_text())
for p in registry["pools"]:
    fam = p["family"]
    if fam in ("univ4", "pcs-infinity-cl"):
        key = ("univ4" if fam == "univ4" else "pcs_infi", p["pool_id"])
        hit = v4.get(key)
        if hit:
            p["address"] = hit["manager"]
            p[f"swaps_{V4_WINDOW_DAYS}d"] = hit["n"]
            p["verified"] = True
        else:
            p[f"swaps_{V4_WINDOW_DAYS}d"] = 0
            p["verified"] = False
    else:
        n = swap_count(p["address"])
        p[f"swaps_{WINDOW_DAYS}d"] = n
        p["verified"] = n > 0
        df = dom_family(p["address"])
        if df:
            p["observed_topic_family"] = df

registry["_probe_window"] = {"pool_probe_days": WINDOW_DAYS, "pool_probe_blocks": WINDOW_BLOCKS, "singleton_sweep_days": V4_WINDOW_DAYS}
(HERE / "stable-pools.json").write_text(json.dumps(registry, indent=1))
print(json.dumps([{ "label": p["label"], "swaps": p.get(f"swaps_{WINDOW_DAYS}d", p.get(f"swaps_{V4_WINDOW_DAYS}d")),
                    "verified": p["verified"], "obs": p.get("observed_topic_family")} for p in registry["pools"]], indent=1))
