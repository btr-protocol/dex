// compute_shapes.ts — liquidity-shape curves for the comparison UI, in two views:
//  (1) impact  : price impact (bps) vs trade size, on a common $10M-per-side pool (fee stripped).
//  (2) density : the "bell curve" — $ of depth per bp of price offset from peg, at TOTAL TVL $20M,
//                so shapes are directly comparable (area under each ≈ TVL). Same units the on-chain
//                v3/Infinity tick reconstruction emits, so real pools overlay 1:1.
// Curves: BTR AIMM (Hermite spline, disp 1000/2000/3000) · Curve stableswap at REAL BSC production A
// (Ellipsis 3EPS A=1500, PCS-StableSwap A=1000; Curve-mainnet 3pool A=2000 for reference) · xy=k.
import { quoteExactIn, buildLeg, type AimmProfile, type PoolState, type PoolLeg } from '../../../front/src/lib/amm/aimm.ts';
const L = 10_000_000;                 // per-side reserve ($10M); total pool ~$20M
const TOTAL = 2 * L;
const SIZES = Array.from({length:56},(_,i)=>Math.round(Math.exp(Math.log(500)+(Math.log(6e6)-Math.log(500))*i/55)));

// ── quote functions q(dx)->dy for each design on a balanced $L/side pool ──
const BASEP = { gamma:10_000, vega:10_000, lambda:10_000, minDisp:1_000, maxDisp:100_000, covMin:5_000, covMax:20_000, depthAmp:10_000, protoShare:0, weights:[50,50,50,50], knots:[-50,-25,0,25,50] };
function oursQuote(disp:number){
  const prof:AimmProfile={...BASEP, minFee:0, minDisp:disp, maxDisp:Math.max(disp,100_000)};
  const leg:PoolLeg=buildLeg('X',1.0,0,L,L,L,18,prof);   // sigma=0 → dispersion pinned at minDisp
  const state:PoolState={base:'USDC',legs:{X:leg}};
  return (dx:number)=>{ const q=quoteExactIn(state,'USDC','X',dx); return q.amountOut>0?q.amountOut:null; };
}
// Curve stableswap invariant, n=2: get_y, D=x0+y0
function curveY(x:number,D:number,A:number){ const Ann=A*4; const c=D*D*D/(4*x*Ann); const b=x+D/Ann; const bd=b-D; return (-bd+Math.sqrt(bd*bd+4*c))/2; }
function curveQuote(A:number){ const D=2*L; return (dx:number)=>{ const y1=curveY(L+dx,D,A); const dy=L-y1; return dy>0?dy:null; }; }
const xykQuote = (dx:number)=>{ const k=L*L; const y1=k/(L+dx); return L-y1; };

const impact = (q:(dx:number)=>number|null)=>SIZES.map(s=>{const o=q(s); return o!=null&&o>0? +((1-o/s)*1e4).toFixed(4):null;});

// ── density: sweep tiny→large, marginal price = d(out)/d(in); price offset(bps) = (1 - mp)*1e4;
// density($/bp) = d(size)/d(offset); cumulative depth = size to reach that offset. TVL-normalized to $20M. ──
function density(q:(dx:number)=>number|null){
  const pts:{off:number,size:number}[]=[]; let s=200;
  while(s<8e6){ const o=q(s), o2=q(s+100);
    if(o!=null&&o2!=null&&o>0){ const marg=(o2-o)/100; const off=(1-marg)*1e4;   // marginal price offset (bps)
      if(off>0&&off<60) pts.push({off,size:s}); }
    s*=1.06; }
  // density = Δsize/Δoff ($ depth per bp); cum = $ input to reach that offset
  pts.sort((a,b)=>a.off-b.off);
  const dens:[number,number][]=[]; const cum:[number,number][]=[];
  for(let i=1;i<pts.length;i++){ const a=pts[i-1],b=pts[i]; const doff=b.off-a.off; if(doff<=0) continue;
    const d=(b.size-a.size)/doff; if(d>0) dens.push([+((a.off+b.off)/2).toFixed(2), +(d).toFixed(1)]); }
  for(const p of pts) cum.push([+p.off.toFixed(2), Math.round(p.size)]);
  return {dens, cum};
}

const DESIGNS:[string,(dx:number)=>number|null][] = [
  ['ours_1000', oursQuote(1000)],['ours_2000', oursQuote(2000)],['ours_3000', oursQuote(3000)],
  ['curve_A1000', curveQuote(1000)],['curve_A1500', curveQuote(1500)],['curve_A2000', curveQuote(2000)],
  ['xyk', (dx:number)=>xykQuote(dx)],
];
const out:any={ sizes:SIZES, L, total:TOTAL, realA:{ellipsis_3eps:1500, pcs_stableswap:1000, curve_mainnet_3pool:2000}, density:{} };
for(const [k,q] of DESIGNS){ out[k]=impact(q); const {dens,cum}=density(q); out.density[k]={dens,cum}; }
await Bun.write('out/shapes.json', JSON.stringify(out));
const i=SIZES.findIndex(s=>s>=100000);
console.log('impact(bps) @ $100k on $10M/side pool (real production A):');
console.log(`  ours  disp1000=${out.ours_1000[i]}  disp2000=${out.ours_2000[i]}  disp3000=${out.ours_3000[i]}`);
console.log(`  Curve A=1000=${out.curve_A1000[i]}  A=1500=${out.curve_A1500[i]}  A=2000=${out.curve_A2000[i]}  |  xy=k=${out.xyk[i]}`);
console.log('density pts (ours_1000):', out.density.ours_1000.dens.length, ' curve_A1000:', out.density.curve_A1000.dens.length);
console.log('wrote out/shapes.json');
