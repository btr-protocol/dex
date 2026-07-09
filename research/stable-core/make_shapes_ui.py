# make_shapes_ui.py — build the two-panel liquidity-shape artifact.
#  density (bell curve): $ depth per bp vs price offset, $20M-normalized → BTR spline vs Curve (real BSC A)
#    vs reconstructed PCS v3 / PCS Infinity tick liquidity.
#  impact: price impact vs trade size (real A) + measured competitor cost.
# Reads out/shapes.json (theo, real A), out/shapes_v3.json, out/shapes_inf.json, out/shapes_emp.json.
import json, os
HERE=os.path.dirname(os.path.abspath(__file__))
def L(f):
    p=os.path.join(HERE,'out',f)
    return json.load(open(p)) if os.path.exists(p) else None
S=L('shapes.json'); V3=L('shapes_v3.json'); INF=L('shapes_inf.json'); E=L('shapes_emp.json')
NORM=S['total']   # $20M

# ── theoretical series meta ──
THEO=[
 ('ours_1000','ours','--s-our1','BTR · disp 1000','USDC / USDT',2.6,None,'disp1000'),
 ('ours_2000','ours','--s-our2','BTR · disp 2000','USD1',2.0,None,'disp2000'),
 ('ours_3000','ours','--s-our3','BTR · disp 3000','USDe / FDUSD',2.0,None,'disp3000'),
 ('curve_A1000','curve','--s-cv1','Curve · A=1000','= PCS-StableSwap',1.8,[6,4],'Curve A1000'),
 ('curve_A1500','curve','--s-cv2','Curve · A=1500','= Ellipsis 3EPS',1.6,[6,4],'Curve A1500'),
 ('curve_A2000','curve','--s-cv3','Curve · A=2000','Curve-mainnet ref',1.5,[6,4],'Curve A2000'),
 ('xyk','xyk','--s-xyk','Constant product','x·y=k (Uni-v2)',1.6,[2,3],'xy=k'),
]
density_theo=[]; impact_series=[]
for k,grp,cv,lab,sub,w,dash,short in THEO:
    d=S['density'][k]
    density_theo.append({'k':k,'group':grp,'cvar':cv,'label':lab,'sub':sub,'w':w,'dash':dash,'short':short,
                         'pts':d['dens'],'cum':d['cum']})
    impact_series.append({'k':k,'group':grp,'cvar':cv,'label':lab,'sub':sub,'w':w,'dash':dash,'short':short,'d':S[k]})

# ── real reconstructed pools (density two-sided + cum each side), pre-scaled to $20M ──
def real(obj,cv,label,sub,short):
    if not obj: return None
    sc=NORM/obj['tvl_recon']
    pts=[[o, round(u*sc,1)] for o,u in obj['density']]
    cu=[[o, round(u*sc,1)] for o,u in obj['cum_up']]
    cd=[[o, round(u*sc,1)] for o,u in obj['cum_dn']]
    return {'k':obj['pool'][:6].lower().replace(' ','')+cv[-2:],'real':True,'cvar':cv,'label':label,'sub':sub,'short':short,
            'tvl':obj.get('tvl_real',obj['tvl_recon']),'pct5':obj.get('pct_within_5bp'),'pct30':obj.get('pct_within_30bp'),
            'usd5':obj.get('usd_within_5bp'),'scale':1.0,'pts':pts,'cum_up':cu,'cum_dn':cd,'group':'real'}
density_real=[r for r in [
    real(V3,'--s-v3','PancakeSwap v3','USDT/USDC 1bp · reconstructed','PCS v3'),
    real(INF,'--s-inf','PancakeSwap Infinity','USDT/USDC · reconstructed','PCS Inf'),
] if r]

# ── empirical measured cost (impact tab) ──
EMPMETA=[('PCS Infinity USDT/USDC','--s-e1','PancakeSwap Infinity','measured all-in'),
         ('PCS v3 USDT/USDC','--s-e2','PancakeSwap v3','measured all-in'),
         ('Topaz USDT/USDC','--s-e3','Topaz PMM','measured all-in')]
impact_emp=[]
for key,cv,lab,sub in EMPMETA:
    if E and key in E:
        pts=sorted(((float(s),v) for s,v in E[key].items()),key=lambda t:t[0])
        impact_emp.append({'k':key,'group':'emp','cvar':cv,'label':lab,'sub':sub,'x':[p[0] for p in pts],'y':[p[1] for p in pts]})

v3tvl=f"${V3['tvl_real']/1e6:.0f}M" if V3 else '—'
v3pct=f"{V3['pct_within_5bp']:.0f}%" if V3 else '—'
v3u5=f"${V3['usd_within_5bp']/1e6:.1f}M" if V3 else '—'
chips=[f'reconstructed on-chain: every initialized tick',
       f'PCS v3 TVL <b>{v3tvl}</b> · only <b class="teal">{v3pct}</b> within ±5 bps',
       f'Curve at <b class="teal">real BSC A 1000 / 1500</b>',
       f'BTR dispersion <b class="teal">1000 / 2000 / 3000</b>']

notes_density=(
 "<p><b>This is the bell curve you asked for</b> — liquidity depth ($ per basis point) at each price offset. For the two live "
 "PancakeSwap pools it is reconstructed from chain: every initialized tick (via the pool's tick-bitmap), its net liquidity, "
 "seeded from the live active-L, then the v3 token integral — which cross-checks to <b>94% of the pool's real on-chain "
 f"balances</b>. Every curve is normalized to a $20M pool, so you compare shapes, not sizes (equal area under each).</p>"
 "<p><b>The big surprise: PCS v3's TVL is mostly not doing anything.</b> The pool holds "
 f"<b>{v3tvl}</b>, but only <b>{v3pct}</b> of it sits within ±30 bps of price — just <b>{v3u5}</b> within ±5 bps, "
 f"<b>${(V3['usd_within_1bp'] or 0)/1e6:.1f}M</b> within ±1 bp. The other ~90% is parked in wide and full-range positions "
 "(we found initialized ticks all the way out to ±88%) that earn the fee banner but provide near-zero depth at the peg. So its "
 "real near-peg bell is far shorter than the $35M headline implies.</p>"
 "<p><b>Concentrated designs put far more depth per dollar at peg.</b> Our spline at <span class='k'>disp 1000</span> and "
 "Curve at the A those BSC pools actually run (<span class='k'>A=1000</span> PCS-StableSwap, <span class='k'>A=1500</span> "
 "Ellipsis) sit on top of each other — a tall, tight bell where nearly all the capital is within a few bps. That's why our "
 "spline at even $0.5–1M of concentrated TVL is competitive on <i>usable</i> depth with a $35M pool that scatters its liquidity. "
 "The dispersion knob widens the bell on purpose for the riskier legs (2000 USD1, 3000 USDe/FDUSD).</p>"
 "<p><b>But we don't win by out-spiking them.</b> A tall static spike is only as good as the price it's centered on — concentrate "
 "hard at a stale mark and every peg tick hands arbitrageurs free money (LVR). Our edge is the <b>fresh keeper mark</b> that keeps "
 "our (deliberately robust) bell centered on the true price, so it intermediates balanced flow and bleeds ~0 LVR. On stables that "
 "buys parity with Curve; the structural edge compounds on volatile pairs.</p>")
notes_impact=(
 "<p><b>Price impact = the slope of the bell.</b> Same designs, now shown as the impact a trade of a given size pays on a "
 "$10M-per-side pool with fees stripped. With <b>real production A</b> the picture flips from the first draft: Curve "
 "<span class='k'>A=1000</span> (what PCS-StableSwap runs) and our <span class='k'>disp 1000</span> spline are on top of each "
 "other (~0.06 bp at $100k); the tighter A=1500/2000 are Ellipsis / Curve-mainnet, not the BSC stable norm, and buy tightness "
 "at the cost of depeg fragility. Constant product (<span class='k'>x·y=k</span>) is ~2000× worse — unusable for stables.</p>"
 "<p><b>Dashed blue = real cost paid on-chain</b> (fee + spread + peg lag), from the tape: PancakeSwap Infinity/v3 clear at "
 "~4–5.5 bp, Topaz's PMM ~2 bp, flat with size. That effective spread — not curve depth — is the real bar, and it's what a "
 "1 bp fee on a fresh-marked pool is built to undercut.</p>")

DATA={'chips':chips,'density':{'xmax':30,'theo':density_theo,'real':density_real},
      'impact':{'sizes':S['sizes'],'series':impact_series,'emp':impact_emp},
      'notes_density':notes_density,'notes_impact':notes_impact,'realA':S['realA']}
html=open(os.path.join(HERE,'shapes_template.html')).read().replace('/*__DATA__*/',json.dumps(DATA))
open(os.path.join(HERE,'out','shapes_ui.html'),'w').write(html)
print(f"wrote out/shapes_ui.html  theo={len(density_theo)} real={len(density_real)} emp={len(impact_emp)}")
if V3: print(f"  v3  TVL_recon=${V3['tvl_recon']/1e6:.2f}M  L_ratio={V3.get('L_ratio')}")
if INF: print(f"  inf TVL_recon=${INF['tvl_recon']/1e3:.1f}k  L_ratio={INF.get('L_ratio')}")
