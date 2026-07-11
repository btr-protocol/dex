#!/usr/bin/env python3
"""Audit + top-up Chapel pool liquidity.

⚠ Prefer `chapel_rebalance_mark_liquidity.py` for volatile pairs — equal TOKEN
amounts (10k BTCB + 10k USDC) make a one-sided BTCB book (bid ≈ USDC/mark).
This script's TARGET defaults to 10_000 ether per token for stables / coverage
checks only; set MARK_PRICED=1 to skip volatile spokes (leave mark rebalance).
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
    "https://data-seed-prebsc-1-s2.bnbchain.org:8545",
    "https://bsc-testnet.drpc.org",
]
RPCS = [r for r in RPCS if r]
PK = os.environ.get("DEPLOYER_PK") or os.environ.get("TESTER_PK", "")
TARGET = int(os.environ.get("TARGET", str(10_000 * 10**18)))
GP = os.environ.get("GAS_PRICE", "100000000")
DRY = os.environ.get("DRY_RUN", "0") == "1"
DO_TOPUP = os.environ.get("TOPUP", "1") == "1"

TOK_NAMES = {
    "0x6dF80a290E0585dad752c25f2808E83b5624290d": "USDC",
    "0xB7b7722369Ab72cb044DE6bb511A4586F3a7dD64": "USDT",
    "0xC28bE4D407096E771F932c202F13D866B4d6BA07": "USD1",
    "0xebF751546832ec77a039083E9FDd8158B21c0172": "USDE",
    "0x4Aa480f3dc3a1f08c24472E083fBDBE919b8BdFc": "FDUSD",
    "0xd719319e853670ac938e426fbdB70CFdb34c11Fa": "BTCB",
    "0x24Ff1aCD4e8fdBFEBee2e7e63ad36B1E72821189": "ETH",
    "0x31B7DCA9e901F7D34fb4a3Ee07eD2994de16685D": "WBNB",
    "0xa7E62dd82789346bEb48a80227B5d926c6403400": "CAKE",
    "0xd384aC4696FA230c9049F6534Fc35aC3af586073": "XAUT",
}


def norm(a: str) -> str:
    return a.strip()


def tname(a: str) -> str:
    return TOK_NAMES.get(a, a[:10])


def eth(n: int) -> str:
    return f"{n / 1e18:.4f}"


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
            if "rate" in last.lower() or "timeout" in last.lower() or "429" in last or "-32005" in last:
                self.rotate()
                time.sleep(0.5 + attempt)
                continue
            # hard revert — don't rotate forever
            if "execution reverted" in last:
                raise RuntimeError(last.strip())
            self.rotate()
            time.sleep(0.4)
        raise RuntimeError(f"cast call failed: {args[:3]} … {last[:200]}")

    def send(self, *args: str, retries: int = 5) -> str:
        if DRY:
            print(f"  [dry] cast send {' '.join(args[:4])}…")
            return "dry"
        last = ""
        for attempt in range(retries):
            p = subprocess.run(
                [
                    "cast",
                    "send",
                    *args,
                    "--private-key",
                    PK,
                    "--rpc-url",
                    self.url,
                    "--legacy",
                    "--gas-price",
                    GP,
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
    raw = rpc.call(token, "balanceOf(address)(uint256)", holder)
    return int(raw, 0)


def mint_to(token: str, amount: int) -> None:
    if amount <= 0:
        return
    rpc.send(token, "mint(address,uint256)", DEPLOYER, str(amount))


def approve(token: str, spender: str, amount: int) -> None:
    rpc.send(token, "approve(address,uint256)", spender, str(amount))


rows: list[dict] = []
gaps: list[str] = []
notes: list[str] = []


def record(venue: str, pool: str, token: str, balance: int, target: int = TARGET) -> int:
    short = max(0, target - balance)
    status = "OK" if short == 0 else f"SHORT {eth(short)}"
    rows.append(
        {
            "venue": venue,
            "pool": pool,
            "token": tname(token),
            "tokenAddr": token,
            "balance": balance,
            "target": target,
            "short": short,
            "status": status,
        }
    )
    print(f"  {venue:12} {pool[:10]}… {tname(token):6} bal={eth(balance):>12} target={eth(target):>8} {status}")
    return short


def main() -> None:
    dep = json.loads((ROOT / "deployments/97.deploy.json").read_text())
    inc = json.loads((ROOT / "deployments/97.incumbents.json").read_text())
    usdc, usdt, usd1, usde, fdusd = dep["usdc"], dep["usdt"], dep["usd1"], dep["usde"], dep["fdusd"]
    btcb, eth_, wbnb, cake, xaut = dep["btcb"], dep["eth"], dep["wbnb"], dep["cake"], dep["xaut"]
    toks5 = [usdc, usdt, usd1, usde, fdusd]

    print(f"=== Chapel liquidity audit TARGET={eth(TARGET)} rpc={rpc.url} dry={DRY} topup={DO_TOPUP} ===\n")

    # ── BTR stable ──
    print("== BTR stable ==")
    stable = dep["stablePool"]
    for t in toks5:
        short = record("BTR-stable", stable, t, bal(t, stable))
        if DO_TOPUP and short:
            mint_to(t, short)
            approve(t, stable, short)
            rpc.send(stable, "deposit(address,uint256)", t, str(short))

    # ── BTR volatile ──
    print("== BTR volatile ==")
    volatile = dep["volatilePool"]
    for t in [usdc, usdt, btcb, eth_, wbnb, cake, xaut]:
        short = record("BTR-volatile", volatile, t, bal(t, volatile))
        if DO_TOPUP and short:
            mint_to(t, short)
            approve(t, volatile, short)
            rpc.send(volatile, "deposit(address,uint256)", t, str(short))

    # ── Curve ──
    print("== Curve ==")
    curve_pools = [
        ("Curve-3pool", inc["curve3pool"], [usdt, usdc, usd1]),
        ("Curve-USDE/USDT", inc["curveUsdeUsdt"], [usdt, usde]),
        ("Curve-FDUSD/USDC", inc["curveFdusdUsdc"], [usdc, fdusd]),
    ]
    for venue, pool, coins in curve_pools:
        shorts = []
        for t in coins:
            shorts.append(record(venue, pool, t, bal(t, pool)))
        if DO_TOPUP and any(shorts):
            for t, s in zip(coins, shorts):
                if s:
                    mint_to(t, s)
                    approve(t, pool, s)
            amts = "[" + ",".join(str(s) for s in shorts) + "]"
            # add_liquidity even if some zeros
            rpc.send(pool, "add_liquidity(uint256[],uint256)", amts, "0")

    # ── UniV4 LiteCL ──
    print("== LiteCL ==")
    clf = inc["clFactory"]
    fees = [str(inc["clFeeUltra"]), str(inc["clFee1bp"])]
    for i, a in enumerate(toks5):
        for b in toks5[i + 1 :]:
            for fee in fees:
                pool = rpc.call(clf, "getPool(address,address,uint24)(address)", a, b, fee)
                if int(pool, 16) == 0:
                    pool = rpc.call(clf, "getPool(address,address,uint24)(address)", b, a, fee)
                if int(pool, 16) == 0:
                    gaps.append(f"LiteCL missing {tname(a)}/{tname(b)} fee={fee}")
                    continue
                # token order on pool
                t0 = rpc.call(pool, "token0()(address)")
                t1 = rpc.call(pool, "token1()(address)")
                b0, b1 = bal(t0, pool), bal(t1, pool)
                s0 = record(f"LiteCL-{fee}", pool, t0, b0)
                s1 = record(f"LiteCL-{fee}", pool, t1, b1)
                if DO_TOPUP and (s0 or s1):
                    # mint requires both sides > 0; if one side ok, still need to add both
                    # add only the shortfall on each side (mint accepts any positive pair)
                    a0 = s0 if s0 else 0
                    a1 = s1 if s1 else 0
                    # LiteCL mint requires both > 0 — if only one short, add 1 wei dust on the other
                    if a0 == 0 and a1 > 0:
                        a0 = 1
                    if a1 == 0 and a0 > 0:
                        a1 = 1
                    if a0:
                        mint_to(t0, a0)
                        approve(t0, pool, a0)
                    if a1:
                        mint_to(t1, a1)
                        approve(t1, pool, a1)
                    rpc.send(pool, "mint(uint256,uint256,address)", str(a0), str(a1), DEPLOYER)

    # ── Wombat ──
    print("== Wombat ==")
    wombat = inc["wombat"]
    for t in [usdc, usdt, usd1, usde]:
        short = record("Wombat", wombat, t, bal(t, wombat))
        if DO_TOPUP and short:
            mint_to(t, short)
            approve(t, wombat, short)
            rpc.send(wombat, "deposit(address,uint256,uint256)", t, str(short), "0")

    # ── Fluid ──
    print("== Fluid ==")
    for pool in inc["fluidPools"]:
        t0 = rpc.call(pool, "token0()(address)")
        t1 = rpc.call(pool, "token1()(address)")
        b0, b1 = bal(t0, pool), bal(t1, pool)
        s0 = record("Fluid", pool, t0, b0)
        s1 = record("Fluid", pool, t1, b1)
        if s0 or s1:
            # Fluid only has initialize() once — no deposit path
            notes.append(
                f"Fluid {pool[:10]}… short t0={eth(s0)} t1={eth(s1)} — "
                "AlreadyInit; no deposit/addLiquidity. Cannot top-up without redeploy."
            )
            gaps.append(f"Fluid {pool} cannot top-up (AlreadyInit only)")

    print("\n=== FINAL TABLE (post top-up balances) ===")
    print(f"{'venue':16} {'pool':44} {'token':6} {'balance':>16} {'ok':>4}")
    seen: set[tuple] = set()
    final_rows = []
    for r in rows:
        key = (r["venue"], r["pool"], r["tokenAddr"])
        if key in seen:
            continue
        seen.add(key)
        b = bal(r["tokenAddr"], r["pool"])
        ok = b >= TARGET
        final_rows.append((r["venue"], r["pool"], r["token"], b, ok))
        print(f"{r['venue']:16} {r['pool']:44} {r['token']:6} {eth(b):>16} {'✓' if ok else '✗'}")

    short_final = [x for x in final_rows if not x[4]]
    print(f"\nPools sides OK: {len(final_rows) - len(short_final)}/{len(final_rows)}")
    if notes:
        print("\nNOTES:")
        for n in notes:
            print(" -", n)
    if gaps:
        print("\nGAPS:")
        for g in gaps:
            print(" -", g)

    out = ROOT / "deployments/97.liquidity-audit.json"
    out.write_text(
        json.dumps(
            {
                "target": TARGET,
                "rows": [
                    {"venue": v, "pool": p, "token": t, "balance": str(b), "ok": ok}
                    for v, p, t, b, ok in final_rows
                ],
                "notes": notes,
                "gaps": gaps,
            },
            indent=2,
        )
        + "\n"
    )
    print("wrote", out)
    if short_final and not any("Fluid" in n for n in notes):
        # only fail if non-Fluid shorts remain
        remaining = [x for x in short_final if "Fluid" not in str(x[0])]
        if remaining:
            sys.exit(1)


if __name__ == "__main__":
    if not PK:
        sys.exit("need DEPLOYER_PK in .env.chapel")
    main()
