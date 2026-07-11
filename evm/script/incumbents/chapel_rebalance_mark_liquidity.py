#!/usr/bin/env python3
"""Rebalance Chapel BTR + UniV2 volatile pairs to ~TARGET_USD per side at mark.

Root cause of the empty-bid book: pools were seeded with 10_000 ether of EACH token
(BTCB=10k, USDC=10k) ⇒ ask depth ~5k BTCB but bid depth only ~10k/mark ≈ 0.15 BTCB.

This script:
  1) Withdraws excess BTR volatile spokes down to TARGET_USD/mark (keeps hub stables).
  2) Bumps BTR USDC hub to cover Σ spoke notionals (shared base).
  3) Burns UniV2 LP and re-mints at mark ratio with TARGET_USD each side.

Usage:
  cd dex/evm && TOPUP=1 DRY_RUN=0 python3 script/incumbents/chapel_rebalance_mark_liquidity.py
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEPLOYER = "0x57b3771F6b772C52E81646Aa007D1Ab28d91B3Fe"
WAD = 10**18
# PoolLiquidity uses LIQUIDITY_INDEX_INIT = 1e12 when index==0
INDEX_INIT = 10**12
TARGET_USD = int(os.environ.get("TARGET_USD", "10000"))


def _load_env() -> None:
    for p in (ROOT / ".env.chapel", ROOT.parent / "dex/evm/.env.chapel"):
        if not p.exists():
            continue
        for line in p.read_text().splitlines():
            if "=" in line and not line.strip().startswith("#"):
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


_load_env()
RPCS = [
    os.environ.get("RPC_URL", ""),
    "https://data-seed-prebsc-2-s1.bnbchain.org:8545",
    "https://data-seed-prebsc-1-s1.bnbchain.org:8545",
    "https://bsc-testnet.drpc.org",
]
RPCS = [r for r in RPCS if r]
PK = os.environ.get("DEPLOYER_PK") or os.environ.get("TESTER_PK", "")
GP = os.environ.get("GAS_PRICE", "100000000")
DRY = os.environ.get("DRY_RUN", "0") == "1"

# Illustrative marks (USDC per token) — match front refMark / live NX ~order.
MARKS = {
    "USDC": 1.0,
    "USDT": 1.0,
    "USD1": 1.0,
    "USDE": 1.0,
    "FDUSD": 1.0,
    "BTCB": 64_000.0,
    "ETH": 3_100.0,
    "WBNB": 610.0,
    "CAKE": 2.4,
    "XAUT": 2_380.0,
}


def eth(n: int) -> str:
    return f"{n / 1e18:.6f}"


def target_wei(sym: str, usd: float = TARGET_USD) -> int:
    m = MARKS.get(sym, 1.0)
    return int((usd / m) * 1e18)


class Rpc:
    def __init__(self) -> None:
        self.i = 0
        self.url = RPCS[0]

    def rotate(self) -> None:
        self.i = (self.i + 1) % len(RPCS)
        self.url = RPCS[self.i]
        print(f"  [rpc] failover -> {self.url}", flush=True)

    def call(self, *args: str, retries: int = 4) -> str:
        last = ""
        for attempt in range(retries):
            p = subprocess.run(
                ["cast", "call", *args, "--rpc-url", self.url],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            if p.returncode == 0:
                return (p.stdout + p.stderr).strip().split("\n")[0].split(" ")[0]
            last = p.stderr or p.stdout
            if "rate" in last.lower() or "timeout" in last.lower() or "429" in last:
                self.rotate()
                time.sleep(0.5 + attempt)
                continue
            if "execution reverted" in last:
                raise RuntimeError(last.strip())
            self.rotate()
            time.sleep(0.4)
        raise RuntimeError(f"cast call failed: {args[:3]} … {last[:200]}")

    def send(self, *args: str, retries: int = 5) -> str:
        if DRY:
            print(f"  [dry] cast send {' '.join(args[:4])}…")
            return "dry"
        if not PK:
            raise RuntimeError("DEPLOYER_PK / TESTER_PK required")
        last = ""
        for attempt in range(retries):
            p = subprocess.run(
                [
                    "cast", "send", *args,
                    "--private-key", PK,
                    "--rpc-url", self.url,
                    "--legacy",
                    "--gas-price", GP,
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            out = p.stdout + p.stderr
            if p.returncode == 0:
                print(f"  ok: {' '.join(args[:3])}")
                return out
            last = out
            if "nonce" in last.lower() or "underpriced" in last.lower() or "timeout" in last.lower():
                self.rotate()
                time.sleep(1 + attempt)
                continue
            if "replacement" in last.lower() or "already known" in last.lower():
                time.sleep(2)
                continue
            self.rotate()
            time.sleep(0.8)
        raise RuntimeError(f"cast send failed: {args[:4]} … {last[-400:]}")


rpc = Rpc()


def bal(token: str, holder: str) -> int:
    return int(rpc.call(token, "balanceOf(address)(uint256)", holder), 0)


def mint_to(token: str, amount: int) -> None:
    if amount <= 0:
        return
    rpc.send(token, "mint(address,uint256)", DEPLOYER, str(amount))


def approve(token: str, spender: str, amount: int) -> None:
    rpc.send(token, "approve(address,uint256)", spender, str(amount))


def lp_balance(pool: str, token: str) -> int:
    return int(rpc.call(pool, "getLPBalance(address,address)(uint256)", DEPLOYER, token), 0)


def liquidity_index(pool: str, token: str) -> int:
    # getAsset returns a tuple; liquidityIndex is field index 3 (0-based).
    # Use cast --json for robust parse.
    p = subprocess.run(
        [
            "cast", "call", pool,
            "getAsset(address)((uint256,uint256,uint256,uint256,uint32,uint16,address,uint16,uint16,uint16,uint16,uint8,uint16,uint16,uint16,uint16,uint256))",
            token, "--rpc-url", rpc.url, "--json",
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if p.returncode != 0:
        return INDEX_INIT
    try:
        data = json.loads(p.stdout)
        # cast --json may return list or dict
        if isinstance(data, list) and len(data) >= 4:
            idx = int(data[3], 0) if isinstance(data[3], str) else int(data[3])
            return idx if idx > 0 else INDEX_INIT
    except Exception:
        pass
    return INDEX_INIT


def lp_for_amount(pool: str, token: str, amount: int) -> int:
    idx = liquidity_index(pool, token)
    return (amount * WAD) // idx


def rebalance_btr_volatile(pool: str, tokens: dict[str, str]) -> None:
    print("== BTR volatile mark rebalance ==")
    spoke_usd = 0.0
    for sym, addr in tokens.items():
        if sym in ("USDC", "USDT"):
            continue
        keep = target_wei(sym)
        spoke_usd += TARGET_USD  # each spoke sized to TARGET_USD at mark
        cur = bal(addr, pool)
        if cur > keep:
            excess = cur - keep
            lp = lp_for_amount(pool, addr, excess)
            have = lp_balance(pool, addr)
            lp = min(lp, have)
            print(f"  withdraw {sym}: bal={eth(cur)} keep={eth(keep)} excess={eth(excess)} lp={lp} have={have}")
            if lp <= 0:
                print(f"  SKIP {sym}: no LP to burn (bal still {eth(cur)})")
                continue
            try:
                rpc.send(pool, "withdraw(address,uint256,uint256)", addr, str(lp), "0")
            except RuntimeError as e:
                print(f"  WARN {sym} withdraw failed: {e}")
                continue
        elif cur < keep:
            gap = keep - cur
            print(f"  deposit {sym}: bal={eth(cur)} target={eth(keep)} gap={eth(gap)}")
            mint_to(addr, gap)
            approve(addr, pool, gap)
            rpc.send(pool, "deposit(address,uint256)", addr, str(gap))
        else:
            print(f"  {sym}: already {eth(cur)}")

    # Shared USDC hub should cover spoke notionals (bid capacity).
    usdc = tokens["USDC"]
    hub_target = target_wei("USDC", max(TARGET_USD, spoke_usd))
    # Prefer at least Σ spoke USD so every pair has meaningful bids.
    hub_target = max(hub_target, int(spoke_usd * 1e18))
    cur_usdc = bal(usdc, pool)
    if cur_usdc < hub_target:
        gap = hub_target - cur_usdc
        print(f"  deposit USDC hub: bal={eth(cur_usdc)} target={eth(hub_target)} gap={eth(gap)}")
        mint_to(usdc, gap)
        approve(usdc, pool, gap)
        rpc.send(pool, "deposit(address,uint256)", usdc, str(gap))
    elif cur_usdc > hub_target * 2:
        # Don't aggressively drain hub — leave headroom.
        print(f"  USDC hub bal={eth(cur_usdc)} (target≈{eth(hub_target)}) — leave")
    else:
        print(f"  USDC hub bal={eth(cur_usdc)} ok")


def rebalance_univ2(factory: str, a: str, b: str, sym_a: str, sym_b: str) -> None:
    pair = rpc.call(factory, "getPair(address,address)(address)", a, b)
    if int(pair, 16) == 0:
        print(f"  UniV2 {sym_a}/{sym_b}: no pair")
        return
    print(f"== UniV2 {sym_a}/{sym_b} {pair[:10]}… ==")
    lp = bal(pair, DEPLOYER)
    supply = int(rpc.call(pair, "totalSupply()(uint256)"), 0)
    if lp > 0 and supply > 0:
        # Burn nearly all LP (leave 1000 minimum liquidity locked forever on first mint).
        burn = lp if lp + 1000 <= supply else max(0, supply - 1000)
        # Transfer LP to pair then burn
        if burn > 0:
            print(f"  burn LP {eth(burn)} / supply {eth(supply)}")
            rpc.send(pair, "transfer(address,uint256)", pair, str(burn))
            rpc.send(pair, "burn(address)", DEPLOYER)

    amt_a = target_wei(sym_a)
    amt_b = target_wei(sym_b)
    # token0/1 order
    t0 = rpc.call(pair, "token0()(address)")
    t1 = rpc.call(pair, "token1()(address)")
    if t0.lower() == a.lower():
        send0, send1 = amt_a, amt_b
        s0, s1 = sym_a, sym_b
    else:
        send0, send1 = amt_b, amt_a
        s0, s1 = sym_b, sym_a

    # Clear dust then seed fresh
    b0, b1 = bal(t0, pair), bal(t1, pair)
    print(f"  post-burn reserves {s0}={eth(b0)} {s1}={eth(b1)}; mint {eth(send0)}/{eth(send1)}")
    mint_to(t0, send0)
    mint_to(t1, send1)
    rpc.send(t0, "transfer(address,uint256)", pair, str(send0))
    rpc.send(t1, "transfer(address,uint256)", pair, str(send1))
    rpc.send(pair, "mint(address)", DEPLOYER)


def main() -> None:
    if not RPCS:
        print("No RPC", file=sys.stderr)
        sys.exit(1)
    dep = json.loads((ROOT / "deployments/97.deploy.json").read_text())
    print(f"=== Mark rebalance TARGET_USD={TARGET_USD} dry={DRY} rpc={rpc.url} ===\n")

    volatile = dep["volatilePool"]
    toks = {
        "USDC": dep["usdc"],
        "USDT": dep["usdt"],
        "BTCB": dep["btcb"],
        "ETH": dep["eth"],
        "WBNB": dep["wbnb"],
        "CAKE": dep["cake"],
        "XAUT": dep["xaut"],
    }
    rebalance_btr_volatile(volatile, toks)

    factory = os.environ.get("UNIV2_FACTORY", "0xD2F5488f1930Df661eceCbD4B122Ef767B6C92D4")
    pairs = [
        (dep["btcb"], dep["usdc"], "BTCB", "USDC"),
        (dep["eth"], dep["usdc"], "ETH", "USDC"),
        (dep["wbnb"], dep["usdc"], "WBNB", "USDC"),
        (dep["xaut"], dep["usdc"], "XAUT", "USDC"),
        (dep["btcb"], dep["usdt"], "BTCB", "USDT"),
        (dep["eth"], dep["usdt"], "ETH", "USDT"),
        (dep["wbnb"], dep["usdt"], "WBNB", "USDT"),
        (dep["xaut"], dep["usdt"], "XAUT", "USDT"),
    ]
    for a, b, sa, sb in pairs:
        try:
            rebalance_univ2(factory, a, b, sa, sb)
        except Exception as e:
            print(f"  WARN UniV2 {sa}/{sb}: {e}")

    print("\n=== Post balances (BTR volatile) ===")
    for sym, addr in toks.items():
        print(f"  {sym:6} {eth(bal(addr, volatile)):>14}  (target≈{eth(target_wei(sym))})")


if __name__ == "__main__":
    main()
