# make_report.py — self-contained HTML analytics report from block_analytics.json (+ census/capture).
# Dark quant-terminal dashboard, canvas charts, no external deps (CSP-safe). Run: python3 make_report.py
import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
B = json.load(open(os.path.join(HERE, 'out', 'block_analytics.json')))

# ── curate: drop decoder-suspect + dust; canonicalize focus pairs ──
SUSPECT = {'THENA_fusion_USDT_USDC', 'UNIv3_USDT_USDC_500'}
pools = [p for p in B['per_pool'] if p['pool'] not in SUSPECT]
FOCUS_PAIRS = ['USDC/USDT', 'USD1/USDT', 'USD1/USDC', 'FDUSD/USDT']

# headline aggregates
tot_vol = sum(p['vol_usd'] for p in pools)
days = max((p['days'] for p in pools), default=183)
vol_day = tot_vol / days
usdc_usdt = sum(p['vol_usd'] for p in pools if p['pair'] in ('USDT/USDC','USDC/USDT'))
usd1 = sum(p['vol_usd'] for p in pools if 'USD1' in p['pair'])

# size distribution rolled up over focus pairs -> <=2k / <=10k shares (count + vol)
def rollup_sizes():
    order = ['<100','100-500','500-1k','1k-2k','2k-5k','5k-10k','10k-50k','>50k']
    agg = {k: {'n':0,'v':0.0} for k in order}
    for pair, h in B['size_hist_by_pair'].items():
        if pair not in FOCUS_PAIRS: continue
        for k, d in h.items():
            if k in agg: agg[k]['n'] += d['n']; agg[k]['v'] += d['v']
    N = sum(a['n'] for a in agg.values()); V = sum(a['v'] for a in agg.values())
    le2k_n = sum(agg[k]['n'] for k in ['<100','100-500','500-1k','1k-2k'])/max(N,1)
    le2k_v = sum(agg[k]['v'] for k in ['<100','100-500','500-1k','1k-2k'])/max(V,1)
    le10k_n = le2k_n + sum(agg[k]['n'] for k in ['2k-5k','5k-10k'])/max(N,1)
    le10k_v = le2k_v + sum(agg[k]['v'] for k in ['2k-5k','5k-10k'])/max(V,1)
    return order, agg, le2k_n, le2k_v, le10k_n, le10k_v, N
order, sz, le2k_n, le2k_v, le10k_n, le10k_v, focusN = rollup_sizes()

# venue attribution per focus pair
venue_attr = {}
for r in B['per_pair_venue']:
    cp = r['cpair']
    if cp in ('USDC/USDT','USD1/USDT','USD1/USDC','FDUSD/USDT'):
        venue_attr.setdefault(cp, []).append({'venue': r['venue'], 'vol': r['vol'], 'allin': r['allin_vw']})

# daily series (downsample to keep payload light) for the 3 biggest pairs
def daily(pair, key):
    s = B['daily_by_pair'].get(pair, [])
    return [round(x[key],1) for x in s]
DAILY = {p: {'vol': daily(p,'vol'), 'n': daily(p,'n'), 'allin': daily(p,'allin_vw')} for p in ['USDC/USDT','USD1/USDT','USD1/USDC']}
day0 = min((x['day'] for p in B['daily_by_pair'].values() for x in p), default=0)

# MEASURED market share + revenue + APR from the per-swap routing replay (route_replay.json)
RR = json.load(open(os.path.join(HERE,'out','route_replay.json')))
APR = {}
for r in RR['by_tvl']:
    APR[f"${r['tvl']/1e6:.2f}M".replace('.00','').replace('.25M','.25M').replace('.50M','.5M')] = {
        'tvl': r['tvl'], 'mkt_vol': r['mkt_vol_pct'], 'mkt_cnt': r['mkt_cnt_pct'],
        'fee_rev_yr': r['fee_rev_yr'], 'fee_apr': r['fee_apr'], 'net_apr': r['net_apr']}
INCUMBENT = RR['incumbent_fees']; INCUMBENT_TOT = RR['incumbent_total_fees_yr']

DATA = {
  'meta': {'swaps': B['generated_over_swaps'], 'pools': len(pools), 'days': round(days,0),
           'tot_vol': round(tot_vol), 'vol_day': round(vol_day), 'usdc_usdt': round(usdc_usdt), 'usd1': round(usd1),
           'le2k_n': round(le2k_n,3), 'le2k_v': round(le2k_v,3), 'le10k_n': round(le10k_n,3), 'le10k_v': round(le10k_v,3)},
  'pools': [{'pool':p['pool'],'pair':p['pair'],'venue':p['venue'],'vol':p['vol_usd'],'swaps':p['swaps'],
             'fee':p['fee_bps'],'slip':p['slip_bps_vw'],'allin':p['allin_bps_vw'],
             'p50':p['sz_p50'],'p90':p['sz_p90'],'p99':p['sz_p99']} for p in pools],
  'sizes': {'order':order,'bins':[{'k':k,'n':sz[k]['n'],'v':round(sz[k]['v'])} for k in order]},
  'venue_attr': venue_attr, 'daily': DAILY, 'day0': day0, 'apr': APR,
  'incumbent': [{'pool':x['pool'],'vol':x['vol_usd'],'fee':x['fee_bps'],'fees_yr':x['fees_yr_usd']} for x in INCUMBENT[:10]],
  'incumbent_tot': INCUMBENT_TOT,
  'faithful': [{'tvl':r['tvl'],'win_cnt':r['win_cnt'],'win_vol':r['win_vol'],'net_apr':r['net_apr'],
                'fee_yr':r['fee_yr'],'rebal_frac':r['rebal_frac'],'cov_min':r['cov_min'].get('USDT')}
               for r in json.load(open(os.path.join(HERE,'out','faithful_sim.json')))],
}
json.dump(DATA, open(os.path.join(HERE,'out','report_data.json'),'w'))

HTML = open(os.path.join(HERE,'report_template.html')).read().replace('/*__DATA__*/', json.dumps(DATA))
open(os.path.join(HERE,'out','stable_report.html'),'w').write(HTML)
print(f"wrote out/stable_report.html  (vol/day=${vol_day/1e6:.1f}M, {len(pools)} pools, <=2k trades={le2k_n*100:.1f}%)")
