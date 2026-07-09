"""Deployable vs-rebal from GROUND-TRUTH measured LVR (no σ-model).

Reads a pool's re-pulled daily series (f0_apr + real_lvr_apr, the measure-from-swaps
LVR) and computes net-vs-rebal = fee − real_LVR, both always-on and causal-gated
(deploy only when the forecast fee ≥ forecast LVR). This is the honest deployable
hedged-MM edge with the audited LVR — no frictionless overstatement, no Parkinson.

Usage: python analyze_lvr.py <label> <lvr_jsonl> [<label2> <jsonl2> ...]
"""
import json
import sys
import statistics as st


def trailing_mean(xs, i, w):
    lo = max(0, i - w)
    return sum(xs[lo:i]) / (i - lo) if i > lo else xs[i]


def analyze(label, path):
    rows = [json.loads(l) for l in open(path) if l.strip()]
    rows.sort(key=lambda r: r["date"])
    f0 = [r["f0_apr"] for r in rows]
    lvr = [max(r.get("real_lvr_apr", 0.0), 0.0) for r in rows]  # realized LVR ≥ 0
    n = len(rows)
    # always-on net vs-rebal (CE=1, ±5% ref): mean daily (fee − LVR)
    always = st.mean([f0[i] - lvr[i] for i in range(n)])
    # causal gate: deploy day i iff forecast fee ≥ forecast LVR (7d trailing, no look-ahead)
    dep, gated_sum = 0, 0.0
    for i in range(n):
        f_fc = trailing_mean(f0, i, 7)
        l_fc = trailing_mean(lvr, i, 7)
        if f_fc >= l_fc:           # decide on forecast
            dep += 1
            gated_sum += f0[i] - lvr[i]   # earn realized
    gated = gated_sum / n          # annualized (neutral days contribute 0)
    print(f"\n=== {label} ({n} days) — GROUND-TRUTH (measured-LVR) vs-rebal ===")
    print(f"  real f0:  mean {st.mean(f0):.2f}  median {st.median(f0):.2f}")
    print(f"  real LVR: mean {st.mean(lvr):.2f}  median {st.median(lvr):.2f}  (measure-from-swaps)")
    print(f"  net vs-rebal (CE=1):  always-on {always*100:+.1f}%   causal-gated {gated*100:+.1f}%  (deployed {dep/n*100:.0f}%)")
    print(f"  ⇒ {'DEPLOYABLE (+)' if always > 0 else 'marginal'} as hedged-MM (before hedge cost + dilution)")
    return always, gated


if __name__ == "__main__":
    a = sys.argv[1:]
    for i in range(0, len(a) - 1, 2):
        analyze(a[i], a[i + 1])
