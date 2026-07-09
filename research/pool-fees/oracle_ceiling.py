"""Oracle-ceiling + net/fee analysis for a dual-leg-marked pool CSV.

Reads a *_marked.csv (date,net_usd,fee_usd,arb_lvr_usd,swaps,v_active_usd,...)
and computes:
  Sigma fee, Sigma arb-LVR, net/fee%  (always-on vs-rebal)
  ORACLE-CEILING %vs-rebal = annualized  Sum_{days: fee_d > lvr_d} (fee_d - lvr_d)
                              expressed as % of position (mean v_active_usd).
    = the best a perfect in/out day gate could earn vs the constant-mix rebalancer.

Also writes the model-input 4-col data/fees/<label>_lvr.csv:
  date_secs,f0_apr,real_lvr_apr,v_active_usd   (f0_apr = fee*365/V, lvr*365/V)

Usage: python oracle_ceiling.py <label> <marked.csv> [<out_lvr.csv>]
"""
import sys, csv, statistics as st
from pathlib import Path


def analyze(label, marked_csv, out_lvr=None):
    rows = list(csv.DictReader(open(marked_csv)))
    rows = [r for r in rows if float(r["v_active_usd"]) > 0]
    rows.sort(key=lambda r: int(r["date"]))
    n = len(rows)
    fee = [float(r["fee_usd"]) for r in rows]
    lvr = [float(r["arb_lvr_usd"]) for r in rows]
    net = [float(r["net_usd"]) for r in rows]
    vact = [float(r["v_active_usd"]) for r in rows]
    swaps = sum(int(r["swaps"]) for r in rows)

    Sfee, Slvr, Snet = sum(fee), sum(lvr), sum(net)
    net_fee_pct = Snet / Sfee * 100 if Sfee else 0.0
    years = (int(rows[-1]["date"]) - int(rows[0]["date"])) / (365.25 * 86400)
    years = max(years, 1e-9)
    mean_v = st.mean(vact)

    # always-on vs-rebal as % of position, annualized
    always_pct = (Snet / mean_v) / years * 100

    # ORACLE CEILING: keep only days where realized fee_d > lvr_d
    oracle_usd = sum(fee[i] - lvr[i] for i in range(n) if fee[i] > lvr[i])
    oracle_pct = (oracle_usd / mean_v) / years * 100
    dep_days = sum(1 for i in range(n) if fee[i] > lvr[i])

    # per-day net as % of that day's V (for distribution intuition)
    f0_apr = [fee[i] / vact[i] * 365 for i in range(n)]
    lvr_apr = [lvr[i] / vact[i] * 365 for i in range(n)]

    print(f"\n=== {label} ({n} days, {years:.2f}y, {swaps:,} swaps) ===")
    print(f"  Sigma fee      ${Sfee/1e6:8.3f}M")
    print(f"  Sigma arb-LVR  ${Slvr/1e6:8.3f}M")
    print(f"  Sigma net      ${Snet/1e6:+8.3f}M")
    print(f"  mean V_active  ${mean_v/1e6:8.3f}M")
    print(f"  net/fee%             {net_fee_pct:+7.1f}%")
    print(f"  always-on  %vs-rebal {always_pct:+7.2f}%/yr")
    print(f"  ORACLE-CEIL %vs-rebal {oracle_pct:+7.2f}%/yr  (deploy {dep_days}/{n}={dep_days/n*100:.0f}% of days)")
    print(f"  f0_apr  mean {st.mean(f0_apr):.3f} median {st.median(f0_apr):.3f}")
    print(f"  lvr_apr mean {st.mean(lvr_apr):.3f} median {st.median(lvr_apr):.3f}")
    print(f"  ROW| {label} | fee | {n} | ${Sfee/1e6:.2f}M | ${Slvr/1e6:.2f}M | {net_fee_pct:+.0f}% | oracle {oracle_pct:+.1f}%")

    if out_lvr:
        Path(out_lvr).parent.mkdir(parents=True, exist_ok=True)
        with open(out_lvr, "w") as o:
            o.write("date_secs,f0_apr,real_lvr_apr,v_active_usd\n")
            for i in range(n):
                o.write(f"{rows[i]['date']},{f0_apr[i]:.6f},{lvr_apr[i]:.6f},{vact[i]:.1f}\n")
        print(f"  -> wrote {out_lvr}")
    return dict(label=label, n=n, Sfee=Sfee, Slvr=Slvr, net_fee_pct=net_fee_pct,
                oracle_pct=oracle_pct, always_pct=always_pct)


if __name__ == "__main__":
    a = sys.argv[1:]
    analyze(*a)
