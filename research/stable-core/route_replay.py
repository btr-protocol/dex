# route_replay.py — "if we had been here" routing simulation over the REAL 6mo per-swap tape.
# For every historical swap between our 5 tokens: actual all-in it paid = venue fee tier + realized
# slippage (vs cross-pool VWAP mid). We interpolate OUR modeled all-in at that size (cost_curves.json)
# and CAPTURE the swap iff our cost <= its actual cost * (1-router_edge). Sum → market share, fee
# revenue, APR per TVL. Also reports the actual fees each competing pool earned. Local, vectorized.
# Run: uv run --with polars python3 route_replay.py
import polars as pl, glob, os, json, re, math
HERE = os.path.dirname(os.path.abspath(__file__))
REG = json.load(open(os.path.join(HERE,'stable-pools.json')))
CURVES = json.load(open(os.path.join(HERE,'out','cost_curves.json')))
SIZES = CURVES['sizes']; N = len(SIZES); LOG0, LOGMAX = math.log(SIZES[0] or 1), math.log(SIZES[-1])
OUR = {'USDT','USDC','USD1','USDe','USDE','FDUSD'}         # our 5 listed tokens (addressable set)
EDGE = 0.02
FEE_OF = {100:1.0,500:5.0,2500:25.0,3000:30.0,10000:100.0,1:0.5,3:3.0}
def fee_of(lbl):
    m = re.search(r'_(\d{1,5})$', lbl); return FEE_OF.get(int(m.group(1)),1.0) if m else 1.0
SUSPECT = {'THENA_fusion_USDT_USDC','UNIv3_USDT_USDC_500'}

frames = []
for f in glob.glob(os.path.join(HERE,'data','*.parquet')):
    if os.path.getsize(f) < 1000: continue
    lbl = os.path.basename(f)[:-8]
    if lbl in SUSPECT: continue
    try: df = pl.read_parquet(f)
    except Exception: continue
    if df.height==0 or 'amount_in' not in df.columns: continue
    df = df.filter((pl.col('amount_in')>0)&(pl.col('amount_out')>0)&(pl.col('amount_in')<5e7)).with_columns([
        pl.lit(lbl).alias('pool'), pl.lit(float(fee_of(lbl))).alias('fee_bps'),
        (pl.col('amount_in')).alias('usd'), (pl.col('amount_out')/pl.col('amount_in')).alias('exec_px'),
        (pl.col('ts_ms')//1000).alias('blk')])
    frames.append(df.select(['blk','ts_ms','pool','fee_bps','token_in','token_out','usd','exec_px']))
A = pl.concat(frames, how='vertical_relaxed')
# addressable: both tokens ∈ our set, sane per-$1 price
A = A.filter(pl.col('token_in').is_in(list(OUR)) & pl.col('token_out').is_in(list(OUR))
             & (pl.col('exec_px')>0.9)&(pl.col('exec_px')<1.11))
A = A.with_columns(pl.struct(['token_in','token_out']).map_elements(
    lambda s: '/'.join(sorted([s['token_in'],s['token_out']])), return_dtype=pl.String).alias('cpair'))
# EMPIRICAL cost, NO nominal fee tiers. pxn = normalized price P (B per A, A<B). A->B execs below fair,
# B->A above → per-pair FAIR = midpoint of directional small-trade medians. actual all-in each trade paid
# = |pxn - fair| (absolute; captures the real fee, so Topaz@~0bp is correctly ~0, not a fake 1bp).
A = A.with_columns([
    pl.when(pl.col('token_in')<pl.col('token_out')).then(pl.col('exec_px')).otherwise(1.0/pl.col('exec_px')).alias('pxn'),
    (pl.col('token_in')<pl.col('token_out')).alias('is_ab'),
])
sm = A.filter(pl.col('usd')<1000)
fair = sm.group_by('cpair').agg([
    pl.col('pxn').filter('is_ab').median().alias('p_ab'),
    pl.col('pxn').filter(pl.col('is_ab').not_()).median().alias('p_ba'),
]).with_columns(((pl.col('p_ab')+pl.col('p_ba'))/2).alias('fair')).select(['cpair','fair'])
A = A.join(fair, on='cpair', how='left').with_columns([
    ((pl.col('pxn')/pl.col('fair')-1.0).abs()*1e4).alias('actual_allin'),
    pl.when(pl.col('cpair').str.contains('USDC')).then(pl.lit('base_spoke')).otherwise(pl.lit('spoke_spoke')).alias('route'),
])
# size-grid index (log-spaced) for interpolation
A = A.with_columns((((pl.col('usd').log()-LOG0)/(LOGMAX-LOG0)*(N-1)).clip(0,N-1)).alias('pos'))
A = A.with_columns([pl.col('pos').floor().cast(pl.Int64).alias('i0')])
A = A.with_columns([pl.min_horizontal(pl.col('i0')+1, N-1).alias('i1'), (pl.col('pos')-pl.col('i0')).alias('frac')])
days = (A['ts_ms'].max()-A['ts_ms'].min())/86400000
tot_vol = A['usd'].sum(); tot_n = A.height
print(f"addressable (our 5 tokens): {tot_n:,} swaps, ${tot_vol/1e6:,.0f}M over {days:.0f}d = ${tot_vol/days/1e6:.1f}M/day\n")

def curve_lookup(route, tvl):
    c = CURVES['curves'][str(int(tvl))][route]
    return pl.col('i0').replace_strict(list(range(N)), c, return_dtype=pl.Float64), pl.col('i1').replace_strict(list(range(N)), c, return_dtype=pl.Float64)

res = {'addressable': {'swaps':tot_n,'vol_usd':round(tot_vol),'days':round(days,1),'vol_day':round(tot_vol/days)}, 'by_tvl':[]}
print(f"{'TVL':>7}{'mkt-share vol':>14}{'mkt-share cnt':>14}{'won $/6mo':>13}{'fee rev/yr':>12}{'fee APR':>9}{'net APR':>9}")
for tvl in CURVES['tvls']:
    B = A
    for route in ('base_spoke','spoke_spoke'):
        c0,c1 = curve_lookup(route,tvl)
        B = B.with_columns(pl.when(pl.col('route')==route).then(c0*(1-pl.col('frac'))+c1*pl.col('frac')).otherwise(pl.col('our_cost') if 'our_cost' in B.columns else None).alias('our_cost'))
    B = B.with_columns((pl.col('our_cost') <= pl.col('actual_allin')*(1-EDGE)).alias('win'))
    won = B.filter('win')
    won_vol = won['usd'].sum() or 0; won_n = won.height
    # revenue = the FEE we keep (our spread), NOT the all-in cost (which includes slippage → not revenue).
    # And cap by CAPACITY: a pool services at most TVL*turnover/day (benchmark: PCS 0.6x, Topaz PMM ~6.6x).
    OUR_FEE_BP = 0.6; TURNOVER = 8.0
    realizable = min(won_vol, tvl*TURNOVER*days)
    fee_rev_yr = realizable * OUR_FEE_BP/1e4 * 365/days
    row = {'tvl':tvl,'mkt_vol_pct':round(won_vol/tot_vol*100,1),'mkt_cnt_pct':round(won_n/tot_n*100,1),
           'won_vol_6mo':round(won_vol),'realizable_6mo':round(realizable),'capacity_bound':realizable<won_vol,
           'fee_rev_yr':round(fee_rev_yr),'fee_apr':round(fee_rev_yr/tvl*100,1),'net_apr':round(fee_rev_yr/tvl*100-0.15,1)}
    res['by_tvl'].append(row)
    cap = '⚠cap' if row['capacity_bound'] else '    '
    print(f"${tvl/1e6:>5.2f}M{row['mkt_vol_pct']:>10}%{row['mkt_cnt_pct']:>10}% {cap}{'$'+format(round(realizable/1e6),',')+'M':>11}{'$'+format(round(fee_rev_yr/1e3),',')+'k':>10}{row['fee_apr']:>7}%{row['net_apr']:>7}%")

# incumbent fees earned (owner's question): vol * MEASURED effective fee (half-spread), per pool
EFF = {r['pool']: max(r['eff_fee_bps'],0.0) for r in json.load(open(os.path.join(HERE,'out','eff_fees.json')))}
inc = A.group_by('pool').agg(pl.col('usd').sum().alias('vol')).sort('vol',descending=True)
res['incumbent_fees'] = []
for r in inc.to_dicts():
    eff = EFF.get(r['pool'], 1.0)
    fees_6mo = r['vol']*eff/1e4
    res['incumbent_fees'].append({'pool':r['pool'],'vol_usd':round(r['vol']),'fee_bps':round(eff,3),
        'fees_6mo_usd':round(fees_6mo),'fees_yr_usd':round(fees_6mo*365/days)})
res['incumbent_fees'].sort(key=lambda x:-x['fees_yr_usd'])
tot_fees_yr = sum(x['fees_yr_usd'] for x in res['incumbent_fees'])
res['incumbent_total_fees_yr'] = tot_fees_yr
print(f"\n=== fees the competing pools ACTUALLY earned (annualized) ===  TOTAL ≈ ${tot_fees_yr/1e6:.2f}M/yr")
for r in res['incumbent_fees'][:10]:
    print(f"  {r['pool']:<26} vol ${r['vol_usd']/1e6:>7.0f}M @ {r['fee_bps']:>4.1f}bp → ${r['fees_yr_usd']/1e3:>6.0f}k/yr")
json.dump(res, open(os.path.join(HERE,'out','route_replay.json'),'w'))
print("\nwrote out/route_replay.json")
