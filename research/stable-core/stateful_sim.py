# stateful_sim.py — proper "if we'd been here" sim over the last 3 MONTHS. Price-based (no fee): for each
# real trade we compare OUR fresh-mark quote to the price it ACTUALLY got, WITH our live coverage skew.
# Winning a trade shifts our inventory → coverage → our next quote (the self-correcting A-S dynamic).
# Keeper rebalances when coverage leaves a band, at market cost. Output: win-share, coverage stats,
# net revenue/APR after rebalancing. Run: uv run --with polars --with numpy python3 stateful_sim.py
import polars as pl, glob, os, json, numpy as np, bisect
HERE = os.path.dirname(os.path.abspath(__file__))
G = json.load(open(os.path.join(HERE,'out','cost_grid3d.json')))
TVLS_G, COVS_G, SIZES_G = G['tvls'], G['covs'], G['sizes']
COVS_ASC = COVS_G[::-1]  # ascending for bisect
CUT = (1783443513 - 90*86400)*1000
OUR = {'USDT','USDC','USD1','FDUSD','USDe','USDE'}
PAIRS = {'USDC/USDT':('USDC','USDT','base_spoke'), 'USD1/USDT':('USD1','USDT','spoke_spoke'), 'USD1/USDC':('USDC','USD1','base_spoke')}
OUR_FEE_BP = 0.6            # spread we keep on a won trade (revenue)
REBAL_COST_BP = 0.25       # market cost to rebalance inventory (≈ measured tight-venue exec cost)
BAND = (0.80, 1.20)        # rebalance when coverage exits this band

def load(pairkey):
    a,b = pairkey.split('/'); want = {a,b}
    fr=[]
    for f in glob.glob(os.path.join(HERE,'data','*.parquet')):
        if os.path.getsize(f)<20000: continue
        try: d=pl.read_parquet(f)
        except: continue
        d=d.filter((pl.col('amount_in')>0)&(pl.col('amount_out')>0)&(pl.col('ts_ms')>=CUT)
                   &pl.col('token_in').is_in(list(want))&pl.col('token_out').is_in(list(want)))
        if d.height==0: continue
        fr.append(d.select(['ts_ms','token_in','token_out','amount_in','amount_out']))
    if not fr: return None
    A=pl.concat(fr,how='vertical_relaxed').sort('ts_ms')
    A=A.with_columns([
      pl.when(pl.col('token_in')<pl.col('token_out')).then(pl.col('amount_out')/pl.col('amount_in')).otherwise(pl.col('amount_in')/pl.col('amount_out')).alias('P'),
      pl.col('amount_in').alias('usd'), (pl.col('ts_ms')//1000).alias('blk')]).filter((pl.col('P')>0.9)&(pl.col('P')<1.11))
    fair=A.group_by('blk').agg(pl.col('P').median().alias('fair'))
    A=A.join(fair,on='blk',how='left').with_columns((( pl.col('P')/pl.col('fair')-1).abs()*1e4).alias('their_cost'))
    return A

def grid_interp(route, tvl, cov, size):
    # nearest TVL, bilinear on (cov,size) in log-size
    ti = min(range(len(TVLS_G)), key=lambda i:abs(TVLS_G[i]-tvl)); rows=G['grid'][str(TVLS_G[ti])][route]
    cov=min(max(cov,COVS_G[-1]),COVS_G[0])
    ci=bisect.bisect_left(COVS_ASC,cov); ci=min(max(ci,1),len(COVS_ASC)-1)
    c_lo,c_hi=COVS_ASC[ci-1],COVS_ASC[ci]; fc=(cov-c_lo)/(c_hi-c_lo) if c_hi>c_lo else 0
    r_lo=rows[len(COVS_G)-1-(ci-1)]; r_hi=rows[len(COVS_G)-1-ci]
    ls=np.log(max(size,1)); si=bisect.bisect_left([np.log(x) for x in SIZES_G],ls); si=min(max(si,1),len(SIZES_G)-1)
    s_lo,s_hi=np.log(SIZES_G[si-1]),np.log(SIZES_G[si]); fs=(ls-s_lo)/(s_hi-s_lo) if s_hi>s_lo else 0
    def at(r): return r[si-1]*(1-fs)+r[si]*fs
    return at(r_lo)*(1-fc)+at(r_hi)*fc

def sim(pairkey, tvl):
    A=load(pairkey);
    if A is None: return None
    a,b,route=PAIRS[pairkey]; spoke=b if b!='USDC' else a   # the leg whose coverage we track (non-base)
    liab=tvl*0.5
    ti=A['token_in'].to_list(); usd=A['usd'].to_list(); their=A['their_cost'].to_list()
    I=0.0; won_vol=0.0; won_n=0; tot_vol=0.0; rebal_vol=0.0; cov_samples=[]
    for tin,u,tc in zip(ti,usd,their):
        tot_vol+=u
        deplete = (tin!=spoke)            # buying the spoke from us depletes it (token_in != spoke)
        cov = 1.0 - I/liab
        c_eff = cov if deplete else (2.0-cov)     # mirror: replenishing side is the abundant-side quote
        oc = grid_interp(route, tvl, c_eff, u)
        if oc < tc:                        # we quote a better price → we win
            won_vol+=u; won_n+=1
            I += (u if deplete else -u)
            # rebalance if coverage leaves band
            cov = 1.0 - I/liab
            if cov < BAND[0] or cov > BAND[1]:
                excess = abs(I) - liab*(1-BAND[0])
                if excess>0: rebal_vol += excess; I = (liab*(1-BAND[0])) if I>0 else -(liab*(1-BAND[0]))
        cov_samples.append(1.0 - I/liab)
    days=(A['ts_ms'].max()-A['ts_ms'].min())/86400000
    fee_rev = won_vol*OUR_FEE_BP/1e4
    # capacity cap: even winning, a pool services <= TVL*turnover/day
    TURN=8.0; realizable=min(won_vol, tvl*TURN*days); fee_rev = realizable*OUR_FEE_BP/1e4
    rebal_cost = rebal_vol*REBAL_COST_BP/1e4
    net_yr = (fee_rev - rebal_cost)*365/days
    cs=np.array(cov_samples)
    return {'pair':pairkey,'tvl':tvl,'days':round(days,1),'mkt_cnt':round(won_n/A.height*100,1),
            'mkt_vol':round(won_vol/tot_vol*100,1),'realizable_vol':round(realizable),
            'cov_p50':round(float(np.median(cs)),3),'cov_p05':round(float(np.percentile(cs,5)),3),'cov_p95':round(float(np.percentile(cs,95)),3),
            'rebal_vol':round(rebal_vol),'rebal_frac_of_won':round(rebal_vol/max(won_vol,1),3),
            'fee_rev_yr':round(fee_rev*365/days),'rebal_cost_yr':round(rebal_cost*365/days),
            'net_apr':round(net_yr/tvl*100,1)}

res=[]
print(f"3-MONTH stateful price-based sim (coverage-aware, rebalanced)")
print(f"{'pair':<11}{'TVL':>7}{'win_cnt':>9}{'win_vol':>9}{'cov p05/50/95':>16}{'rebal%won':>10}{'fee/yr':>9}{'rebalC/yr':>10}{'netAPR':>8}")
for pk in PAIRS:
    for tvl in [0.5e6,1e6,2e6,5e6]:
        r=sim(pk,tvl)
        if not r: continue
        res.append(r)
        print(f"{pk:<11}${r['tvl']/1e6:>4.1f}M{r['mkt_cnt']:>8}%{r['mkt_vol']:>8}%  {r['cov_p05']:.2f}/{r['cov_p50']:.2f}/{r['cov_p95']:.2f}{r['rebal_frac_of_won']*100:>8.0f}%{'$'+format(round(r['fee_rev_yr']/1e3),',')+'k':>9}{'$'+format(round(r['rebal_cost_yr']/1e3),',')+'k':>10}{r['net_apr']:>7}%")
json.dump(res, open(os.path.join(HERE,'out','stateful_sim.json'),'w'))
print("\nwrote out/stateful_sim.json")
