# census_ds.py — DexScreener cross-check: all BSC pairs for each stablecoin, ranked by 24h vol.
# DexScreener often reports more completely than GeckoTerminal. Run: uv run --with requests python3 census_ds.py
import requests, json, time
STABLES = {
    'USDT': '0x55d398326f99059ff775485246999027b3197955',
    'USDC': '0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d',
    'USD1': '0x8d0d000ee44948fc98c9b98a4fa4921476f08b0d',
    'FDUSD': '0xc5f0f7b66764f6ec8c8dff7ba683102295e16409',
    'TUSD': '0x14016e85a25aeb13065688cafb43044c2ef86784',
    'USDE': '0x5d3a1ff2b6bab83b63cd9ad0787074081a52ef34',
}
ADDR2SYM = {v.lower(): k for k, v in STABLES.items()}
def sym(a): return ADDR2SYM.get((a or '').lower())

seen = {}
for s, addr in STABLES.items():
    try:
        r = requests.get(f'https://api.dexscreener.com/token-pairs/v1/bsc/{addr}', timeout=25)
        pairs = r.json() if r.status_code == 200 else []
    except Exception as e:
        pairs = []; print('err', s, e)
    for p in pairs:
        b = sym(p.get('baseToken', {}).get('address')); q = sym(p.get('quoteToken', {}).get('address'))
        if not (b and q):  # only stable-stable
            continue
        pa = p.get('pairAddress', '').lower()
        if not pa or pa in seen:
            continue
        seen[pa] = {
            'pair': f'{b}/{q}', 'dex': p.get('dexId'), 'addr': pa,
            'vol24h_usd': float(p.get('volume', {}).get('h24', 0) or 0),
            'vol6h_usd': float(p.get('volume', {}).get('h6', 0) or 0),
            'liq_usd': float(p.get('liquidity', {}).get('usd', 0) or 0),
            'txns24h': (p.get('txns', {}).get('h24', {}) or {}).get('buys', 0) + (p.get('txns', {}).get('h24', {}) or {}).get('sells', 0),
        }
    time.sleep(0.5)

pools = sorted(seen.values(), key=lambda x: -x['vol24h_usd'])
print(f"{'pair':<12} {'dex':<20} {'vol24h$M':>10} {'liq$M':>8} {'txns24h':>8}  addr")
tot = 0
for p in pools[:30]:
    tot_all = sum(x['vol24h_usd'] for x in pools)
    print(f"{p['pair']:<12} {p['dex']:<20} {p['vol24h_usd']/1e6:>10.2f} {p['liq_usd']/1e6:>8.2f} {p['txns24h']:>8}  {p['addr']}")
tot_all = sum(x['vol24h_usd'] for x in pools)
print(f"\nTOTAL stable-stable 24h vol (DexScreener, {len(pools)} pools): ${tot_all/1e6:,.1f}M")
json.dump(pools, open('out/census_ds.json', 'w'), indent=1)
print("wrote out/census_ds.json")
