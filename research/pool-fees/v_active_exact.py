"""EXACT V_active via on-chain tick-liquidity reconstruction.

Replaces the FLAT-spread approximation (cluster_mark.v_active_usd: spreads the
active-tick L uniformly over +/-5%) with the TRUE decaying-liquidity integral:
reconstruct liquidityNet from Mint/Burn, prefix-sum to get L(tick), and integrate
getAmountsForLiquidity over the +/-5% band, valued at the NXR USD price.

INPUTS (per pool):
  <prefix>_lp.bin      : '<q i i d b' = (ts_ms, tickLower, tickUpper, liq_amount, is_mint)
  <prefix>_swtick.bin  : '<q i d'     = (ts_ms, tick, liquidity)  [reconciliation ground truth]
  <marked.csv>         : date,net_usd,fee_usd,arb_lvr_usd,swaps,v_active_usd,btc_price
                         (btc_price = NXR USD price of the BTC leg; band center)

TICK / SIGN discipline (audit-critical):
  Mint(amount): liquidityNet[tickLower] += amount ; liquidityNet[tickUpper] -= amount
  Burn(amount): liquidityNet[tickLower] -= amount ; liquidityNet[tickUpper] += amount
  amount is uint128 (>=0). L_active(tick) = sum of liquidityNet over all edges <= tick.
  Reconcile L_active(swap_tick) vs Swap.liquidity → drift must converge to ~0.

PRICE / SCALING (per pool token ordering, VERIFIED on-chain):
  pool raw price P_raw = token1/token0 (raw integer units) = 1.0001**tick
  human price (token1 per token0) = P_raw * 10**(d0 - d1)
  sqrtP_raw = 1.0001**(tick/2)
  getAmountsForLiquidity(L, sa, sb, sc) in RAW token units (sa<sb sqrtP at range edges,
  sc current sqrtP):
    if sc<=sa:  amt0 = L*(1/sa - 1/sb); amt1 = 0
    if sc>=sb:  amt0 = 0;               amt1 = L*(sb - sa)
    else:       amt0 = L*(1/sc - 1/sb); amt1 = L*(sc - sa)
  token units = raw/10**d ; USD = amt0_tok*p0_usd + amt1_tok*p1_usd.

Usage:
  v_active_exact.py <prefix> <marked.csv> <d0> <d1> <usd_token> <pool_kind> <out.csv>
    pool_kind ∈ {btcb_usdt, wbtc_usdt, cbbtc_usdc} — selects price→tick mapping +
    which leg is the BTC leg priced at btc_price.
"""
import sys, math, struct, bisect, csv
from pathlib import Path

LOG_1_0001 = math.log(1.0001)


def price_to_tick_raw(p_raw: float) -> float:
    return math.log(p_raw) / LOG_1_0001


def sqrtp_raw(tick: float) -> float:
    return 1.0001 ** (tick * 0.5)


def load_lp(path):
    """→ list of (ts_ms, tickLower, tickUpper, liq_int, is_mint), sorted by ts.
    liq is an EXACT Python int (from u128-LE bytes) — no f64 precision loss."""
    raw = Path(path).read_bytes()
    rec = struct.Struct("<qii16sb")
    out = []
    for o in range(0, len(raw) - len(raw) % rec.size, rec.size):
        ts, tl, tu, lb, im = rec.unpack_from(raw, o)
        out.append((ts, tl, tu, int.from_bytes(lb, "little"), im))
    out.sort(key=lambda r: r[0])
    return out


def load_swtick(path):
    """→ list of (ts_ms, tick, liq_int), sorted by ts. liq exact Python int."""
    raw = Path(path).read_bytes()
    rec = struct.Struct("<qi16s")
    out = []
    for o in range(0, len(raw) - len(raw) % rec.size, rec.size):
        ts, tk, lb = rec.unpack_from(raw, o)
        out.append((ts, tk, int.from_bytes(lb, "little")))
    out.sort(key=lambda r: r[0])
    return out


def build_net_timeline(lp):
    """Apply Mint/Burn in time order, snapshotting the cumulative liquidityNet map
    as a sorted (ticks, prefix_L) once per UTC day boundary is crossed at query time.
    Here we just return the event list; the day-state is built incrementally in main."""
    return lp


def amounts_for_liquidity(L, sa, sb, sc):
    """RAW token0, token1 amounts for liquidity L over [sa,sb] at current sqrtP sc."""
    if sa > sb:
        sa, sb = sb, sa
    if sc <= sa:
        return L * (1.0 / sa - 1.0 / sb), 0.0
    if sc >= sb:
        return 0.0, L * (sb - sa)
    return L * (1.0 / sc - 1.0 / sb), L * (sc - sa)


def v_active_exact(net_ticks, net_prefixL, sc_raw, sa_band, sb_band, d0, d1, p0_usd, p1_usd):
    """Integrate L(tick) over the price band [sa_band, sb_band] (raw sqrtP), summing
    getAmountsForLiquidity per initialized sub-range, valued in USD.

    net_ticks: sorted initialized ticks. net_prefixL[i] = active L on the interval
    [net_ticks[i], net_ticks[i+1]). sc_raw = current sqrtP (raw). Band edges are raw
    sqrtP. We clip sub-range edges to the band."""
    if not net_ticks:
        return 0.0
    lo = min(sa_band, sb_band)
    hi = max(sa_band, sb_band)
    amt0 = amt1 = 0.0
    n = len(net_ticks)
    # iterate intervals [net_ticks[i], net_ticks[i+1]) with constant L = net_prefixL[i]
    for i in range(n - 1):
        L = net_prefixL[i]
        if L <= 0:
            continue
        s_lo = sqrtp_raw(net_ticks[i])
        s_hi = sqrtp_raw(net_ticks[i + 1])
        # clip to band
        a = max(s_lo, lo)
        b = min(s_hi, hi)
        if a >= b:
            continue
        x0, x1 = amounts_for_liquidity(L, a, b, sc_raw)
        amt0 += x0
        amt1 += x1
    t0 = amt0 / 10 ** d0
    t1 = amt1 / 10 ** d1
    return t0 * p0_usd + t1 * p1_usd


def main(prefix, marked_csv, d0, d1, usd_token, pool_kind, out_csv):
    lp = load_lp(f"{prefix}_lp.bin")
    sw_path = Path(f"{prefix}_swtick.bin")
    sw = load_swtick(str(sw_path)) if sw_path.exists() and sw_path.stat().st_size > 0 else []
    print(f"  loaded {len(lp):,} mint/burn, {len(sw):,} swaps", flush=True)

    # ---- RECONCILIATION: replay liquidityNet, compare cur_L vs Swap.liquidity ----
    # Ground-truth check: at a SAMPLED set of swaps (~1 per hour, post-warmup) rebuild
    # the active L from the net map as of that swap's time and compare to Swap.liquidity.
    # cur_L(tick) = sum of net[t] for t <= tick = bisect-prefix over sorted (ticks,prefix).
    # This is O(#samples * log#ticks + #lp), not O(#swaps * #ticks).
    from collections import defaultdict
    import bisect as _bi
    net = defaultdict(int)  # tick -> signed net liquidity (EXACT int, cumulative)
    li = 0
    drift_samples = []  # (abs_drift, rel_drift)
    warmup_ms = lp[0][0] + 7 * 86400_000 if lp else 0   # 7-day warmup after first LP
    last_sample_ms = -1
    SAMPLE_GAP_MS = 3600_000  # 1 sample/hour
    # cached snapshot of sorted ticks + prefix (rebuilt lazily when net changed)
    dirty = True
    snap_ticks, snap_prefix = [], []

    def rebuild_snapshot():
        nonlocal snap_ticks, snap_prefix, dirty
        items = sorted((t, v) for t, v in net.items() if v != 0)
        snap_ticks = [t for t, _ in items]
        snap_prefix = []
        acc = 0
        for _, v in items:
            acc += v
            snap_prefix.append(acc)   # exact int active L on [ticks[i], ticks[i+1])
        dirty = False

    def active_L_at(tick):
        # active L on the interval containing `tick` = prefix at rightmost edge <= tick
        if not snap_ticks:
            return 0
        idx = _bi.bisect_right(snap_ticks, tick) - 1
        return snap_prefix[idx] if idx >= 0 else 0

    for sts, stick, sliq in sw:
        while li < len(lp) and lp[li][0] <= sts:
            _, tl, tu, amt, is_mint = lp[li]
            sign = 1 if is_mint else -1
            net[tl] += sign * amt
            net[tu] -= sign * amt
            dirty = True
            li += 1
        if sts < warmup_ms or sliq <= 0:
            continue
        if sts - last_sample_ms < SAMPLE_GAP_MS:
            continue
        last_sample_ms = sts
        if dirty:
            rebuild_snapshot()
        cur_L = active_L_at(stick)
        drift = cur_L - sliq
        drift_samples.append((abs(drift), abs(drift) / sliq))
    if drift_samples:
        rels = sorted(d[1] for d in drift_samples)
        med_rel = rels[len(rels) // 2]
        p90_rel = rels[len(rels) * 9 // 10]
        max_rel = rels[-1]
        print(f"  RECONCILE drift (cur_L vs Swap.liquidity, n={len(drift_samples):,} hourly samples): "
              f"median_rel={med_rel:.2e} p90_rel={p90_rel:.2e} max_rel={max_rel:.2e}", flush=True)
    else:
        print("  RECONCILE: no drift samples")

    # ---- DAILY EXACT V_active ----
    # Re-replay LP up to each day's end, snapshot the net map → sorted ticks + prefix L,
    # then integrate over the +/-5% band centered at that day's NXR price.
    # ---- STRUCTURAL INVARIANTS (sign discipline) over the FULL LP set ----
    full_net = defaultdict(int)
    for _, tl, tu, amt, is_mint in lp:
        sign = 1 if is_mint else -1
        full_net[tl] += sign * amt
        full_net[tu] -= sign * amt
    tot = sum(full_net.values())
    # prefix-sum L must be >= 0 everywhere (no negative active liquidity)
    acc = 0
    min_pref = 0
    for t in sorted(full_net):
        acc += full_net[t]
        if acc < min_pref:
            min_pref = acc
    print(f"  INVARIANTS: Σ liquidityNet = {tot} (must be 0); min prefix-L = {min_pref} "
          f"(must be ≥0) → {'OK' if tot == 0 and min_pref >= 0 else 'VIOLATION'}", flush=True)

    rows = list(csv.DictReader(open(marked_csv)))
    # event pointer for incremental day-state
    netd = defaultdict(int)
    lp_ptr = 0
    out_rows = []
    W = 0.05
    for r in rows:
        day_secs = int(r["date"])
        day_end_ms = (day_secs + 86400) * 1000  # liquidity state at end of the day
        btc = float(r["btc_price"])
        while lp_ptr < len(lp) and lp[lp_ptr][0] < day_end_ms:
            _, tl, tu, amt, is_mint = lp[lp_ptr]
            sign = 1 if is_mint else -1
            netd[tl] += sign * amt
            netd[tu] -= sign * amt
            lp_ptr += 1
        # snapshot sorted ticks + prefix L (exact ints; cast to float only in integral)
        items = sorted((t, v) for t, v in netd.items() if v != 0)
        ticks = [t for t, _ in items]
        prefix = []
        acc = 0
        for _, v in items:
            acc += v
            prefix.append(acc)  # active L on [ticks[i], ticks[i+1])
        # price → tick (per pool token ordering)
        if pool_kind == "btcb_usdt":      # t0=USDT(18), t1=BTCB(18); P_raw=BTCB/USDT=1/btc *10^0
            p_raw = (1.0 / btc) * 10 ** (d1 - d0)
            p0_usd, p1_usd = 1.0, btc
        elif pool_kind == "wbtc_usdt":    # t0=WBTC(8), t1=USDT(6); P_raw=USDT/WBTC=btc *10^(d1-d0)
            p_raw = btc * 10 ** (d1 - d0)
            p0_usd, p1_usd = btc, 1.0
        elif pool_kind == "cbbtc_usdc":   # t0=USDC(6), t1=cbBTC(8); P_raw=cbBTC/USDC=1/btc *10^(d1-d0)
            p_raw = (1.0 / btc) * 10 ** (d1 - d0)
            p0_usd, p1_usd = 1.0, btc
        else:
            raise SystemExit(f"unknown pool_kind {pool_kind}")
        if p_raw <= 0 or not ticks:
            out_rows.append((day_secs, 0.0, r))
            continue
        sc = math.sqrt(p_raw)
        # band: +/-5% in HUMAN price. human ∝ p_raw (monotone), so band in raw price =
        # p_raw*(1-W) .. p_raw*(1+W). sqrtP edges = sqrt of those (raw sqrtP space).
        sa = math.sqrt(p_raw * (1 - W))
        sb = math.sqrt(p_raw * (1 + W))
        v = v_active_exact(ticks, prefix, sc, sa, sb, d0, d1, p0_usd, p1_usd)
        out_rows.append((day_secs, v, r))

    # write exact-V marked csv (same schema as marked, V replaced)
    with open(out_csv, "w") as o:
        o.write("date,net_usd,fee_usd,arb_lvr_usd,swaps,v_active_usd,btc_price\n")
        for day_secs, v, r in out_rows:
            o.write(f"{day_secs},{r['net_usd']},{r['fee_usd']},{r['arb_lvr_usd']},"
                    f"{r['swaps']},{v:.1f},{r['btc_price']}\n")
    vs = [v for _, v, _ in out_rows if v > 0]
    import statistics as st
    if vs:
        print(f"  EXACT V_active: mean ${st.mean(vs)/1e6:.3f}M median ${st.median(vs)/1e6:.3f}M "
              f"(n={len(vs)} days) → {out_csv}", flush=True)


if __name__ == "__main__":
    _, prefix, marked, d0, d1, ut, kind, out = sys.argv
    main(prefix, marked, int(d0), int(d1), int(ut), kind, out)
