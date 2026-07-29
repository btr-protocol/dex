// emit_cost_grid.ts — our all-in cost (bps) over a 3-D grid: TVL × output-leg coverage × trade size,
// for both routes. The stateful sim interpolates this per trade instead of calling the quote law
// millions of times. Coverage = output leg res/liab (skew from captured one-way flow).
// Run: bun run emit_cost_grid.ts
import { quoteExactIn, buildLeg, type AimmProfile, type PoolState, type PoolLeg } from '../../../sdk/src/amm/aimm.ts';
const SHARED = { gamma:10_000, vega:10_000, lambda:10_000, minDisp:1_000, maxDisp:100_000, covMin:5_000, covMax:20_000, depthAmp:10_000, protoShare:20, weights:[50,50,50,50], knots:[-50,-25,0,25,50] };
const push = JSON.parse(await Bun.file('out/push_econ.json').text());
const sig = (s:string)=> s==='USDT'?500:((push.per_asset?.[s]?.sigma_day_bps_denoised??10)*100);
const BASE_FRAC=0.35, SPOKE_FRAC=0.65, VS:Record<string,number>={USDT:0.40,USD1:0.42,FDUSD:0.13,USDe:0.05};
const MINFEE=100;

// Build a pool at TVL with the OUTPUT spoke leg at coverage `cov` (res=cov*liab). Route base<->spoke uses
// USDT as spoke; spoke<->spoke uses USD1->USDT (USDT output the skewed leg).
function poolFor(route:string, tvl:number, cov:number):[PoolState,string,string]{
  const legs:Record<string,PoolLeg>={}; const baseRes=tvl*BASE_FRAC;
  const outLeg = 'USDT';                 // the depleting/output leg we skew
  for(const s of ['USDT','USDe','USD1','FDUSD']){ const prof:AimmProfile={...SHARED,minFee:MINFEE,maxFee:2000};
    const liab=tvl*SPOKE_FRAC*(VS[s]??0.1); const res = s===outLeg ? liab*cov : liab;
    legs[s]=buildLeg(s,1.0,sig(s),res,liab,baseRes,18,prof); }
  const [a,b] = route==='base_spoke' ? ['USDC','USDT'] : ['USD1','USDT'];
  return [{base:'USDC',legs}, a, b];
}
function cost(p:PoolState,a:string,b:string,sz:number){ const q=quoteExactIn(p,a,b,sz); return q.amountOut>0?+((1-q.amountOut/sz)*1e4).toFixed(4):9999; }

const TVLS=[0.5e6,1e6,2e6,5e6];
const COVS=[1.2,1.1,1.0,0.95,0.9,0.85,0.8,0.75,0.7,0.6,0.5];
const SIZES=Array.from({length:48},(_,i)=>Math.round(Math.exp(Math.log(1)+(Math.log(2e6)-Math.log(1))*i/47)));
const out:any={ tvls:TVLS, covs:COVS, sizes:SIZES, minFee_bp:MINFEE/100, grid:{} };
for(const tvl of TVLS){ out.grid[tvl]={};
  for(const route of ['base_spoke','spoke_spoke']){ out.grid[tvl][route]=COVS.map(cov=>{
    const [p,a,b]=poolFor(route,tvl,cov); return SIZES.map(s=>cost(p,a,b,s)); }); } }
await Bun.write('out/cost_grid3d.json', JSON.stringify(out));
console.log('wrote out/cost_grid3d.json —', TVLS.length,'TVL x', COVS.length,'cov x', SIZES.length,'size x 2 routes');
const i2k=SIZES.findIndex(s=>s>=2000);
console.log('\nour cost @ $2k, spoke->spoke, by TVL x coverage:');
console.log('  cov: '+COVS.map(c=>c.toFixed(2).padStart(6)).join(''));
for(const tvl of TVLS){ const cells=out.grid[tvl].spoke_spoke.map((row:number[])=>row[i2k].toFixed(2).padStart(6)).join(''); console.log(`  $${(tvl/1e6).toFixed(1)}M ${cells}`); }
