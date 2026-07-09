# scale_check.py — reconcile "billions/day" vs stable-stable DEX volume. Pulls token-level totals
# (all pairs incl. volatile) + market caps, to separate CEX/total-DEX from our addressable stable-stable slice.
import requests, json, time
GT = 'https://api.geckoterminal.com/api/v2'
TOKENS = {  # BSC addresses
    'USDT': '0x55d398326f99059ff775485246999027b3197955',
    'USDC': '0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d',
    'USD1': '0x8d0d000ee44948fc98c9b98a4fa4921476f08b0d',
    'FDUSD': '0xc5f0f7b66764f6ec8c8dff7ba683102295e16409',
}
print("=== GeckoTerminal token-level (BSC): total 24h DEX vol across ALL pairs (incl. volatile) ===")
for s, a in TOKENS.items():
    try:
        d = requests.get(f'{GT}/networks/bsc/tokens/{a}', headers={'accept':'application/json'}, timeout=20).json()
        at = d.get('data', {}).get('attributes', {})
        v = float(at.get('volume_usd', {}).get('h24', 0) or 0)
        mc = at.get('market_cap_usd') or at.get('fdv_usd')
        print(f"  {s:<6} total_BSC_DEX_vol_24h=${v/1e6:>10.1f}M   fdv/mcap=${float(mc or 0)/1e6:>10.1f}M   px={at.get('price_usd')}")
    except Exception as e:
        print('  err', s, e)
    time.sleep(1)

print("\n=== CoinGecko: market cap + total (all-venue incl CEX) 24h volume ===")
IDS = {'tether':'USDT','usd-coin':'USDC','world-liberty-financial-usd':'USD1','first-digital-usd':'FDUSD'}
try:
    d = requests.get('https://api.coingecko.com/api/v3/simple/price',
                     params={'ids':','.join(IDS), 'vs_currencies':'usd', 'include_market_cap':'true', 'include_24hr_vol':'true'},
                     timeout=25).json()
    for cid, sym in IDS.items():
        r = d.get(cid, {})
        print(f"  {sym:<6} mcap=${r.get('usd_market_cap',0)/1e9:>7.1f}B   total_24h_vol(all venues, incl CEX)=${r.get('usd_24h_vol',0)/1e9:>7.2f}B")
except Exception as e:
    print('  cg err', e)
