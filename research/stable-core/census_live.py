# census_live.py — live pool census via GeckoTerminal + DexScreener to find the REAL top BSC
# stablecoin pools (esp. the giant PCS USDT/USDC) with addresses, 24h vol, TVL, fee tier.
# Run: uv run --with requests python3 census_live.py
import requests, json, time

STABLES = {
    'USDT': '0x55d398326f99059ff775485246999027b3197955',
    'USDC': '0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d',
    'USD1': '0x8d0d000ee44948fc98c9b98a4fa4921476f08b0d',
    'FDUSD': '0xc5f0f7b66764f6ec8c8dff7ba683102295e16409',
    'TUSD': '0x14016e85a25aeb13065688cafb43044c2ef86784',
    'DAI': '0x1af3f329e8be154074d8769d1ffa4ee058b1dbc3',
    'USDE': '0x5d3a1ff2b6bab83b63cd9ad0787074081a52ef34',
}
ADDR2SYM = {v: k for k, v in STABLES.items()}
def is_stable(addr): return (addr or '').lower() in ADDR2SYM

GT = 'https://api.geckoterminal.com/api/v2'
def gt(path):
    for _ in range(3):
        r = requests.get(f'{GT}{path}', headers={'accept': 'application/json'}, timeout=20)
        if r.status_code == 200: return r.json()
        time.sleep(2)
    return {}

seen = {}
def add(p):
    a = p['attributes']; addr = a.get('address', '').lower()
    if not addr or addr in seen: return
    # tokens
    base = p['relationships'].get('base_token', {}).get('data', {}).get('id', '').split('_')[-1].lower()
    quote = p['relationships'].get('quote_token', {}).get('data', {}).get('id', '').split('_')[-1].lower()
    if not (is_stable(base) and is_stable(quote)): return
    v24 = float(a.get('volume_usd', {}).get('h24', 0) or 0)
    tvl = float(a.get('reserve_in_usd', 0) or 0)
    seen[addr] = {
        'name': a.get('name'), 'addr': addr, 'dex': p['relationships']['dex']['data']['id'],
        'pair': f'{ADDR2SYM.get(base,"?")}/{ADDR2SYM.get(quote,"?")}',
        'vol24h_usd': v24, 'tvl_usd': tvl, 'turnover': round(v24 / tvl, 2) if tvl else None,
    }

# 1) top BSC pools overall (catches the giants)
for pg in range(1, 6):
    d = gt(f'/networks/bsc/pools?page={pg}&sort=h24_volume_usd_desc')
    for p in d.get('data', []): add(p)
    time.sleep(1)
# 2) per-stablecoin top pools (catches pairs not in the global top)
for sym, addr in STABLES.items():
    d = gt(f'/networks/bsc/tokens/{addr}/pools?sort=h24_volume_usd_desc')
    for p in d.get('data', []): add(p)
    time.sleep(1)

pools = sorted(seen.values(), key=lambda x: -x['vol24h_usd'])
print(f"{'pair':<12} {'dex':<22} {'vol24h$M':>10} {'tvl$M':>8} {'turn':>5}  addr")
tot = 0
for p in pools:
    tot += p['vol24h_usd']
    print(f"{p['pair']:<12} {p['dex']:<22} {p['vol24h_usd']/1e6:>10.1f} {p['tvl_usd']/1e6:>8.1f} {str(p['turnover']):>5}  {p['addr']}")
print(f"\nTOTAL stable-stable 24h vol (found): ${tot/1e6:,.1f}M  across {len(pools)} pools")
json.dump(pools, open('out/census_live.json', 'w'), indent=1)
print("wrote out/census_live.json")
