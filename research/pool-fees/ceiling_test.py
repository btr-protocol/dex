"""Decisive ceiling test (expert-mandated, before any ML build).

Question: the per-bar ORACLE gate (perfect σ foresight) earns +37/+51% vs-rebal;
the causal hand gate (trailing σ) earns ~0/negative. How much of that gap is
reachable by a CAUSAL forecast — and does moving to DAILY granularity recover the
signal that per-bar noise destroys? If a daily causal forecast can't beat the hand
gate, the oracle gap is irreducible per-bar noise ⇒ ML is futile.

Gates compared (all on real f0(t), fixed ±5% reference width, vs-rebal carry):
  oracle_bar : deploy each BAR iff realized fee_bar ≥ lvr_bar      (perfect, per-bar)
  oracle_day : deploy each DAY  iff realized Σday(fee−lvr) ≥ 0     (perfect, daily = daily ceiling)
  causal_day : deploy each DAY  iff forecast Σday(fee−lvr) ≥ 0     (trailing-7d σ, causal)
  har_day    : same but σ forecast = HAR-RV (1d/7d/30d), causal-ish (in-sample = optimistic)
  hand_bar   : deploy each BAR iff forecast fee_bar ≥ lvr_bar      (trailing σ, the current gate)
"""
import json, math, statistics as st
from pathlib import Path
import numpy as np

HERE = Path(__file__).parent
LVR_CONST = 0.25
DT = 1800 / (365.25 * 86400)        # 30min in years
LN2_4 = math.sqrt(4 * math.log(2))


def lp_value(p, pl, ph):
    sq_pl = math.sqrt(max(pl, 1e-18)); inv_sq_ph = 1 / math.sqrt(max(ph, 1e-18))
    if p <= pl: return p * (1 / sq_pl - inv_sq_ph)
    if p >= ph: return 1 / inv_sq_ph - sq_pl
    return 2 * math.sqrt(p) - sq_pl - p * inv_sq_ph


def run(pair, kfile, ffile):
    k = json.load(open(kfile))
    # kline: [ts_ms, o, h, l, c, ...] OR dict
    def fld(r, i, *names):
        if isinstance(r, list): return r[i]
        for n in names:
            if n in r: return r[n]
    bars = []
    for r in k:
        ts = fld(r, 0, "ts", "t"); h = fld(r, 2, "high", "h"); l = fld(r, 3, "low", "l"); c = fld(r, 4, "close", "c")
        bars.append((int(ts), float(h), float(l), float(c)))
    # daily f0 lookup
    f0d = {}
    for line in open(ffile):
        if line.startswith("date"): continue
        d, f0, va = line.strip().split(",")
        f0d[int(d)] = float(f0)
    days_sorted = sorted(f0d)
    def f0_at(ts_ms):
        day = (ts_ms // 1000) // 86400 * 86400
        # forward-fill: latest day ≤ this
        import bisect
        i = bisect.bisect_right(days_sorted, day)
        return f0d[days_sorted[i - 1]] if i > 0 else f0d[days_sorted[0]]

    n = len(bars)
    sig = np.zeros(n); fee = np.zeros(n); lvr = np.zeros(n); day_idx = np.zeros(n, dtype=np.int64)
    for i, (ts, h, l, c) in enumerate(bars):
        s = abs(math.log(max(h, 1e-18) / max(l, 1e-18))) / LN2_4
        pl, ph = 0.95 * c, 1.05 * c
        lp = max(lp_value(c, pl, ph), 1e-18)
        sig[i] = s
        fee[i] = f0_at(ts) * DT                      # CE=1 at ±5% ref
        lvr[i] = LVR_CONST * s * s * math.sqrt(c) / lp
        day_idx[i] = (ts // 1000) // 86400

    years = (bars[-1][0] - bars[0][0]) / 1000 / (365.25 * 86400)
    ann = lambda x: x / years

    # trailing causal per-bar σ (48-bar window) -> hand gate
    W = 48
    sig_tr = np.zeros(n)
    cs = np.cumsum(sig);
    for i in range(n):
        lo = max(0, i - W); sig_tr[i] = (cs[i] - (cs[lo - 1] if lo > 0 else 0)) / (i - lo + 1)
    lvr_tr = LVR_CONST * sig_tr ** 2 * np.sqrt(np.array([b[3] for b in bars])) / (fee / (np.array([f0_at(b[0]) for b in bars]) * DT)).clip(1e-18)  # reuse lp via fee
    # simpler: recompute lvr_tr with trailing σ on same lp
    lp_arr = lvr / (LVR_CONST * sig ** 2 * np.sqrt(np.array([b[3] for b in bars]))).clip(1e-18)  # = 1/lp? invert
    # lp_arr above is messy; recompute cleanly:
    price = np.array([b[3] for b in bars])
    lpv = np.array([max(lp_value(c, 0.95 * c, 1.05 * c), 1e-18) for c in price])
    lvr_tr = LVR_CONST * sig_tr ** 2 * np.sqrt(price) / lpv

    net = fee - lvr            # realized per-bar vs-rebal
    # ---- gates ----
    res = {}
    res["oracle_bar"] = ann(net[net >= 0].sum())                      # deploy where realized fee≥lvr
    res["hand_bar"]   = ann(net[fee >= lvr_tr].sum())                 # gate on trailing σ (current)

    # daily aggregation
    udays = np.unique(day_idx)
    day_net = {d: net[day_idx == d].sum() for d in udays}
    day_sig = {d: sig[day_idx == d].mean() for d in udays}
    # oracle_day: deploy whole day if realized day_net≥0
    res["oracle_day"] = ann(sum(v for v in day_net.values() if v >= 0))
    # causal_day: forecast day σ = trailing 7-day mean of daily σ; predict day_net sign via σ
    dser = list(udays); dsig = np.array([day_sig[d] for d in dser]); dnet = np.array([day_net[d] for d in dser])
    fc7 = np.zeros(len(dser))
    for j in range(len(dser)):
        lo = max(0, j - 7); fc7[j] = dsig[lo:j].mean() if j > lo else dsig[j]
    # decision: deploy day j if forecast day_net ≥ 0. Forecast day_net = day_fee - day_lvr(fc σ).
    # day_fee ≈ (#bars*f0*DT); day_lvr scales with σ². Use ratio test: realized fee vs lvr(fcσ).
    day_fee = {d: fee[day_idx == d].sum() for d in udays}
    day_lp = {d: lpv[day_idx == d].mean() for d in udays}
    day_px = {d: price[day_idx == d].mean() for d in udays}
    day_nb = {d: int((day_idx == d).sum()) for d in udays}
    fc_lvr = np.array([LVR_CONST * fc7[j] ** 2 * math.sqrt(day_px[dser[j]]) / day_lp[dser[j]] * day_nb[dser[j]] for j in range(len(dser))])
    dfee = np.array([day_fee[d] for d in dser])
    res["causal_day"] = ann(sum(dnet[j] for j in range(len(dser)) if dfee[j] >= fc_lvr[j]))

    # HAR-RV daily forecast (in-sample OLS, optimistic ceiling): RV_{d+1} ~ RV_d, RV_7, RV_30
    rv = dsig ** 2
    X = []; Y = []
    for j in range(30, len(dser) - 1):
        X.append([1, rv[j], rv[j-7:j].mean(), rv[j-30:j].mean()]); Y.append(rv[j+1])
    X = np.array(X); Y = np.array(Y)
    beta, *_ = np.linalg.lstsq(X, Y, rcond=None)
    har_sig = np.sqrt(np.clip(X @ beta, 1e-12, None))
    # map back to days 31..end-1
    har_lvr = np.array([LVR_CONST * har_sig[j-31] ** 2 * math.sqrt(day_px[dser[j]]) / day_lp[dser[j]] * day_nb[dser[j]] for j in range(31, len(dser)-1)])
    har_net = ann(sum(dnet[j] for j in range(31, len(dser)-1) if dfee[j] >= har_lvr[j-31]))
    res["har_day_insample"] = har_net
    # IC of HAR forecast
    ic = np.corrcoef(har_sig, np.sqrt(Y))[0, 1]
    print(f"\n=== {pair} ({years:.2f}y, {len(udays)} days) — annualized vs-rebal % per gate ===")
    for kk in ["oracle_bar", "oracle_day", "har_day_insample", "causal_day", "hand_bar"]:
        print(f"  {kk:18s} {res[kk]*100:+7.2f}%")
    print(f"  HAR-RV daily σ IC (in-sample): {ic:.3f}")
    print(f"  reachable fraction (oracle_day/oracle_bar): {res['oracle_day']/max(res['oracle_bar'],1e-9):.0%}")
    return res


if __name__ == "__main__":
    import sys
    a = sys.argv[1:]
    if len(a) >= 3:
        for i in range(0, len(a) - 2, 3):
            run(a[i], a[i + 1], a[i + 2])
    else:
        run("BTCBUSDT", "../../data/klines/BTCBUSDT_30m.json", "../../data/fees/BTCBUSDT_fees.csv")
        run("BNBUSDT", "../../data/klines/BNBUSDT_30m.json", "../../data/fees/BNBUSDT_fees.csv")
