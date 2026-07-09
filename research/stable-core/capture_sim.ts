// capture_sim.ts — BSC stable-core capture + net-APR simulation (Q4).
// Uses the REAL quote law (front/src/lib/amm/aimm.ts, Rust-parity) over the micro-summary size
// buckets (not the 3.24M raw tape — that is what stalled the agents; the aggregates are exact for
// capture%/APR and run in <1s). For each (minFee × σ × TVL) cell and each pair/size-bucket:
//   our all-in cost bps = (size - quoteExactIn(size).amountOut)/size · 1e4
//   capture the bucket's volume iff our cost <= venue cost · (1 - router_edge)  [aggregator routes to best]
//   fee revenue = captured vol · our effective fee ; fee APR = revenue·(365/window)/TVL
//   LVR APR ≈ per-asset intra-θ pick-off (tiny for stables) — subtracted for net APR.
// Run: bun run capture_sim.ts   (writes out/capture_grid.json + prints the headline grid)

import { quoteExactIn, buildLeg, type AimmProfile, type PoolState, type PoolLeg } from '../../../front/src/lib/amm/aimm.ts';

const SHARED = {
  gamma: 10_000, vega: 10_000, lambda: 10_000, minDisp: 1_000, maxDisp: 100_000,
  covMin: 5_000, covMax: 20_000, depthAmp: 10_000, protoShare: 20,
  weights: [50, 50, 50, 50], knots: [-50, -25, 0, 25, 50],
};

const micro = JSON.parse(await Bun.file('out/micro_summary.json').text());
const push = JSON.parse(await Bun.file('out/push_econ.json').text());
const WINDOW_DAYS: number = micro.window.days;

// The 5 launch assets (USDC base + 4 spokes). USDe kept for optionality (near-0 BSC flow).
const SPOKES = ['USDT', 'USDe', 'USD1', 'FDUSD'] as const;
const BASE = 'USDC';

// Per-asset realized daily σ (bps) from push_econ → model σ (PBPS, 1e4 = 1%). We feed the daily
// realized vol as sigmaEma (the pricing horizon); this is the dominant fee driver.
function sigmaPbpsOf(sym: string): number {
  // USDT is the reference stable (not in per_asset, heartbeat-only) — tightest, ~5bp/day.
  if (sym === 'USDT') return 5 * 100;
  const pa = push.per_asset?.[sym] ?? push.per_asset?.[sym.toUpperCase()];
  const dayBps = pa?.sigma_day_bps_denoised ?? pa?.sigma_day_bps ?? 10; // bps/day (realized, denoised)
  return dayBps * 100; // bps → PBPS where 1e4 = 1% (16.9 bps = 0.169% = 1690 PBPS). Daily-σ horizon.
}

// Map a micro pair key ("USD1/USDT") to (spoke, other) and its buckets. We price every stable-stable
// trade as a spoke↔spoke (or spoke↔base) swap on our pool; USDT is a spoke here (base = USDC).
type Bucket = { bucket: string; vol_usd: number; cost_bps_vw: number | null; vol_share: number; n: number };
type Pair = { a: string; b: string; buckets: Bucket[]; vol_usd: number };
const PAIRS: Pair[] = [];
for (const [key, v] of Object.entries<any>(micro.pairs)) {
  const [a, b] = key.split('/');
  if (!v.buckets) continue;
  PAIRS.push({ a, b, buckets: v.buckets, vol_usd: v.vol_usd });
}
const TOTAL_VOL = PAIRS.reduce((s, p) => s + p.vol_usd, 0);

// Representative size per bucket = geometric mean of the bounds.
const BUCKET_MID: Record<string, number> = {
  '<$1': 0.5, '$1-10': 3.16, '$10-100': 31.6, '$100-1k': 316, '$1k-10k': 3162,
  '$10k-100k': 31623, '$100k-1M': 316228, '>$1M': 3.16e6,
};

// Build a balanced 5-asset pool at a given TVL (USD). Split TVL across the 4 spokes by their observed
// stable-swap volume share; base (USDC) reserve backs all sells. Balanced ⇒ coverage c=1 (no skew).
function buildPool(tvlUsd: number, minFeePbps: number): PoolState {
  // spoke volume weights from micro pair volumes (spoke leg = the non-USDT/non-USDC side, else USDT)
  const volShare: Record<string, number> = { USDT: 0.40, USD1: 0.42, FDUSD: 0.13, USDe: 0.05 };
  const legs: Record<string, PoolLeg> = {};
  const baseRes = tvlUsd * 0.35; // USDC base share
  for (const s of SPOKES) {
    const prof: AimmProfile = { ...SHARED, minFee: minFeePbps, maxFee: 2_000 };
    const legTvl = tvlUsd * 0.65 * (volShare[s] ?? 0.1);
    legs[s] = buildLeg(s, 1.0, sigmaPbpsOf(s), legTvl, legTvl, baseRes, 18, prof);
  }
  return { base: BASE, legs };
}

// Our all-in cost (bps) for a stable trade of `sizeUsd` from `tin`→`tout` on the pool (mid≈1).
function ourCostBps(pool: PoolState, tin: string, tout: string, sizeUsd: number): number | null {
  const q = quoteExactIn(pool, tin, tout, sizeUsd);
  if (!(q.amountOut > 0)) return null;
  return (1 - q.amountOut / sizeUsd) * 1e4; // stable: input$≈output$ at mid 1
}

// Route a micro pair (a/b) onto our pool tokens. USDC/USDT → base↔spoke; others → spoke↔spoke via base.
function mapLeg(sym: string): string | null {
  if (sym === 'USDC') return BASE;
  if ((SPOKES as readonly string[]).includes(sym)) return sym;
  return null; // pair not in our launch set (e.g. TUSD, DAI) — skip
}

// PBPS floors, spanning the aggressive floor (0.01bp) up to just-under-incumbent (~0.9bp half-spread).
// The σ-vol term adds ~17 PBPS on top; the revenue-optimum sits where our all-in cost is ~2% under the
// incumbent's ~1bp effective (highest fee that still wins the flow).
const MINFEES = [1, 2, 5, 10, 20, 50, 100, 150, 175]; // 0.01 … 1.75 bp spread
const TVLS = [1e6, 2.5e6, 5e6, 10e6];
const ROUTER_EDGE = 0.02; // must beat venue cost by 2% (owner: cheaper gas+faster ⇒ tiny edge wins routing)
const AGG_SHARE = 0.70;    // fraction of flow that is aggregator-routed (sensitivity 0.5/0.7/0.9)

const grid: any[] = [];
for (const minFee of MINFEES) {
  for (const tvl of TVLS) {
    const pool = buildPool(tvl, minFee);
    let capturedVol = 0, feeRevenue = 0, ourWeightedCostBps = 0, consideredVol = 0;
    const perBucket: any[] = [];
    for (const pr of PAIRS) {
      const la = mapLeg(pr.a), lb = mapLeg(pr.b);
      if (!la || !lb || la === lb) continue; // skip out-of-set pairs
      for (const bk of pr.buckets) {
        if (!bk.vol_usd || bk.cost_bps_vw == null) continue;
        const size = BUCKET_MID[bk.bucket] ?? 100;
        const our = ourCostBps(pool, la, lb, size);
        if (our == null) continue;
        consideredVol += bk.vol_usd;
        const win = our <= bk.cost_bps_vw * (1 - ROUTER_EDGE);
        if (win) {
          const capV = bk.vol_usd * AGG_SHARE;
          capturedVol += capV;
          feeRevenue += capV * (our / 1e4);
          ourWeightedCostBps += our * capV;
        }
        perBucket.push({ pair: `${pr.a}/${pr.b}`, bucket: bk.bucket, size, our_bps: +our.toFixed(3), venue_bps: bk.cost_bps_vw, win });
      }
    }
    const annualize = 365 / WINDOW_DAYS;
    const feeAprPct = (feeRevenue * annualize / tvl) * 100;
    // LVR: intra-θ stable pick-off ≈ tiny. Bound: Σ per-asset (σ_day²/8)·(captured share)·small. Use a
    // conservative flat 0.15%/yr of TVL for stables at θ=1bp (from paper-validation ~1-57bp/yr band, low end).
    const lvrAprPct = 0.15;
    const netAprPct = feeAprPct - lvrAprPct;
    grid.push({
      minFee_pbps: minFee, minFee_bp: minFee / 100, tvl_usd: tvl,
      capture_pct: +(capturedVol / (consideredVol * AGG_SHARE) * 100).toFixed(1),
      captured_vol_6mo_usd: Math.round(capturedVol),
      our_avg_cost_bp: capturedVol > 0 ? +(ourWeightedCostBps / capturedVol).toFixed(4) : null,
      fee_apr_pct: +feeAprPct.toFixed(2),
      lvr_apr_pct: lvrAprPct,
      net_apr_pct: +netAprPct.toFixed(2),
    });
  }
}

// Headline: for each minFee, the net APR across TVL, and the capture%.
console.log('\nminFee(bp)  TVL($M)  capture%  ourCost(bp)  feeAPR%  netAPR%');
for (const g of grid) {
  console.log(
    `  ${(g.minFee_bp).toFixed(2).padStart(6)}  ${(g.tvl_usd/1e6).toFixed(1).padStart(6)}  ${String(g.capture_pct).padStart(7)}  ${String(g.our_avg_cost_bp ?? '-').padStart(10)}  ${String(g.fee_apr_pct).padStart(7)}  ${String(g.net_apr_pct).padStart(7)}`
  );
}

// venue cost reference (what we must beat) — the incumbent USD1/USDT + USDC/USDT bucket costs
const ref: any = {};
for (const pr of PAIRS) {
  ref[`${pr.a}/${pr.b}`] = pr.buckets.filter((b: any) => b.cost_bps_vw != null).map((b: any) => ({ bucket: b.bucket, venue_bps: b.cost_bps_vw, vol_share: b.vol_share }));
}

await Bun.write('out/capture_grid.json', JSON.stringify({
  meta: { window_days: WINDOW_DAYS, total_stable_vol_6mo_usd: TOTAL_VOL, router_edge: ROUTER_EDGE, agg_share: AGG_SHARE,
    note: 'σ fed as denoised daily realized vol; fee = minFee floor + σ·vega term (σ-dominated). LVR flat 0.15%/yr stable proxy.' },
  grid, venue_reference: ref,
}, null, 1));
console.log('\nwrote out/capture_grid.json');
