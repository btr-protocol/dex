"""Prod real-time on-chain collector for the BTR ALM.

Continuously polls HyperSync for each target BTC pool's Swaps, marks every swap at
the NXR live CEX mid (the SAME ground-truth marking as cluster_mark.py:
net = a0*e0 + a1*e1 at the external price = fee - arb_LVR vs a constant-mix
rebalancer), maintains rolling-window live metrics (f0_apr, arb_lvr_apr, net_apr,
V_active, utilization, price/tick), and writes a per-pool JSON snapshot that the
monitor / front-end reads. Respects the HyperSync 100rpm Starter cap via the
client's proactive_rate_limit_sleep + a poll interval.

Reuses the proven hs_pull primitives (client, decode, V_active, endpoints, token).
NXR live mid via the same GET {base}/v1/ohlc/{SYM}?tf=30 endpoint the keeper uses
(keepers/src/daemon/nxr.rs) — last 30s bar close.

Run:
  python3 collector.py once     # one poll cycle for every pool (test)
  python3 collector.py          # continuous daemon
Env (optional): NXR_API_KEY (sent as x-api-key if present), NXR_API_URL
(default https://api.nxrates.com), BTR_LIVE_DIR (default ../../data/live),
BTR_POLL_S (default 45), BTR_WINDOW_DAYS (default 7).
"""
import asyncio
import json
import os
import sys
import time
import urllib.request
import urllib.parse
from collections import deque
from pathlib import Path

import hs_pull
from hypersync import (
    HypersyncClient, ClientConfig, Query, LogSelection, FieldSelection,
    LogField, BlockField,
)

HERE = Path(__file__).parent
LIVE_DIR = Path(os.environ.get("BTR_LIVE_DIR", HERE / "../../data/live")).resolve()
NXR_URL = os.environ.get("NXR_API_URL", "https://api.nxrates.com").rstrip("/")
NXR_KEY = os.environ.get("NXR_API_KEY", "")
POLL_S = int(os.environ.get("BTR_POLL_S", "45"))
WINDOW_DAYS = int(os.environ.get("BTR_WINDOW_DAYS", "7"))
WINDOW_MS = WINDOW_DAYS * 86400 * 1000
YEAR_S = 365.0 * 86400.0

# The 3 deployable BTC pools (on-chain-verified token order + decimals; usd_token =
# index of the USD-stable leg). Mirrors keepers/alm.toml.
POOLS = [
    {"name": "bsc-BTCB-USDT",  "chain": "bsc",  "address": "0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4",
     "fee_bps": 5,  "usd_token": 0, "d0": 18, "d1": 18, "nxr_sym": "BTC-USDT", "tick_spacing": 10},
    {"name": "eth-WBTC-USDT",  "chain": "eth",  "address": "0x9Db9e0e53058C89e5B94e29621a205198648425B",
     "fee_bps": 30, "usd_token": 1, "d0": 8,  "d1": 6,  "nxr_sym": "BTC-USDT", "tick_spacing": 60},
    {"name": "base-cbBTC-USDC", "chain": "base", "address": "0x4e962bb3889bf030368f56810a9c96b83cb3e778",
     "fee_bps": 5,  "usd_token": 0, "d0": 6,  "d1": 8,  "nxr_sym": "BTC-USDT", "tick_spacing": 100},
]

# ── BTR vault/adapter (CLAdapter `Dex`) event topics (cast keccak of the sigs) ──
EV_REBALANCED = "0xc2df45ace19779c8cee33727e1cf9829c78beb3141250e153674e7825f631dad"  # Rebalanced(int24,int24,uint128)
EV_PULLED     = "0x8f6dc746d2ddfc02adada7fa1b00410b478496d5fed7a2b9020322b3959fe9ee"  # Pulled(address,uint256)
EV_WITHDRAWN  = "0x7084f5476618d8e60b11ef0d7d3f06914655adb8793e28ff7f018d4c76d505d5"  # Withdrawn(address,uint256)
EV_KILLED     = "0x4b0bc4f25f8d0b92d2e12b686ba96cd75e4e69325e6cf7b1f3119d14eaf2cbdf"  # Killed(address)
ZERO_ADDR = "0x0000000000000000000000000000000000000000"


def _word(hexstr: str, i: int) -> str:
    """The i-th 32-byte ABI word of a 0x data blob."""
    h = hexstr[2:] if hexstr.startswith("0x") else hexstr
    return h[i * 64:(i + 1) * 64]


def _i24(word: str) -> int:
    """A 32-byte word holding a sign-extended int24 → python int."""
    v = int(word, 16)
    return v - (1 << 256) if v >= (1 << 255) else v


def decode_rebalanced(data: str):
    """Rebalanced(tickLower int24, tickUpper int24, liquidity uint128) — all unindexed (in data).
    Returns (tick_lower, tick_upper, liquidity). (0,0,0) ⇒ exit/neutral (no LP)."""
    return _i24(_word(data, 0)), _i24(_word(data, 1)), int(_word(data, 2), 16)


# ── NXR live CEX mid (same endpoint as the keeper) ──────────────────────────────
def nxr_mid(sym: str) -> float:
    """Latest 30s-bar close for `sym` from NXR (CEX truth). 0.0 on failure."""
    now = int(time.time() * 1000)
    qs = urllib.parse.urlencode({"tf": 30, "from": now - 5 * 60_000, "to": now})
    req = urllib.request.Request(f"{NXR_URL}/v1/ohlc/{urllib.parse.quote(sym)}?{qs}",
                                 headers={"accept": "application/json"})
    if NXR_KEY:
        req.add_header("x-api-key", NXR_KEY)
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            rows = json.load(r)
        if rows:
            last = rows[-1]
            return float(last.get("close") or last.get("c") or 0.0)
    except Exception as e:
        print(f"  [nxr] {sym} mark failed: {e}", flush=True)
    return 0.0


def pool_price_usd(sqrtp: float, d0: int, d1: int, usd_token: int) -> float:
    """USD/BTC price from a swap's sqrtPriceX96 — fallback when NXR is unavailable.
    For an arbitraged BTC pool this tracks the CEX mid closely; NXR is preferred for
    precision but this keeps the collector self-sufficient."""
    s = sqrtp / 2 ** 96
    ph = s * s * 10 ** (d0 - d1)          # token1 per token0 (human)
    if ph <= 0:
        return 0.0
    return ph if usd_token == 1 else 1.0 / ph


# ── per-swap marking (ground-truth, == cluster_mark.py) ─────────────────────────
def mark_swap(a0: float, a1: float, price: float, usd_token: int, fee_frac: float):
    """a0,a1 = decimal-scaled signed pool reserve deltas; price = NXR USD/BTC mid.
    Returns (fee_usd, net_usd, arb_lvr_usd). net = value-change at external price
    = fee - arb_LVR (LP edge vs constant-mix rebalancer)."""
    e0, e1 = (1.0, price) if usd_token == 0 else (price, 1.0)
    net = a0 * e0 + a1 * e1
    in_usd = a0 * e0 if a0 > 0 else a1 * e1
    fee = abs(in_usd) * fee_frac
    return fee, net, fee - net


# ── rolling-window state (persisted so restarts resume) ─────────────────────────
class PoolState:
    def __init__(self, cfg):
        self.cfg = cfg
        self.cursor = 0                 # last processed block
        self.win = deque()              # (ts_ms, fee, arb_lvr, vol_usd, v_active, liq, sqrtp, tick)
        self.last_price = 0.0
        self.last_tick = 0
        # BTR vault/adapter state (populated once the adapter is deployed + configured).
        self.vault_cursor = 0
        self.vault = {"range": None, "liquidity": 0, "killed": False,
                      "last_rebalance_ms": 0, "total_pulled": 0.0, "total_withdrawn": 0.0,
                      "deployed": None}

    def path(self):
        return LIVE_DIR / f"{self.cfg['name']}.json"

    def state_path(self):
        return LIVE_DIR / f".{self.cfg['name']}.state.json"

    def load(self):
        p = self.state_path()
        if p.exists():
            d = json.loads(p.read_text())
            self.cursor = d.get("cursor", 0)
            self.win = deque(tuple(x) for x in d.get("win", []))

    def save_state(self):
        self.state_path().write_text(json.dumps(
            {"cursor": self.cursor, "win": list(self.win)}))

    def trim(self, now_ms):
        lo = now_ms - WINDOW_MS
        while self.win and self.win[0][0] < lo:
            self.win.popleft()

    def metrics(self, lo_ms, hi_ms):
        seg = [x for x in self.win if lo_ms <= x[0] <= hi_ms]
        if not seg:
            return None
        fee = sum(x[1] for x in seg)
        lvr = sum(x[2] for x in seg)
        vol = sum(x[3] for x in seg)
        vact = sum(x[4] for x in seg) / len(seg)         # mean active depth
        span_s = max((hi_ms - lo_ms) / 1000.0, 1.0)
        ann = YEAR_S / span_s
        f0 = fee * ann / vact if vact > 0 else 0.0
        lvr_apr = lvr * ann / vact if vact > 0 else 0.0
        net = fee - lvr
        return {
            "swaps": len(seg), "vol_usd": vol, "fee_usd": fee, "arb_lvr_usd": lvr,
            "net_usd": net, "v_active_usd": vact, "f0_apr": f0, "arb_lvr_apr": lvr_apr,
            "net_apr": f0 - lvr_apr, "margin_pct": (net / fee * 100.0) if fee else 0.0,
            "utilization": vol * ann / vact if vact > 0 else 0.0,  # annualized turnover
        }

    def snapshot(self, now_ms, head):
        self.trim(now_ms)
        out = {
            "name": self.cfg["name"], "chain": self.cfg["chain"], "pool": self.cfg["address"],
            "fee_bps": self.cfg["fee_bps"], "updated_ms": now_ms, "head_block": head,
            "cursor_block": self.cursor, "price": self.last_price, "tick": self.last_tick,
            "w24h": self.metrics(now_ms - 86400_000, now_ms),
            "w7d": self.metrics(now_ms - WINDOW_MS, now_ms),
        }
        self.path().write_text(json.dumps(out, indent=1))
        return out


# ── HyperSync poll ──────────────────────────────────────────────────────────────
_clients = {}
def client_for(chain):
    if chain not in _clients:
        _clients[chain] = HypersyncClient(ClientConfig(
            url=hs_pull.ENDPOINTS[chain], bearer_token=hs_pull.TOKEN,
            proactive_rate_limit_sleep=True))
    return _clients[chain]


async def poll_pool(st: PoolState):
    cfg = st.cfg
    cl = client_for(cfg["chain"])
    head = await cl.get_height()
    if st.cursor == 0:
        # cold start: backfill the rolling window (approx blocks for WINDOW_DAYS).
        bpd = {"bsc": 28800 * 30, "eth": 7200 * 30, "base": 43200 * 30}.get(cfg["chain"], 200_000)
        st.cursor = max(0, head - bpd * WINDOW_DAYS // 30)
    price = nxr_mid(cfg["nxr_sym"])
    if price > 0:
        st.last_price = price
    fee_frac = cfg["fee_bps"] / 1e4
    blk = st.cursor
    added = 0
    while blk < head:
        q = Query(from_block=blk, to_block=head,
                  logs=[LogSelection(address=[cfg["address"]], topics=[hs_pull.SWAP_T0])],
                  field_selection=FieldSelection(
                      block=[BlockField.NUMBER, BlockField.TIMESTAMP],
                      log=[LogField.BLOCK_NUMBER, LogField.DATA]))
        res = await cl.get(q)
        ts_of = {b.number: int(b.timestamp, 16) for b in (res.data.blocks or [])}
        for lg in res.data.logs:
            d = hs_pull.decode_swap_data(lg.data)
            if d is None:
                continue
            a0 = d["amount0"] / 10 ** cfg["d0"]
            a1 = d["amount1"] / 10 ** cfg["d1"]
            # NXR live mid (CEX truth, preferred) — else the swap's own pool price.
            p = st.last_price if st.last_price > 0 else \
                pool_price_usd(float(d["sqrtPriceX96"]), cfg["d0"], cfg["d1"], cfg["usd_token"])
            fee, net, lvr = mark_swap(a0, a1, p, cfg["usd_token"], fee_frac)
            in_usd = abs(a0 * (1.0 if cfg["usd_token"] == 0 else p)) if a0 > 0 \
                else abs(a1 * (p if cfg["usd_token"] == 0 else 1.0))
            vact = hs_pull.v_active_usd(float(d["liquidity"]), float(d["sqrtPriceX96"]),
                                        cfg["d0"], cfg["d1"], cfg["usd_token"])
            ts_ms = ts_of.get(lg.block_number, 0) * 1000
            st.win.append((ts_ms, fee, lvr, in_usd, vact, float(d["liquidity"]),
                           float(d["sqrtPriceX96"]), int(d["tick"])))
            st.last_tick = int(d["tick"])
            added += 1
        nb = res.next_block
        if nb <= blk:
            break
        blk = nb
    st.cursor = head
    if st.last_price <= 0 and st.win:        # no NXR key → show the pool price
        last = st.win[-1]
        st.last_price = pool_price_usd(last[6], cfg["d0"], cfg["d1"], cfg["usd_token"])
    now_ms = int(time.time() * 1000)
    snap = st.snapshot(now_ms, head)
    st.save_state()
    w = snap.get("w24h") or {}
    print(f"  [{cfg['name']}] +{added} swaps  price=${st.last_price:,.0f}  "
          f"24h: f0={w.get('f0_apr',0)*100:.0f}% lvr={w.get('arb_lvr_apr',0)*100:.0f}% "
          f"net={w.get('net_apr',0)*100:+.0f}% margin={w.get('margin_pct',0):+.0f}% "
          f"V=${(w.get('v_active_usd',0))/1e6:.1f}M", flush=True)


async def poll_vault(st: PoolState):
    """Ingest BTR adapter events (Rebalanced/Pulled/Withdrawn/Killed) → live vault state
    (current range, liquidity, deployed/neutral, deposits, killed). INERT until the adapter
    is deployed: skips a zero/placeholder address, so it never affects the swap collector."""
    cfg = st.cfg
    adapter = cfg.get("adapter", ZERO_ADDR)
    if not adapter or int(adapter, 16) == 0:
        return
    cl = client_for(cfg["chain"])
    head = await cl.get_height()
    if st.vault_cursor == 0:
        bpd = {"bsc": 28800, "eth": 7200, "base": 43200}.get(cfg["chain"], 7200)
        st.vault_cursor = max(0, head - bpd * WINDOW_DAYS)
    blk = st.vault_cursor
    sc = 10 ** cfg["d0"]
    while blk < head:
        q = Query(from_block=blk, to_block=head,
                  logs=[LogSelection(address=[adapter],
                                     topics=[[EV_REBALANCED, EV_PULLED, EV_WITHDRAWN, EV_KILLED]])],
                  field_selection=FieldSelection(
                      block=[BlockField.NUMBER, BlockField.TIMESTAMP],
                      log=[LogField.BLOCK_NUMBER, LogField.DATA, LogField.TOPIC0]))
        res = await cl.get(q)
        ts_of = {b.number: int(b.timestamp, 16) for b in (res.data.blocks or [])}
        for lg in res.data.logs:
            t0 = (getattr(lg, "topic0", "") or "").lower()
            ts_ms = ts_of.get(lg.block_number, 0) * 1000
            if t0 == EV_REBALANCED:
                tl, tu, liq = decode_rebalanced(lg.data)
                st.vault["range"] = None if (tl == 0 and tu == 0 and liq == 0) else [tl, tu]
                st.vault["liquidity"] = liq
                st.vault["deployed"] = liq > 0
                st.vault["last_rebalance_ms"] = ts_ms
            elif t0 == EV_PULLED:
                st.vault["total_pulled"] += int(_word(lg.data, 0), 16) / sc
            elif t0 == EV_WITHDRAWN:
                st.vault["total_withdrawn"] += int(_word(lg.data, 0), 16) / sc
            elif t0 == EV_KILLED:
                st.vault["killed"] = True
        nb = res.next_block
        if nb <= blk:
            break
        blk = nb
    st.vault_cursor = head
    (LIVE_DIR / f"{cfg['name']}.vault.json").write_text(json.dumps(
        {"name": cfg["name"], "adapter": adapter, "updated_ms": int(time.time() * 1000), **st.vault}))
    print(f"  [{cfg['name']}] vault: deployed={st.vault['deployed']} range={st.vault['range']} "
          f"killed={st.vault['killed']} pulled={st.vault['total_pulled']:.2f}", flush=True)


async def cycle(states):
    for st in states:
        try:
            await poll_pool(st)
            await poll_vault(st)
        except Exception as e:
            print(f"  [{st.cfg['name']}] poll error: {e}", flush=True)


async def main():
    LIVE_DIR.mkdir(parents=True, exist_ok=True)
    once = len(sys.argv) > 1 and sys.argv[1] == "once"
    states = [PoolState(c) for c in POOLS]
    for st in states:
        st.load()
    print(f"BTR live collector → {LIVE_DIR}  ({'once' if once else f'daemon poll={POLL_S}s'})", flush=True)
    while True:
        t0 = time.time()
        await cycle(states)
        if once:
            break
        await asyncio.sleep(max(1.0, POLL_S - (time.time() - t0)))


if __name__ == "__main__":
    asyncio.run(main())
