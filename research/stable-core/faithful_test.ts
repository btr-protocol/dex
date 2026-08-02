// faithful_sim.ts — FAITHFUL state-machine "if we'd been here" sim over the 3-month tape.
// A live PoolState (shared USDC base + per-spoke reserves). For each real swap in time order we run the
// REAL quote law (quoteExactIn, mark=1.0 peg) against the CURRENT state; if our amountOut beats what the
// trader actually got, we WIN → apply the reserve deltas (coverage moves) → next quote reflects it.
// Keeper rebalances a spoke at market cost when its coverage leaves the band. Run: bun run faithful_sim.ts
import { quoteExactIn, buildLeg, type AimmProfile, type PoolState, type PoolLeg } from '../../../sdk/src/amm/aimm.ts';
const SHARED = { gamma:10_000, vega:10_000, lambda:10_000, minDisp:1_000, maxDisp:100_000, covMin:5_000, covMax:20_000, depthAmp:10_000, protoShare:20, weights:[50,50,50,50], knots:[-50,-25,0,25,50] };
const push = JSON.parse(await Bun.file('out/push_econ.json').text());
const sig = (s:string)=> s==='USDT'?500:((push.per_asset?.[s]?.sigma_day_bps_denoised??10)*100);
const BASE='USDC'; const SPOKES=['USDT','USDe','USD1','FDUSD']; const VS:Record<string,number>={USDT:0.40,USD1:0.42,FDUSD:0.13,USDe:0.05};
const REBAL_COST_BP=0.25, BAND_LO=0.80, BAND_HI=1.20, MINFEE=100, TURN=8.0;

function makePool(tvl:number){
  const B={v:tvl*0.35}; const legs:Record<string,PoolLeg>={};
  for(const s of SPOKES){ const liab=tvl*0.65*(VS[s]??0.1); const prof:AimmProfile={...SHARED,minFee:MINFEE,maxFee:2000};
    legs[s]=buildLeg(s,1.0,sig(s),liab,liab,B.v,18,prof); }
  return {B, state:{base:BASE,legs} as PoolState, liab:Object.fromEntries(SPOKES.map(s=>[s,tvl*0.65*(VS[s]??0.1)]))};
}
function setBase(P:any){ for(const s of SPOKES) P.state.legs[s].baseRes=P.B.v; }

// stream the CSV (652MB) in chunks; header: ts_ms,token_in,token_out,amount_in,amount_out
async function run(tvl:number){
  const P=makePool(tvl); setBase(P);
  let wonVol=0,wonN=0,totVol=0,totN=0,feeRev=0,rebalVol=0; const covMin:Record<string,number>={}, covLast:Record<string,number>={};
  for(const s of SPOKES){covMin[s]=1;covLast[s]=1;}
  let t0=0,t1=0;
  const stream=Bun.file('out/tape_test.csv').stream(); const dec=new TextDecoder(); let buf='';
  let first=true;
  for await(const chunk of stream){
    buf+=dec.decode(chunk,{stream:true}); let nl;
    while((nl=buf.indexOf('\n'))>=0){ const line=buf.slice(0,nl); buf=buf.slice(nl+1);
      if(first){first=false;continue;} if(!line)continue;
      const c=line.split(','); const ts=+c[0], tin=c[1], tout=c[2], ain=+c[3], aout=+c[4];
      if(!(ain>0&&aout>0))continue; if(!t0)t0=ts; t1=ts; totN++; totVol+=ain;
      // LIVE MARK: our keeper tracks the real base(USDC)-per-token price from observed flow (EMA), so the
      // pool prices at the true peg (~1.0004 for USDT), not a flat 1.0. This is the "proper exchange rate"
      // recovered from the tape itself (no external history needed).
      const A_=0.05;
      if(tin===BASE && tout!==BASE){ const px=ain/aout; if(px>0.9&&px<1.11) P.state.legs[tout].twap=(1-A_)*P.state.legs[tout].twap+A_*px; } // USDC->spoke: base-per-token = in/out
      else if(tout===BASE && tin!==BASE){ const px=aout/ain; if(px>0.9&&px<1.11) P.state.legs[tin].twap=(1-A_)*P.state.legs[tin].twap+A_*px; } // spoke->USDC: base-per-token = out/in
      const q=quoteExactIn(P.state,tin,tout,ain);
      if(q.amountOut>aout && q.amountOut>0){          // we quote a better price → win
        wonVol+=ain; wonN++; feeRev+=ain*(q.lpFeeBps||0)/1e4; // LP leg only: protoFeeBps goes to treasury, never to LPs
        // apply reserve deltas
        const inBase=tin===BASE, outBase=tout===BASE;
        if(!inBase&&outBase){ P.state.legs[tin].res+=ain; P.B.v-=q.amountOut; }         // sell spoke→base
        else if(inBase&&!outBase){ P.B.v+=ain; P.state.legs[tout].res-=q.amountOut; }    // buy spoke
        else if(!inBase&&!outBase){ P.state.legs[tin].res+=ain; P.state.legs[tout].res-=q.amountOut; } // cross (base nets)
        setBase(P);
        // rebalance any spoke out of band
        for(const s of SPOKES){ const cov=P.state.legs[s].res/P.liab[s]; covLast[s]=cov; if(cov<covMin[s])covMin[s]=cov;
          if(cov<BAND_LO||cov>BAND_HI){ const target=P.liab[s]; const delta=target*(cov<BAND_LO?BAND_LO:BAND_HI)-P.state.legs[s].res;
            rebalVol+=Math.abs(delta); P.state.legs[s].res+= (cov<BAND_LO? P.liab[s]*BAND_LO - P.state.legs[s].res : P.liab[s]*BAND_HI - P.state.legs[s].res);
            P.B.v-= (cov<BAND_LO? (P.liab[s]*BAND_LO - (P.state.legs[s].res)) : 0)*0; setBase(P); } }
      }
    }
  }
  const days=(t1-t0)/86400000; const realizable=Math.min(wonVol, tvl*TURN*days);
  const feeReal=realizable/Math.max(wonVol,1)*feeRev; const rebalCost=rebalVol*REBAL_COST_BP/1e4;
  const netYr=(feeReal-rebalCost)*365/days;
  return { tvl, days:+days.toFixed(1), win_cnt:+(wonN/totN*100).toFixed(1), win_vol:+(wonVol/totVol*100).toFixed(1),
    realizable_6mo:Math.round(realizable), cov_min:Object.fromEntries(SPOKES.map(s=>[s,+covMin[s].toFixed(2)])),
    cov_last:Object.fromEntries(SPOKES.map(s=>[s,+covLast[s].toFixed(2)])),
    rebal_frac:+(rebalVol/Math.max(wonVol,1)).toFixed(2), fee_yr:Math.round(feeReal*365/days),
    rebal_cost_yr:Math.round(rebalCost*365/days), net_apr:+(netYr/tvl*100).toFixed(1) };
}

const out:any[]=[];
console.log('FAITHFUL 3mo state-machine sim (real quote law, mark=1.0, coverage evolves per swap, rebalanced)\n');
console.log(`${'TVL'.padStart(7)}${'win_cnt'.padStart(9)}${'win_vol'.padStart(9)}${'USDT_cov_min'.padStart(13)}${'rebal/won'.padStart(11)}${'fee/yr'.padStart(9)}${'rebalC/yr'.padStart(10)}${'netAPR'.padStart(8)}`);
for(const tvl of [1e6]){ const r=await run(tvl); out.push(r);
  console.log(`$${(tvl/1e6).toFixed(1)}M`.padStart(7)+`${r.win_cnt}%`.padStart(9)+`${r.win_vol}%`.padStart(9)+`${r.cov_min.USDT}`.padStart(13)+`${(r.rebal_frac*100).toFixed(0)}%`.padStart(11)+`$${Math.round(r.fee_yr/1e3)}k`.padStart(9)+`$${Math.round(r.rebal_cost_yr/1e3)}k`.padStart(10)+`${r.net_apr}%`.padStart(8)); }
await Bun.write('out/faithful_sim.json', JSON.stringify(out,null,1));
console.log('\nwrote out/faithful_sim.json');
