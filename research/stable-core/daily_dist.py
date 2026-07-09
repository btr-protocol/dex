# daily_dist.py — per-pool daily/hourly trade distribution over the 6mo BSC+ETH stable tape.
# Answers: what does daily activity look like, and what % of TRADES / VOLUME are <= $2k / <= $10k
# (the segment we want to own). Stables priced at $1 (amount_in ~ USD). Local only.
# Run: uv run --with polars python3 daily_dist.py
import polars as pl, glob, os, json

FILES = {
    'UNIv3 USDT/USDC (BSC)':  'data/UNIv3_USDT_USDC_100.parquet',
    'PCSv3 USD1/USDT':        'data/PCSv3_USD1_USDT_100.parquet',
    'PCSv3 FDUSD/USDT':       'data/PCSv3_FDUSD_USDT_100.parquet',
    'PCSv3 USDe/USDT':        'data/PCSv3_USDe_USDT_100.parquet',
    'PCSv3 TUSD/USDT':        'data/PCSv3_TUSD_USDT_100.parquet',
}
SIZE_EDGES = [0, 100, 500, 1000, 2000, 5000, 10000, 50000, 100000, 1e12]
SIZE_LABELS = ['<100', '100-500', '500-1k', '1k-2k', '2k-5k', '5k-10k', '10k-50k', '50k-100k', '>100k']

out = {}
print(f"{'pool':<24} {'days':>5} {'vol$M':>8} {'trades':>9} {'vol/day$':>11} {'tr/day':>7} {'p50$':>6} {'p90$':>7} {'p99$':>8} {'<=2k#%':>7} {'<=2k$%':>7} {'<=10k#%':>8} {'<=10k$%':>8}")
for name, path in FILES.items():
    if not os.path.exists(path) or os.path.getsize(path) < 1000:
        continue
    df = pl.read_parquet(path).with_columns([
        (pl.col('amount_in')).alias('usd'),                       # stable ~ $1
        (pl.col('ts_ms') // 86_400_000).alias('day'),
        ((pl.col('ts_ms') // 3_600_000) % 24).alias('hod'),
    ]).filter((pl.col('usd') > 0) & (pl.col('usd') < 5e7))
    n = df.height
    if n == 0:
        continue
    vol = df['usd'].sum()
    days = (df['ts_ms'].max() - df['ts_ms'].min()) / 86_400_000
    p50, p90, p99 = (df['usd'].quantile(q) for q in (0.5, 0.9, 0.99))
    le2k_n = df.filter(pl.col('usd') <= 2000).height / n
    le2k_v = df.filter(pl.col('usd') <= 2000)['usd'].sum() / vol
    le10k_n = df.filter(pl.col('usd') <= 10000).height / n
    le10k_v = df.filter(pl.col('usd') <= 10000)['usd'].sum() / vol
    # daily series
    daily = df.group_by('day').agg([pl.col('usd').sum().alias('v'), pl.len().alias('t')]).sort('day')
    # hour-of-day volume share
    hod = df.group_by('hod').agg(pl.col('usd').sum().alias('v')).sort('hod')
    hod_share = {int(r['hod']): round(r['v'] / vol, 4) for r in hod.to_dicts()}
    # size histogram (count + volume share)
    df = df.with_columns(pl.col('usd').cut(SIZE_EDGES[1:-1], labels=SIZE_LABELS).alias('bkt'))
    hist = df.group_by('bkt').agg([pl.len().alias('n'), pl.col('usd').sum().alias('v')])
    hist_d = {r['bkt']: {'n': int(r['n']), 'n_share': round(r['n']/n, 4), 'vol_usd': round(r['v'], 1), 'vol_share': round(r['v']/vol, 4)} for r in hist.to_dicts()}
    out[name] = {
        'days': round(days, 1), 'vol_usd': round(vol, 1), 'trades': n,
        'vol_per_day_usd': round(vol/days, 1), 'trades_per_day': round(n/days, 1),
        'size_p50': round(p50, 2), 'size_p90': round(p90, 2), 'size_p99': round(p99, 2),
        'le_2k_trade_share': round(le2k_n, 4), 'le_2k_vol_share': round(le2k_v, 4),
        'le_10k_trade_share': round(le10k_n, 4), 'le_10k_vol_share': round(le10k_v, 4),
        'hist': hist_d, 'hod_vol_share': hod_share,
        'daily_vol_usd': [round(r['v'], 1) for r in daily.to_dicts()],
        'daily_trades': [int(r['t']) for r in daily.to_dicts()],
    }
    print(f"{name:<24} {days:>5.0f} {vol/1e6:>8.1f} {n:>9,} {vol/days:>11,.0f} {n/days:>7,.0f} {p50:>6.0f} {p90:>7.0f} {p99:>8.0f} {le2k_n*100:>6.1f}% {le2k_v*100:>6.1f}% {le10k_n*100:>7.1f}% {le10k_v*100:>7.1f}%")

json.dump(out, open('out/daily_dist.json', 'w'), indent=1)
print("\nwrote out/daily_dist.json")
