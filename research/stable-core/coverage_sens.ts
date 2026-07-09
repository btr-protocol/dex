// coverage_sens.ts — how much does OUR all-in cost widen as the output leg's coverage drops (skew)?
// Prices a spoke<->spoke and base<->spoke trade at $1M TVL with the OUTPUT leg at coverage c<1.
import { quoteExactIn, buildLeg, type AimmProfile, type PoolState, type PoolLeg } from '../../../front/src/lib/amm/aimm.ts';
const SHARED = { gamma:10_000, vega:10_000, lambda:10_000, minDisp:1_000, maxDisp:100_000, covMin:5_000, covMax:20_000, depthAmp:10_000, protoShare:20, weights:[50,50,50,50], knots:[-50,-25,0,25,50] };
const push = JSON.parse(await Bun.file('out/push_econ.json').text());
const sig = (s:string)=> s==='USDT'?500:((push.per_asset?.[s]?.sigma_day_bps_denoised??10)*100);
const TVL=1e6, MINFEE=100, BASE_FRAC=0.35, SPOKE_FRAC=0.65, VS:Record<string,number>={USDT:0.40,USD1:0.42,FDUSD:0.13,USDe:0.05};
function pool(cov:Record<string,number>):PoolState{ const legs:Record<string,PoolLeg>={}; const baseRes=TVL*BASE_FRAC;
  for(const s of ['USDT','USDe','USD1','FDUSD']){ const prof:AimmProfile={...SHARED,minFee:MINFEE,maxFee:2000};
    const liab=TVL*SPOKE_FRAC*(VS[s]??0.1); const res=liab*(cov[s]??1.0); legs[s]=buildLeg(s,1.0,sig(s),res,liab,baseRes*(cov['USDC']??1),18,prof);} return {base:'USDC',legs}; }
function cost(p:PoolState,a:string,b:string,sz:number){ const q=quoteExactIn(p,a,b,sz); return q.amountOut>0?(1-q.amountOut/sz)*1e4:NaN; }
console.log('cost(bps) as OUTPUT-leg coverage drops (USDT the output; $1M TVL, 1bp minFee)\n');
console.log('  coverage   base->spoke(USDC->USDT)              spoke->spoke(USD1->USDT)');
console.log('             $100   $1k   $2k   $10k              $100   $1k   $2k   $10k');
for(const c of [1.0,0.9,0.8,0.7,0.6,0.5]){
  const p=pool({USDT:c});  // USDT (the output) under-covered
  const bs=[100,1000,2000,10000].map(s=>cost(p,'USDC','USDT',s).toFixed(2));
  const ss=[100,1000,2000,10000].map(s=>cost(p,'USD1','USDT',s).toFixed(2));
  console.log(`   ${c.toFixed(2)}     ${bs.map(x=>x.padStart(5)).join(' ')}          ${ss.map(x=>x.padStart(5)).join(' ')}`);
}
console.log('\n(vs the ~1bp incumbent: we win only while our cost < ~0.98bp)');
