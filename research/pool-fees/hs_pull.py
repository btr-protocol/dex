"""HyperSync v3 pool event puller + real-fee computer.

Pulls Swap (and optionally Mint/Burn) logs for a set of v3 pools over a block
range, decodes the first 5 data words (amount0, amount1, sqrtPriceX96, liquidity,
tick) — identical layout for Uniswap-v3 (7-field) and PancakeSwap-v3 (9-field)
Swaps — and writes a compact per-pool parquet/jsonl. From these we compute real
trading volume, fee revenue (vol*feeTier), and the active-liquidity series
(the `liquidity` field = L_active at each swap) used for our fee share + dilution.

Token is read from the gitignored hypersync.env. 100 rpm Starter plan → the
client's proactive_rate_limit_sleep + max events/request keep us under the cap.
"""
import asyncio
import os
import sys
import json
from pathlib import Path

import hypersync
from hypersync import (
    HypersyncClient, ClientConfig, Query, LogSelection, FieldSelection,
    LogField, BlockField, StreamConfig, HexOutput,
)

HERE = Path(__file__).parent
# Load token from gitignored env (never hard-code / echo).
for line in (HERE / "hypersync.env").read_text().splitlines():
    if line.startswith("HYPERSYNC_BEARER_TOKEN="):
        os.environ["HYPERSYNC_BEARER_TOKEN"] = line.split("=", 1)[1].strip()
TOKEN = os.environ["HYPERSYNC_BEARER_TOKEN"]

ENDPOINTS = {
    "bsc": "https://bsc.hypersync.xyz",
    "base": "https://base.hypersync.xyz",
    "eth": "https://eth.hypersync.xyz",
    "arbitrum": "https://arbitrum.hypersync.xyz",
}
# Swap topic0: Uni-v3 (7-field) and PancakeSwap-v3 (9-field) differ; query both.
SWAP_T0 = [
    "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67",  # uni v3
    "0x19b47279256b2a23a1665c810c8d55a1758940ee09377d4f8d26497a3577dc83",  # pcs v3
]


def _to_int(h: str, signed: bool, bits: int) -> int:
    v = int(h, 16)
    if signed and v >= (1 << (bits - 1)):
        v -= 1 << bits
    return v


def decode_swap_data(data_hex: str):
    """First 5 ABI words of a v3 Swap: amount0,int256; amount1,int256;
    sqrtPriceX96,uint160; liquidity,uint128; tick,int24. (pcs trailing
    protocolFees words ignored.)"""
    h = data_hex[2:] if data_hex.startswith("0x") else data_hex
    w = [h[i * 64:(i + 1) * 64] for i in range(5)]
    if len(w) < 5 or len(w[4]) < 64:
        return None
    return {
        "amount0": _to_int(w[0], True, 256),
        "amount1": _to_int(w[1], True, 256),
        "sqrtPriceX96": int(w[2], 16),
        "liquidity": int(w[3], 16),
        # int24 is ABI-encoded sign-extended into the full 256-bit word.
        "tick": _to_int(w[4], True, 256),
    }


async def validate(chain: str, pool: str, lookback_blocks: int):
    client = HypersyncClient(ClientConfig(url=ENDPOINTS[chain], bearer_token=TOKEN,
                                          proactive_rate_limit_sleep=True))
    height = await client.get_height()
    from_block = max(0, height - lookback_blocks)
    print(f"[{chain}] head={height:,} querying {pool} from {from_block:,}")
    q = Query(
        from_block=from_block,
        logs=[LogSelection(address=[pool], topics=[SWAP_T0])],
        field_selection=FieldSelection(
            block=[BlockField.NUMBER, BlockField.TIMESTAMP],
            log=[LogField.BLOCK_NUMBER, LogField.DATA, LogField.TOPIC0,
                 LogField.ADDRESS, LogField.LOG_INDEX],
        ),
    )
    res = await client.get(q)
    logs = res.data.logs
    print(f"  one get() returned {len(logs)} swap logs; next_block={res.next_block:,} "
          f"(archive_height={res.archive_height})")
    sample = []
    for lg in logs[:3]:
        d = decode_swap_data(lg.data)
        sample.append(d)
    for s in sample:
        print("  sample:", s)
    return len(logs), res.next_block, height


import math


def v_active_usd(liq: float, sqrtp: float, d0: int, d1: int, usd_token: int, w: float = 0.05):
    """USD value of `liq` spread over ±w around the current price (L-const). Mirrors
    the on-chain V_active measurement. usd_token = index (0|1) of the USD-stable leg."""
    s = sqrtp / 2 ** 96
    if s <= 0:
        return 0.0
    price = s * s * 10 ** (d0 - d1)  # token1 per token0 (human)
    sa, sb = s * math.sqrt(1 - w), s * math.sqrt(1 + w)
    amt1 = liq * (s - sa) / 10 ** d1
    amt0 = liq * (1 / s - 1 / sb) / 10 ** d0
    if usd_token == 0:       # token0 = USD stable
        return amt0 + amt1 / max(price, 1e-30)
    return amt1 + amt0 * price  # token1 = USD stable


def _lp_value(P, Pa, Pb):
    """v3 position value per unit liquidity at external price P (token1 numeraire)."""
    sPa, sPb = math.sqrt(Pa), math.sqrt(Pb)
    if P <= Pa:
        return P * (1 / sPa - 1 / sPb)
    if P >= Pb:
        return sPb - sPa
    return 2 * math.sqrt(P) - sPa - P / sPb


def _x0(P, Pa, Pb):
    """token0 (base) holding per unit liquidity at P, clamped to the range."""
    Pc = min(max(P, Pa), Pb)
    return 1 / math.sqrt(Pc) - 1 / math.sqrt(Pb)


async def pull_daily(chain, pool, fee_bps, start_block, end_block, usd_token, d0, d1, out_path):
    """Paginate Swaps start→end, aggregate per UTC-day: volume_usd, fee_usd, swaps,
    mean active-liquidity, mean sqrtPrice → real f0(t)=fee*365/V_active. Writes JSONL."""
    client = HypersyncClient(ClientConfig(url=ENDPOINTS[chain], bearer_token=TOKEN,
                                          proactive_rate_limit_sleep=True))
    fee_frac = fee_bps / 1e4
    days = {}  # day -> [vol_usd, swaps, sumL, sumSqrtP]
    # Measure-from-swaps realized LVR: a ±5% reference position recentered at each
    # day's first swap; LVR_i = x_{i-1}(P_i−P_{i-1}) − [V(P_i)−V(P_{i-1})] over the
    # real post-swap price path (no-arb gaps contribute 0 automatically).
    lvr_day = {}
    v0_day = {}
    cur_day = None
    gPa = gPb = prevP = 0.0
    W_LVR = 0.05
    blk = start_block
    reqs = 0
    while blk < end_block:
        q = Query(
            from_block=blk, to_block=end_block,
            logs=[LogSelection(address=[pool], topics=[SWAP_T0])],
            field_selection=FieldSelection(
                block=[BlockField.NUMBER, BlockField.TIMESTAMP],
                log=[LogField.BLOCK_NUMBER, LogField.DATA]),
        )
        res = await client.get(q)
        reqs += 1
        # block ts lookup
        ts_of = {b.number: int(b.timestamp, 16) for b in (res.data.blocks or [])}
        for lg in res.data.logs:
            d = decode_swap_data(lg.data)
            if d is None:
                continue
            amt = d["amount0"] if usd_token == 0 else d["amount1"]
            vol = abs(amt) / 10 ** (d0 if usd_token == 0 else d1)
            ts = ts_of.get(lg.block_number, 0)
            day = ts // 86400
            r = days.setdefault(day, [0.0, 0, 0.0, 0.0])
            r[0] += vol
            r[1] += 1
            r[2] += d["liquidity"]
            r[3] += d["sqrtPriceX96"]
            # realized-LVR accumulation on the real price path
            P = (d["sqrtPriceX96"] / 2 ** 96) ** 2
            if P > 0:
                if day != cur_day:
                    cur_day = day
                    gPa, gPb = P * (1 - W_LVR), P * (1 + W_LVR)
                    v0_day[day] = _lp_value(P, gPa, gPb)
                    lvr_day[day] = 0.0
                    prevP = P
                elif gPb > 0:
                    x = _x0(prevP, gPa, gPb)
                    lvr_day[day] += x * (P - prevP) - (_lp_value(P, gPa, gPb) - _lp_value(prevP, gPa, gPb))
                    prevP = P
        nb = res.next_block
        if nb <= blk:
            break
        blk = nb
        if reqs % 25 == 0:
            print(f"  [{pool[:10]}] req {reqs}, block {blk:,}/{end_block:,}, days {len(days)}", flush=True)
    # write daily series
    rows = []
    for day in sorted(days):
        vol, n, sumL, sumS = days[day]
        meanL = sumL / n
        meanS = sumS / n
        vact = v_active_usd(meanL, meanS, d0, d1, usd_token)
        fee = vol * fee_frac
        f0 = fee * 365.0 / vact if vact > 0 else 0.0
        # realized-LVR APR for the ±5% daily-recentered reference (frac/day × 365).
        rlvr = (lvr_day.get(day, 0.0) / v0_day.get(day, 1e-18)) * 365.0
        rows.append({"date": day * 86400, "volume_usd": vol, "fee_usd": fee, "swaps": n,
                     "mean_liq": meanL, "v_active_usd": vact, "f0_apr": f0, "real_lvr_apr": rlvr})
    Path(out_path).write_text("\n".join(json.dumps(r) for r in rows))
    tot_vol = sum(r["volume_usd"] for r in rows)
    tot_fee = sum(r["fee_usd"] for r in rows)
    mean_v = sum(r["v_active_usd"] for r in rows) / max(len(rows), 1)
    print(f"DONE {pool}: {len(rows)} days, {reqs} reqs, Σvol ${tot_vol/1e9:.2f}B, "
          f"Σfee ${tot_fee/1e6:.2f}M, meanVact ${mean_v/1e6:.2f}M")
    import statistics as st
    f0s = [r["f0_apr"] for r in rows if r["f0_apr"] > 0]
    if f0s:
        print(f"  REAL active-range f0(t): mean {st.mean(f0s):.2f}, median {st.median(f0s):.2f}, "
              f"p10 {sorted(f0s)[len(f0s)//10]:.2f}, p90 {sorted(f0s)[len(f0s)*9//10]:.2f}")
    rlvrs = [r["real_lvr_apr"] for r in rows]
    if rlvrs:
        print(f"  ⭐ MEASURED LVR(t) APR (±5% daily-recentered, from swap path): "
              f"mean {st.mean(rlvrs):.2f}, median {st.median(rlvrs):.2f} "
              f"→ vs frictionless≈f0/(f0·σ²); compare to model LVR% in backtest")
    return out_path


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "validate"
    if mode == "validate":
        asyncio.run(validate("bsc", "0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4", 200_000))
    elif mode == "daily":
        # daily <chain> <pool> <fee_bps> <start_block> <end_block> <usd_token> <d0> <d1> <out>
        _, _, chain, pool, fee_bps, sb, eb, usd_token, d0, d1, out = sys.argv
        asyncio.run(pull_daily(chain, pool, float(fee_bps), int(sb), int(eb),
                               int(usd_token), int(d0), int(d1), out))
