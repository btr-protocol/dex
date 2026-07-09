"""Regenerate data/fees/{label}_lvr.csv from an EXACT-V marked CSV.

The 4-col series consumed by the Rust ALM (crates/ml/src/alm.rs::load_fee_series):
  date_secs, f0_apr, real_lvr_apr, v_active_usd
where (matching wait_mark.sh's original derivation, now with EXACT V):
  f0_apr       = fee_usd     / V_active * 365   (undiluted active-range fee APR)
  real_lvr_apr = arb_lvr_usd / V_active * 365   (undiluted active-range arb-LVR APR)
BOTH are V_active-normalized → recomputed consistently with the exact V_active so
the fee/LVR economics keep correct units (the dilution f0·V/(V+D) then uses the
same exact V).  Rows with V<=0 are skipped (same as the original).

Usage: regen_lvr.py <exact_marked.csv> <out_lvr.csv>
"""
import sys, csv

_, src, out = sys.argv
rows = list(csv.DictReader(open(src)))
n = 0
with open(out, "w") as o:
    o.write("date_secs,f0_apr,real_lvr_apr,v_active_usd\n")
    for r in rows:
        v = float(r["v_active_usd"])
        if v <= 0:
            continue
        f0 = float(r["fee_usd"]) / v * 365
        lvr = float(r["arb_lvr_usd"]) / v * 365
        o.write(f"{r['date']},{f0:.6f},{lvr:.6f},{v:.1f}\n")
        n += 1
print(f"DONE: {n} rows → {out}")
