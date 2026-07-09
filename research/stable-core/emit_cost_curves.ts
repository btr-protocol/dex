// emit_cost_curves.ts — precompute OUR pool's all-in cost (bps) vs trade size, at a grid of TVLs, for
// the two routing types (base<->spoke, spoke<->spoke). The routing replay then interpolates per swap
// instead of calling quoteExactIn millions of times. Uses the REAL quote law. Run: bun run emit_cost_curves.ts
import { quoteExactIn, buildLeg, type AimmProfile, type PoolState, type PoolLeg } from '../../../front/src/lib/amm/aimm.ts';
const SHARED = { gamma:10_000, vega:10_000, lambda:10_000, minDisp:1_000, maxDisp:100_000, covMin:5_000, covMax:20_000, depthAmp:10_000, protoShare:20, weights:[50,50,50,50], knots:[-50,-25,0,25,50] };
const push = JSON.parse(await Bun.file('out/push_econ.json').text());
const BASE='USDC'; const SPOKES=['USDT','USDe','USD1','FDUSD'] as const;
const VOL_SHARE:Record<string,number>={USDT:0.40,USD1:0.42,FDUSD:0.13,USDe:0.05}; const BASE_FRAC=0.35,SPOKE_FRAC=0.65;
function sigmaPbpsOf(s:string){ if(s==='USDT')return 500; const pa=push.per_asset?.[s]??push.per_asset?.[s.toUpperCase()]; return (pa?.sigma_day_bps_denoised??pa?.sigma_day_bps??10)*100; }
function buildPool(tvl:number,minFee:number):PoolState{ const legs:Record<string,PoolLeg>={}; const baseRes=tvl*BASE_FRAC;
  for(const s of SPOKES){ const prof:AimmProfile={...SHARED,minFee,maxFee:2_000}; const legTvl=tvl*SPOKE_FRAC*(VOL_SHARE[s]??0.1); legs[s]=buildLeg(s,1.0,sigmaPbpsOf(s),legTvl,legTvl,baseRes,18,prof);} return {base:BASE,legs}; }
function costBps(pool:PoolState,tin:string,tout:string,sz:number):number|null{ const q=quoteExactIn(pool,tin,tout,sz); if(!(q.amountOut>0))return null; return (1-q.amountOut/sz)*1e4; }

const MINFEE=100; // 1bp launch spread
const TVLS=[0.25e6,0.5e6,1e6,2e6,5e6];
// 60 log-spaced sizes $1 .. $2M
const SIZES=Array.from({length:60},(_,i)=>Math.round(Math.exp(Math.log(1)+(Math.log(2e6)-Math.log(1))*i/59)));
const ROUTES={ base_spoke:['USDC','USDT'], spoke_spoke:['USD1','USDT'] } as Record<string,[string,string]>;

const out:any={ minFee_bp:MINFEE/100, sizes:SIZES, tvls:TVLS, curves:{} };
for(const tvl of TVLS){ const pool=buildPool(tvl,MINFEE); out.curves[tvl]={};
  for(const [route,[a,b]] of Object.entries(ROUTES)){ out.curves[tvl][route]=SIZES.map(s=>{const c=costBps(pool,a,b,s); return c==null?9999:+c.toFixed(4);}); }
}
await Bun.write('out/cost_curves.json', JSON.stringify(out));
console.log('wrote out/cost_curves.json —', TVLS.length,'TVLs x', SIZES.length,'sizes x 2 routes');
// preview at $2k
for(const tvl of TVLS){ const i=SIZES.findIndex(s=>s>=2000); console.log(`  TVL $${(tvl/1e6).toFixed(2)}M  base-spoke@2k=${out.curves[tvl].base_spoke[i]}bp  spoke-spoke@2k=${out.curves[tvl].spoke_spoke[i]}bp`); }
