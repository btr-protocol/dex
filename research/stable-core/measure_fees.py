# measure_fees.py — EMPIRICAL effective fee per pool via the half-spread (no nominal tier trusted).
# For pair (A,B), A<B: A->B swaps execute below fair (P<fair), B->A execute above (P>fair). Their
# medians straddle fair; half-spread = (P_ba - P_ab)/2 = effective fee+half-impact. Measure on SMALL
# trades (<$1k, impact~0) → the real fee the pool charges. Run: uv run --with polars python3 measure_fees.py
import polars as pl, glob, os, json
HERE = os.path.dirname(os.path.abspath(__file__))
OUR = {'USDT','USDC','USD1','USDe','USDE','FDUSD','TUSD','DAI'}
rows = []
for f in glob.glob(os.path.join(HERE,'data','*.parquet')):
    if os.path.getsize(f) < 1000: continue
    lbl = os.path.basename(f)[:-8]
    try: df = pl.read_parquet(f)
    except Exception: continue
    if df.height == 0 or 'amount_in' not in df.columns: continue
    df = df.filter((pl.col('amount_in')>0)&(pl.col('amount_out')>0)&(pl.col('amount_in')<5e7)
                   & pl.col('token_in').is_in(list(OUR)) & pl.col('token_out').is_in(list(OUR)))
    if df.height < 50: continue
    # normalized price P (B per A, A<B alphabetical); direction sign
    df = df.with_columns([
        pl.when(pl.col('token_in')<pl.col('token_out'))
          .then(pl.col('amount_out')/pl.col('amount_in'))            # A->B : exec = B/A = P (below fair)
          .otherwise(pl.col('amount_in')/pl.col('amount_out')).alias('P'),  # B->A : in/out = B/A = P (above fair)
        (pl.col('token_in')<pl.col('token_out')).alias('is_ab'),
        pl.col('amount_in').alias('usd'),
    ]).filter((pl.col('P')>0.9)&(pl.col('P')<1.11))
    small = df.filter(pl.col('usd') < 1000)
    if small.filter('is_ab').height < 20 or small.filter(pl.col('is_ab').not_()).height < 20:
        small = df  # fall back to all sizes if too few small
    p_ab = small.filter('is_ab')['P'].median()
    p_ba = small.filter(pl.col('is_ab').not_())['P'].median()
    if p_ab is None or p_ba is None: continue
    fair = (p_ab + p_ba)/2
    half_spread_bps = (p_ba - p_ab)/2 / fair * 1e4
    vol = df['usd'].sum()
    rows.append({'pool':lbl,'vol_usd':round(vol),'eff_fee_bps':round(half_spread_bps,4),
                 'fair':round(fair,6),'n':df.height})
rows.sort(key=lambda x:-x['vol_usd'])
print(f"{'pool':<28}{'vol$M':>8}{'eff_fee_bp':>11}{'nominal_guess':>14}")
NOM = {'_100':'1.0','_500':'5.0','_2500':'25.0'}
for r in rows:
    import re; m = re.search(r'_(\d+)$', r['pool']); nom = {'100':'1.0bp','500':'5.0bp','2500':'25bp'}.get(m.group(1) if m else '','?')
    print(f"{r['pool']:<28}{r['vol_usd']/1e6:>8.0f}{r['eff_fee_bps']:>11.3f}{nom:>14}")
json.dump(rows, open(os.path.join(HERE,'out','eff_fees.json'),'w'))
print("\nwrote out/eff_fees.json")
