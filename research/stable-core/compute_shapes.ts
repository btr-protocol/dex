// compute_shapes.ts — liquidity-shape curves for the comparison UI, in two views:
//  (1) impact  : price impact (bps) vs trade size, on a common $10M-per-side pool (fee stripped).
//  (2) density : the "bell curve" — $ of depth per bp of price offset from peg, at TOTAL TVL $20M,
//                so shapes are directly comparable (area under each ≈ TVL). Same units the on-chain
//                v3/Infinity tick reconstruction emits, so real pools overlay 1:1.
// Curves: BTR AIMM (Hermite spline, disp 1000/2000/3000) · Curve stableswap at REAL BSC production A
// (Ellipsis 3EPS A=1500, PCS-StableSwap A=1000; Curve-mainnet 3pool A=2000 for reference) · xy=k.
import { quoteExactIn, buildLeg, type AimmProfile, type PoolState, type PoolLeg } from '../../../sdk/src/amm/aimm.ts';
const L = 10_000_000;                 // per-side reserve ($10M); total pool ~$20M
const TOTAL = 2 * L;
const SIZES = Array.from({length:56},(_,i)=>Math.round(Math.exp(Math.log(500)+(Math.log(6e6)-Math.log(500))*i/55)));

// ── quote functions q(dx)->dy for each design on a balanced $L/side pool ──
// Each factory also returns `maxIn`: the REAL capacity ceiling beyond which a quote is invalid.
// aimm.ts's spline walk is a genuinely FINITE band ([0,BPS] depth-coords) — past q.maxIn, traverse()'s
// band is saturated at the edge and bandPrice() returns a FROZEN average (not a real marginal quote).
// Bisecting for a target offset past that point searches a plateau, not a monotone function, and jumps.
const BASEP = { gamma:10_000, vega:10_000, lambda:10_000, minDisp:1_000, maxDisp:100_000, covMin:5_000, covMax:20_000, depthAmp:10_000, protoShare:0, weights:[50,50,50,50], knots:[-50,-25,0,25,50] };
function oursQuote(disp:number){
  const prof:AimmProfile={...BASEP, minFee:0, minDisp:disp, maxDisp:Math.max(disp,100_000)};
  const leg:PoolLeg=buildLeg('X',1.0,0,L,L,L,18,prof);   // sigma=0 → dispersion pinned at minDisp
  const state:PoolState={base:'USDC',legs:{X:leg}};
  const maxIn=quoteExactIn(state,'USDC','X',1).maxIn;    // constant for the leg — doesn't depend on trade size
  const q=(dx:number)=>{ if(dx>maxIn) return null; const r=quoteExactIn(state,'USDC','X',dx); return r.amountOut>0?r.amountOut:null; };
  return {q, maxIn};
}
// Curve stableswap invariant, n=2: get_y, D=x0+y0 — continuous, no artificial cutoff (y→0 asymptotically)
function curveY(x:number,D:number,A:number){ const Ann=A*4; const c=D*D*D/(4*x*Ann); const b=x+D/Ann; const bd=b-D; return (-bd+Math.sqrt(bd*bd+4*c))/2; }
function curveQuote(A:number){ const D=2*L; const q=(dx:number)=>{ const y1=curveY(L+dx,D,A); const dy=L-y1; return dy>0?dy:null; }; return {q, maxIn:9.9e6}; }
const xykQuoteWrap = {q:(dx:number)=>{ const k=L*L; const y1=k/(L+dx); return L-y1; }, maxIn:9.9e6};

const impact = ({q,maxIn}:{q:(dx:number)=>number|null,maxIn:number})=>SIZES.map(s=>{
  if(s>maxIn) return null; const o=q(s); return o!=null&&o>0? +((1-o/s)*1e4).toFixed(4):null; });

// ── density (bell): the TRUE marginal-liquidity density dLiquidity/dPrice, to match how real v3/Infinity
// tick liquidity is measured. For a target marginal price-offset δ (regular grid), binary-search the input
// size whose MARGINAL price = 1−δ; cum(δ)=that size ($ within ±δ, one side); density(δ)=d cum/dδ ($/bp).
// Bisection domain is hard-capped at maxIn: past it the design has NO liquidity (a real wall), so cum(δ)
// simply stays pinned at maxIn — never extrapolated past the model's real, finite capacity. ──
function density({q,maxIn}:{q:(dx:number)=>number|null,maxIn:number}){
  const marg=(s:number)=>{ const h=Math.max(50,s*2e-4); const o=q(Math.min(s,maxIn)), o2=q(Math.min(s+h,maxIn));
    if(o==null||o2==null||s+h>maxIn) return null; return (1-(o2-o)/h)*1e4; };  // null past the wall ⇒ never satisfies marg<d
  const cum:[number,number][]=[];
  for(let d=0.25; d<=30.001; d+=0.25){                                        // regular δ grid
    let lo=0, hi=maxIn;                                                       // hard-capped: no quote exists beyond maxIn
    for(let it=0;it<44;it++){ const mid=(lo+hi)/2; const m=marg(mid);
      if(m!=null && m<d) lo=mid; else hi=mid; }
    cum.push([+d.toFixed(2), Math.round((lo+hi)/2)]);                         // pins at maxIn once δ exceeds the real wall
  }
  const dens:[number,number][]=[];
  for(let i=1;i<cum.length;i++){ const dS=cum[i][1]-cum[i-1][1], dO=cum[i][0]-cum[i-1][0];
    dens.push([+((cum[i][0]+cum[i-1][0])/2).toFixed(2), Math.max(0,+(dS/dO).toFixed(1))]); }
  return {dens, cum};
}

const DESIGNS:[string,{q:(dx:number)=>number|null,maxIn:number}][] = [
  ['ours_1000', oursQuote(1000)],['ours_2000', oursQuote(2000)],['ours_3000', oursQuote(3000)],
  ['curve_A1000', curveQuote(1000)],['curve_A1500', curveQuote(1500)],['curve_A2000', curveQuote(2000)],
  ['xyk', xykQuoteWrap],
];
const out:any={ sizes:SIZES, L, total:TOTAL, realA:{ellipsis_3eps:1500, pcs_stableswap:1000, curve_mainnet_3pool:2000}, density:{}, maxIn:{} };
for(const [k,w] of DESIGNS){ out[k]=impact(w); const {dens,cum}=density(w); out.density[k]={dens,cum}; out.maxIn[k]=w.maxIn; }
await Bun.write('out/shapes.json', JSON.stringify(out));
const i=SIZES.findIndex(s=>s>=100000);
console.log('impact(bps) @ $100k on $10M/side pool (real production A):');
console.log(`  ours  disp1000=${out.ours_1000[i]}  disp2000=${out.ours_2000[i]}  disp3000=${out.ours_3000[i]}`);
console.log(`  Curve A=1000=${out.curve_A1000[i]}  A=1500=${out.curve_A1500[i]}  A=2000=${out.curve_A2000[i]}  |  xy=k=${out.xyk[i]}`);
console.log('density pts (ours_1000):', out.density.ours_1000.dens.length, ' curve_A1000:', out.density.curve_A1000.dens.length);
console.log('wrote out/shapes.json');
