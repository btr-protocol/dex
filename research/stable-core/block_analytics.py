# block_analytics.py — per-block cross-pool microstructure over ALL pulled BSC stable pools.
# For each pool & block: volume, #swaps, VWAP execution price, avg trade size, fee tier, and realized
# slippage vs the cross-pool volume-weighted mid (the "truth" price at that block). Then attributes,
# per block & per pair, WHERE the volume went and WHY (fee + slippage cost ranking across venues).
# Focus assets: USD1, USDC, USDT. Emits out/block_analytics.json for the chart report. Local only.
# Run: uv run --with polars python3 block_analytics.py
import polars as pl, glob, os, json, re, math

HERE = os.path.dirname(os.path.abspath(__file__))
REG = json.load(open(os.path.join(HERE, 'stable-pools.json')))
LABEL2META = {}
for p in REG['pools']:
    lbl = p['label']
    m = re.search(r'_(\d{2,4})$', lbl)                       # fee tier from label suffix (100=1bp,500=5bp,2500=25bp)
    fee_bps = (int(m.group(1)) / 100) if m else None         # PCS/Uni tier is in pips-of-% → /100 = bps? 100 tier=0.01%=1bp
    fee_bps = {100:1.0, 500:5.0, 2500:25.0, 3000:30.0, 10000:100.0, 1:0.5, 3:3.0}.get(int(m.group(1)) if m else 0, fee_bps)
    parts = lbl.split('_')
    venue = parts[0]
    pair = f"{parts[1]}/{parts[2]}" if len(parts) >= 3 else lbl
    LABEL2META[lbl] = {'venue': venue, 'pair': pair, 'family': p.get('family'), 'fee_bps': fee_bps or 1.0}

FOCUS = {'USD1', 'USDC', 'USDT'}
STABLES = {'USDT', 'USDC', 'USD1', 'FDUSD', 'USDe', 'USDE', 'TUSD', 'DAI', 'BUSD'}
# override nominal tiers with MEASURED effective fees (half-spread) where available
try:
    EFF = {r['pool']: max(r['eff_fee_bps'], 0.0) for r in json.load(open(os.path.join(HERE, 'out', 'eff_fees.json')))}
except Exception:
    EFF = {}
for lbl, meta in list(LABEL2META.items()):
    if lbl in EFF: meta['fee_bps'] = EFF[lbl]
files = [f for f in glob.glob(os.path.join(HERE, 'data', '*.parquet')) if os.path.getsize(f) > 1000]

# ── load every pool, tag with label/pair/venue/fee, price each swap ──
frames = []
for f in files:
    lbl = os.path.basename(f)[:-8]
    meta = LABEL2META.get(lbl)
    if not meta:  # fall back: parse label
        parts = lbl.split('_'); meta = {'venue': parts[0], 'pair': f"{parts[1]}/{parts[2]}" if len(parts)>=3 else lbl, 'fee_bps': 1.0, 'family': None}
    try:
        df = pl.read_parquet(f)
    except Exception:
        continue
    if df.height == 0 or 'amount_in' not in df.columns:
        continue
    df = df.filter((pl.col('amount_in') > 0) & (pl.col('amount_out') > 0) & (pl.col('amount_in') < 5e7)).with_columns([
        pl.lit(lbl).alias('pool'), pl.lit(meta['pair']).alias('pair'), pl.lit(meta['venue']).alias('venue'),
        pl.lit(float(meta['fee_bps'])).alias('fee_bps'),
        (pl.col('amount_in')).alias('usd'),                                   # stable ~ $1
        (pl.col('amount_out') / pl.col('amount_in')).alias('exec_px'),        # realized out-per-in
        (pl.col('ts_ms') // 1000).alias('blk_ts'),                            # block-second proxy (one ts per block)
    ])
    frames.append(df.select(['blk_ts','ts_ms','pool','pair','venue','fee_bps','token_in','token_out','usd','exec_px']))

if not frames:
    print('no parquets yet — pull still running?'); raise SystemExit
A = pl.concat(frames, how='vertical_relaxed')
# keep only stable-stable swaps with a sane per-$1 execution price (drops decode-error prints like
# Thena's unresolved token @198bp and dust-pool junk; still admits real depegs to ~±12%, e.g. USDe/FDUSD)
A = A.filter(
    pl.col('token_in').is_in(list(STABLES)) & pl.col('token_out').is_in(list(STABLES))
    & (pl.col('exec_px') > 0.88) & (pl.col('exec_px') < 1.13)
)
print(f"loaded {A.height:,} stable-stable swaps across {A['pool'].n_unique()} pools, {A['pair'].n_unique()} pairs")

# ── canonical pair key (orderless) so USDT/USDC and USDC/USDT merge; direction via token_in ──
def canon(a, b): return '/'.join(sorted([a, b]))
A = A.with_columns(pl.struct(['token_in','token_out']).map_elements(lambda s: canon(s['token_in'], s['token_out']), return_dtype=pl.String).alias('cpair'))

# ── cross-pool per-block VWAP mid per canonical pair = the "truth" price; slippage = exec vs mid ──
# normalize exec price to a canonical direction (price of first-alpha token in second): use token_in<token_out sign
A = A.with_columns([
    pl.when(pl.col('token_in') < pl.col('token_out')).then(pl.col('exec_px')).otherwise(1.0/pl.col('exec_px')).alias('px_norm'),
])
mid = A.group_by(['cpair','blk_ts']).agg([
    ((pl.col('px_norm')*pl.col('usd')).sum()/pl.col('usd').sum()).alias('mid'),
]).select(['cpair','blk_ts','mid'])
A = A.join(mid, on=['cpair','blk_ts'], how='left').with_columns([
    ((pl.col('px_norm')/pl.col('mid') - 1.0).abs()*1e4).alias('slip_bps'),      # |exec - mid|/mid in bps
    (pl.col('fee_bps') + (pl.col('px_norm')/pl.col('mid') - 1.0).abs()*1e4).alias('allin_bps'),
])

out = {'generated_over_swaps': A.height, 'pools': A['pool'].n_unique(), 'focus': sorted(FOCUS)}

# ── per-pool summary (the headline table) ──
pool_sum = A.group_by(['pool','pair','venue']).agg([
    pl.col('usd').sum().alias('vol_usd'), pl.len().alias('swaps'),
    (pl.col('ts_ms').max()-pl.col('ts_ms').min()).alias('span_ms'),
    pl.col('usd').median().alias('sz_p50'), pl.col('usd').quantile(0.9).alias('sz_p90'), pl.col('usd').quantile(0.99).alias('sz_p99'),
    pl.col('fee_bps').first().alias('fee_bps'),
    ((pl.col('slip_bps')*pl.col('usd')).sum()/pl.col('usd').sum()).alias('slip_bps_vw'),
    ((pl.col('allin_bps')*pl.col('usd')).sum()/pl.col('usd').sum()).alias('allin_bps_vw'),
]).sort('vol_usd', descending=True)
out['per_pool'] = [{**r, 'vol_usd': round(r['vol_usd'],0), 'days': round(r['span_ms']/86400000,1),
    'sz_p50': round(r['sz_p50'] or 0,1),'sz_p90': round(r['sz_p90'] or 0,1),'sz_p99': round(r['sz_p99'] or 0,1),
    'slip_bps_vw': round(r['slip_bps_vw'] or 0,3),'allin_bps_vw': round(r['allin_bps_vw'] or 0,3)} for r in pool_sum.to_dicts()]

# ── per canonical-pair: total vol + venue split ("where did volume go") + cost by venue ("why") ──
pair_venue = A.group_by(['cpair','venue']).agg([pl.col('usd').sum().alias('vol'), pl.len().alias('n'),
    ((pl.col('allin_bps')*pl.col('usd')).sum()/pl.col('usd').sum()).alias('allin_vw')]).sort(['cpair','vol'], descending=[False,True])
out['per_pair_venue'] = [{**r,'vol': round(r['vol'],0),'allin_vw': round(r['allin_vw'] or 0,3)} for r in pair_venue.to_dicts()]

# ── daily series per canonical pair (for charts): vol, swaps, vw allin bps, median size ──
daily = A.with_columns((pl.col('ts_ms')//86400000).alias('day')).group_by(['cpair','day']).agg([
    pl.col('usd').sum().alias('vol'), pl.len().alias('n'), pl.col('usd').median().alias('sz_med'),
    ((pl.col('allin_bps')*pl.col('usd')).sum()/pl.col('usd').sum()).alias('allin_vw'),
]).sort(['cpair','day'])
dser = {}
for r in daily.to_dicts():
    dser.setdefault(r['cpair'], []).append({'day': r['day'],'vol': round(r['vol'],0),'n': r['n'],
        'sz_med': round(r['sz_med'] or 0,1),'allin_vw': round(r['allin_vw'] or 0,3)})
out['daily_by_pair'] = dser

# ── hour-of-day volume share per focus pair ──
hod = A.with_columns(((pl.col('ts_ms')//3600000)%24).alias('hod')).group_by(['cpair','hod']).agg(pl.col('usd').sum().alias('vol')).sort(['cpair','hod'])
out['hod_by_pair'] = {}
for r in hod.to_dicts(): out['hod_by_pair'].setdefault(r['cpair'], {})[int(r['hod'])] = round(r['vol'],0)

# ── size histogram + <=2k/<=10k shares per focus pair ──
EDGES=[0,100,500,1000,2000,5000,10000,50000,1e12]; LBL=['<100','100-500','500-1k','1k-2k','2k-5k','5k-10k','10k-50k','>50k']
sh = A.with_columns(pl.col('usd').cut(EDGES[1:-1], labels=LBL).alias('bk'))
hist = sh.group_by(['cpair','bk']).agg([pl.len().alias('n'), pl.col('usd').sum().alias('v')])
out['size_hist_by_pair'] = {}
for r in hist.to_dicts(): out['size_hist_by_pair'].setdefault(r['cpair'], {})[r['bk']] = {'n': r['n'],'v': round(r['v'],0)}

json.dump(out, open(os.path.join(HERE, 'out', 'block_analytics.json'), 'w'))
print("\n=== per-pool (top by volume) ===")
print(f"{'pool':<26}{'pair':<12}{'vol$M':>8}{'swaps':>10}{'fee':>5}{'slip_vw':>8}{'allin_vw':>9}")
for r in out['per_pool'][:20]:
    print(f"{r['pool']:<26}{r['pair']:<12}{r['vol_usd']/1e6:>8.1f}{r['swaps']:>10,}{r['fee_bps']:>5.1f}{r['slip_bps_vw']:>8.3f}{r['allin_bps_vw']:>9.3f}")
print("\nwrote out/block_analytics.json")
