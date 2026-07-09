#!/bin/bash
cd /Users/derpa/Work/btr/prime/research/pool-fees
# label:usd_token:d0:d1:fee
for spec in "BASE_cbBTCUSDC_005:0:6:8:5:cbBTCUSDC" "BSC_BTCBUSDT_005:0:18:18:5:BTCBUSDT_real"; do
  bin=${spec%%:*}; rest=${spec#*:}; ut=${rest%%:*}; rest=${rest#*:}; d0=${rest%%:*}; rest=${rest#*:}; d1=${rest%%:*}; rest=${rest#*:}; fee=${rest%%:*}; lbl=${rest##*:}
  while ! grep -q DONE data_raw/swaps/$bin.log 2>/dev/null; do sleep 30; done
  echo "[$bin] swaps DONE → marking"
  scp -q -P 40022 data_raw/swaps/$bin.bin nxrates.com:/tmp/$bin.bin
  ssh -p 40022 nxrates.com "sudo /tmp/nxv/bin/python /tmp/cluster_mark.py /tmp/$bin.bin 435315775907037184 $ut $d0 $d1 $fee /tmp/$bin.csv 2>&1 | grep DONE"
  scp -q -P 40022 nxrates.com:/tmp/$bin.csv data_raw/${bin}_marked.csv
  # → series
  /tmp/almrd/bin/python -c "
import csv
rows=list(csv.DictReader(open('data_raw/${bin}_marked.csv')))
with open('../../data/fees/${lbl}_lvr.csv','w') as o:
    o.write('date_secs,f0_apr,real_lvr_apr,v_active_usd\n')
    for r in rows:
        v=float(r['v_active_usd'])
        if v<=0: continue
        o.write(f\"{r['date']},{float(r['fee_usd'])/v*365:.6f},{float(r['arb_lvr_usd'])/v*365:.6f},{v:.1f}\n\")
import statistics as st
net=sum(float(r['net_usd']) for r in rows); fee=sum(float(r['fee_usd']) for r in rows); lvr=sum(float(r['arb_lvr_usd']) for r in rows)
print(f'$lbl: {len(rows)}d Σfee \${fee/1e6:.1f}M Σarb-LVR \${lvr/1e6:.1f}M Σnet \${net/1e6:+.2f}M net/fee={net/fee*100:+.0f}%')
"
done
echo "WAIT_MARK_DONE"
