// tvl_threshold.ts — minimum TVL (total + per-asset) to WIN the small-trade segment vs the incumbent.
// Reuses the real quote law (aimm.ts) + the same balanced-pool build as capture_sim. For each pair and
// trade size we compute our all-in cost (bps) and compare to the incumbent's measured cost; we "win" the
// size iff our cost <= venue * (1 - router_edge). We sweep TVL to find the min total (and the implied
// per-leg reserves) at which we win everything up to $2k, and up to $10k. Run: bun run tvl_threshold.ts
import { quoteExactIn, buildLeg, type AimmProfile, type PoolState, type PoolLeg } from '../../../front/src/lib/amm/aimm.ts';

const SHARED = { gamma: 10_000, vega: 10_000, lambda: 10_000, minDisp: 1_000, maxDisp: 100_000,
  covMin: 5_000, covMax: 20_000, depthAmp: 10_000, protoShare: 20, weights: [50, 50, 50, 50], knots: [-50, -25, 0, 25, 50] };
const micro = JSON.parse(await Bun.file('out/micro_summary.json').text());
const push = JSON.parse(await Bun.file('out/push_econ.json').text());

const BASE = 'USDC';
const SPOKES = ['USDT', 'USDe', 'USD1', 'FDUSD'] as const;
// per-leg TVL split (matches capture_sim): base 35%, spokes 65% * volShare
const VOL_SHARE: Record<string, number> = { USDT: 0.40, USD1: 0.42, FDUSD: 0.13, USDe: 0.05 };
const BASE_FRAC = 0.35, SPOKE_FRAC = 0.65;

function sigmaPbpsOf(sym: string): number {
  if (sym === 'USDT') return 5 * 100;
  const pa = push.per_asset?.[sym] ?? push.per_asset?.[sym.toUpperCase()];
  return (pa?.sigma_day_bps_denoised ?? pa?.sigma_day_bps ?? 10) * 100;
}
function buildPool(tvlUsd: number, minFeePbps: number): PoolState {
  const legs: Record<string, PoolLeg> = {};
  const baseRes = tvlUsd * BASE_FRAC;
  for (const s of SPOKES) {
    const prof: AimmProfile = { ...SHARED, minFee: minFeePbps, maxFee: 2_000 };
    const legTvl = tvlUsd * SPOKE_FRAC * (VOL_SHARE[s] ?? 0.1);
    legs[s] = buildLeg(s, 1.0, sigmaPbpsOf(s), legTvl, legTvl, baseRes, 18, prof);
  }
  return { base: BASE, legs };
}
function ourCostBps(pool: PoolState, tin: string, tout: string, sizeUsd: number): number | null {
  const q = quoteExactIn(pool, tin, tout, sizeUsd);
  if (!(q.amountOut > 0)) return null;
  return (1 - q.amountOut / sizeUsd) * 1e4;
}
function mapLeg(sym: string): string | null {
  if (sym === 'USDC') return BASE;
  if ((SPOKES as readonly string[]).includes(sym)) return sym;
  return null;
}
// venue cost (bps) for a given size from the pair's measured bucket costs
function venueCostBps(pairKey: string, sizeUsd: number): number | null {
  const p = micro.pairs[pairKey]; if (!p?.buckets) return null;
  const edges: [number, number, string][] = [[0,1,'<$1'],[1,10,'$1-10'],[10,100,'$10-100'],[100,1e3,'$100-1k'],[1e3,1e4,'$1k-10k'],[1e4,1e5,'$10k-100k'],[1e5,1e6,'$100k-1M']];
  const lbl = edges.find(([lo,hi]) => sizeUsd > lo && sizeUsd <= hi)?.[2];
  const bk = p.buckets.find((b: any) => b.bucket === lbl && b.cost_bps_vw != null)
          ?? p.buckets.filter((b: any) => b.cost_bps_vw != null).at(-1);
  return bk?.cost_bps_vw ?? null;
}

const ROUTER_EDGE = 0.02;
const SIZES = [100, 500, 1000, 2000, 5000, 10000, 25000, 50000];
const TVLS = [0.25e6, 0.5e6, 0.75e6, 1e6, 1.5e6, 2e6, 3e6, 5e6, 10e6];
// pairs from our launch set that map onto the pool
const PAIRS = Object.keys(micro.pairs).filter(k => { const [a,b]=k.split('/'); const la=mapLeg(a),lb=mapLeg(b); return la&&lb&&la!==lb; });
const MINFEE = 100; // 1bp launch spread (also show 1 PBPS floor below)

function maxWinSize(pool: PoolState, pairKey: string): number {
  const [a, b] = pairKey.split('/'); const la = mapLeg(a)!, lb = mapLeg(b)!;
  let best = 0;
  for (const s of SIZES) {
    const our = ourCostBps(pool, la, lb, s); const ven = venueCostBps(pairKey, s);
    if (our == null || ven == null) continue;
    if (our <= ven * (1 - ROUTER_EDGE)) best = s; else break;
  }
  return best;
}

const result: any = { minFee_bp: MINFEE/100, router_edge: ROUTER_EDGE, per_leg_split: { base: BASE_FRAC, spoke_frac: SPOKE_FRAC, vol_share: VOL_SHARE }, sweep: [], thresholds: {} };

console.log(`\n=== our all-in cost (bps) vs incumbent, minFee=${MINFEE/100}bp — by TVL & size ===`);
console.log(`(venue ref ~${venueCostBps('USD1/USDT',2000)?.toFixed(2)}bp for USD1/USDT; win if our <= venue*0.98)\n`);
for (const pairKey of PAIRS) {
  console.log(`--- ${pairKey}  (max winnable trade size by TVL) ---`);
  const row: any = { pair: pairKey, by_tvl: [] };
  for (const tvl of TVLS) {
    const pool = buildPool(tvl, MINFEE);
    const [a,b]=pairKey.split('/'); const la=mapLeg(a)!, lb=mapLeg(b)!;
    const costs = SIZES.map(s => ourCostBps(pool, la, lb, s));
    const win = maxWinSize(pool, pairKey);
    row.by_tvl.push({ tvl_usd: tvl, max_win_usd: win, cost_at_2k: costs[3]!=null?+costs[3]!.toFixed(3):null, cost_at_10k: costs[5]!=null?+costs[5]!.toFixed(3):null });
    console.log(`  TVL $${(tvl/1e6).toFixed(2)}M  win<=$${String(win).padStart(6)}   cost@2k=${(costs[3]??NaN).toFixed(3)}bp  cost@10k=${(costs[5]??NaN).toFixed(3)}bp`);
  }
  result.sweep.push(row);
}

// Volume-weighted capture of a size segment: for each pair+bucket with mid<=target, win iff our cost
// (at the bucket mid) beats venue; accumulate won vs total VOLUME and COUNT across all pairs, weighted
// by the pair's real per-bucket volume/count. (No break-on-first-loss — venue cost is non-monotonic.)
const FINE = { '<$1':0.5,'$1-10':3.16,'$10-100':31.6,'$100-1k':316,'$1k-10k':3162,'$10k-100k':31623,'$100k-1M':316228 } as Record<string,number>;
function segmentCapture(tvl: number, target: number) {
  const pool = buildPool(tvl, MINFEE);
  let wonVol=0, totVol=0, wonN=0, totN=0;
  for (const pk of PAIRS) {
    const [a,b]=pk.split('/'); const la=mapLeg(a)!, lb=mapLeg(b)!;
    for (const bk of micro.pairs[pk].buckets) {
      const mid = FINE[bk.bucket]; if (mid==null || mid>target || bk.cost_bps_vw==null) continue;
      const our = ourCostBps(pool, la, lb, Math.min(mid, target));
      totVol += bk.vol_usd; totN += bk.n;
      if (our!=null && our <= bk.cost_bps_vw*(1-ROUTER_EDGE)) { wonVol += bk.vol_usd; wonN += bk.n; }
    }
  }
  return { vol_pct: totVol?+(wonVol/totVol*100).toFixed(1):0, cnt_pct: totN?+(wonN/totN*100).toFixed(1):0 };
}
// core pairs = the ones that actually carry the flow (USD1/USDT + USDC/USDT = ~95% of stable volume)
const CORE = ['USD1/USDT','USDC/USDT'].filter(p=>PAIRS.includes(p));
function coreMinTvl(target: number): number|null {
  for (const tvl of TVLS) { const pool=buildPool(tvl,MINFEE); if (CORE.every(pk=>maxWinSize(pool,pk)>=target)) return tvl; }
  return null;
}
console.log('\n=== volume-weighted capture of the small-trade segment (all launch pairs) ===');
console.log('TVL($M)   <=$2k: vol%  cnt%     <=$10k: vol%  cnt%');
for (const tvl of TVLS) {
  const s2=segmentCapture(tvl,2000), s10=segmentCapture(tvl,10000);
  console.log(`  ${(tvl/1e6).toFixed(2).padStart(5)}      ${String(s2.vol_pct).padStart(5)} ${String(s2.cnt_pct).padStart(5)}        ${String(s10.vol_pct).padStart(5)} ${String(s10.cnt_pct).padStart(5)}`);
  result.sweep.find((r:any)=>false); // keep types happy
}
for (const target of [2000, 10000]) {
  const minTvl = coreMinTvl(target);
  const perLeg: any = {};
  if (minTvl) { perLeg[BASE]=Math.round(minTvl*BASE_FRAC); for (const s of SPOKES) perLeg[s]=Math.round(minTvl*SPOKE_FRAC*(VOL_SHARE[s]??0.1)); }
  const cap = minTvl ? segmentCapture(minTvl, target) : null;
  result.thresholds[`core_win_le_${target}`] = { min_total_tvl_usd: minTvl, per_asset_reserve_usd: perLeg, segment_capture_all_pairs: cap };
  console.log(`\n>>> min TOTAL TVL to win the core pairs (USD1/USDT+USDC/USDT, 95% of flow) up to $${target}: ${minTvl?('$'+(minTvl/1e6).toFixed(2)+'M'):'>$10M'}`);
  if (minTvl) { console.log('    per-asset reserve: ' + Object.entries(perLeg).map(([k,v])=>`${k} $${((v as number)/1e6).toFixed(3)}M`).join('  '));
    console.log(`    (at this TVL we capture ${cap?.vol_pct}% of <=$${target} VOLUME, ${cap?.cnt_pct}% of TRADES across all pairs)`); }
}

await Bun.write('out/tvl_threshold.json', JSON.stringify(result, null, 1));
console.log('\nwrote out/tvl_threshold.json');
