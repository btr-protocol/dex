#!/usr/bin/env python3
"""Chapel unify: top-up to 50k/side + redeploy Fluid + deploy UniV4 stable pools.

Does NOT touch BTR Admin (coordinate with stable-params agent).
Gas: 0.1 gwei. Env: DEPLOYER_PK via .env.chapel.

Usage:
  cd dex/evm && DRY_RUN=0 python3 script/incumbents/chapel_unify_50k.py
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEPLOYER = "0x57b3771F6b772C52E81646Aa007D1Ab28d91B3Fe"
WAD = 10**18
TARGET = int(os.environ.get("TARGET", str(50_000 * WAD)))
# Uni fee units (hundredths of a bip / 1e6): 0.0005%=5, 0.01%=100, 0.1%=1000
UNI_FEES = [5, 100, 1000]
RANGE_BPS = 1_000  # ±10% for stables (wide enough)
MARKS = {
    "BTCB": 64_000.0,
    "ETH": 3_100.0,
    "WBNB": 610.0,
    "XAUT": 2_380.0,
}


def _load_env() -> None:
    for p in (ROOT / ".env.chapel",):
        if not p.exists():
            continue
        for line in p.read_text().splitlines():
            if "=" in line and not line.strip().startswith("#"):
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


_load_env()
RPCS = [
    os.environ.get("RPC_URL", ""),
    "https://data-seed-prebsc-1-s1.bnbchain.org:8545",
    "https://data-seed-prebsc-2-s1.bnbchain.org:8545",
    "https://bsc-testnet.drpc.org",
    "https://bsc-testnet-rpc.publicnode.com",
]
RPCS = [r for r in RPCS if r]
PK = os.environ.get("DEPLOYER_PK") or os.environ.get("TESTER_PK", "")
GP = os.environ.get("GAS_PRICE", "100000000")
DRY = os.environ.get("DRY_RUN", "0") == "1"


def eth(n: int) -> str:
    return f"{n / 1e18:.4f}"


class Rpc:
    def __init__(self) -> None:
        self.i = 0
        self.url = RPCS[0]

    def rotate(self) -> None:
        self.i = (self.i + 1) % len(RPCS)
        self.url = RPCS[self.i]
        print(f"  [rpc] -> {self.url}", flush=True)

    def _run(self, cmd: list[str], retries: int = 5) -> str:
        last = ""
        for attempt in range(retries):
            p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
            out = p.stdout + p.stderr
            if p.returncode == 0:
                return out
            last = out
            low = last.lower()
            if any(x in low for x in ("rate", "timeout", "429", "-32005", "503", "502")):
                self.rotate()
                time.sleep(0.6 + attempt)
                continue
            if "nonce" in low or "underpriced" in low or "replacement" in low:
                time.sleep(1.2 + attempt)
                continue
            if "execution reverted" in low:
                raise RuntimeError(last.strip()[-500:])
            self.rotate()
            time.sleep(0.5)
        raise RuntimeError(f"cmd failed: {cmd[:4]} … {last[-400:]}")

    def call(self, *args: str) -> str:
        out = self._run(["cast", "call", *args, "--rpc-url", self.url])
        return out.strip().split("\n")[0].split()[0]

    def call_lines(self, *args: str) -> list[str]:
        out = self._run(["cast", "call", *args, "--rpc-url", self.url])
        return [ln.split()[0] for ln in out.strip().split("\n") if ln.strip()]

    def send(self, *args: str) -> str:
        if DRY:
            print(f"  [dry] send {args[0][:10]}… {args[1] if len(args)>1 else ''}")
            return "dry"
        out = self._run(
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
            ]
        )
        print(f"  ok: {args[0][:12]}… {args[1] if len(args) > 1 else ''}")
        time.sleep(0.35)
        return out

    def forge_create(self, contract: str, ctor: list[str]) -> str:
        if DRY:
            print(f"  [dry] forge create {contract}")
            return "0x" + "d" * 40
        cmd = [
            "forge",
            "create",
            contract,
            "--rpc-url",
            self.url,
            "--private-key",
            PK,
            "--legacy",
            "--gas-price",
            GP,
            "--broadcast",
        ]
        if ctor:
            cmd += ["--constructor-args", *ctor]
        out = self._run(cmd, retries=3)
        m = re.search(r"Deployed to:\s*(0x[0-9a-fA-F]+)", out)
        if not m:
            m2 = re.search(r'"deployedTo"\s*:\s*"(0x[0-9a-fA-F]+)"', out)
            if not m2:
                raise RuntimeError(f"parse deploy fail:\n{out[-800:]}")
            return m2.group(1)
        return m.group(1)


rpc = Rpc()
before_rows: list[dict] = []
after_rows: list[dict] = []
notes: list[str] = []


def bal(token: str, holder: str) -> int:
    return int(rpc.call(token, "balanceOf(address)(uint256)", holder), 0)


def mint_to(token: str, amount: int) -> None:
    if amount <= 0:
        return
    rpc.send(token, "mint(address,uint256)", DEPLOYER, str(amount))


def approve(token: str, spender: str, amount: int) -> None:
    rpc.send(token, "approve(address,uint256)", spender, str(amount))


def record(phase: list[dict], venue: str, pool: str, token: str, name: str, fee: str = "") -> int:
    b = bal(token, pool)
    phase.append(
        {
            "venue": venue,
            "pool": pool,
            "token": name,
            "tokenAddr": token,
            "balance": b,
            "fee": fee,
        }
    )
    return b


def top_btr(dep: dict, names: dict) -> None:
    print("\n== BTR ==")
    for label, pool, toks in [
        ("BTR-stable", dep["stablePool"], [dep[k] for k in ("usdc", "usdt", "usd1", "usde", "fdusd")]),
        (
            "BTR-volatile",
            dep["volatilePool"],
            [dep[k] for k in ("usdc", "usdt", "btcb", "eth", "wbnb", "cake", "xaut")],
        ),
    ]:
        for t in toks:
            b = record(before_rows, label, pool, t, names[t])
            short = max(0, TARGET - b)
            # Volatile spokes: only top hub stables to TARGET; leave mark-sized spokes alone
            if label == "BTR-volatile" and names[t] not in ("USDC", "USDT"):
                if b > 0:
                    print(f"  skip spoke {names[t]} bal={eth(b)} (mark-sized)")
                    continue
            if short:
                print(f"  top {label} {names[t]} +{eth(short)}")
                mint_to(t, short)
                approve(t, pool, short)
                rpc.send(pool, "deposit(address,uint256)", t, str(short))
            record(after_rows, label, pool, t, names[t])


def top_curve(inc: dict, dep: dict, names: dict) -> None:
    print("\n== Curve ==")
    pools = [
        ("Curve-3pool", inc["curve3pool"], [dep["usdt"], dep["usdc"], dep["usd1"]], "1bp"),
        ("Curve-USDE/USDT", inc["curveUsdeUsdt"], [dep["usdt"], dep["usde"]], "1bp"),
        ("Curve-FDUSD/USDC", inc["curveFdusdUsdc"], [dep["usdc"], dep["fdusd"]], "1bp"),
        ("Curve-USDT/BNB/BTCB", inc["curveUsdtBnbBtcb"], [dep["usdt"], dep["wbnb"], dep["btcb"]], "30bp"),
        ("Curve-USDC/ETH/BTCB", inc["curveUsdcEthBtcb"], [dep["usdc"], dep["eth"], dep["btcb"]], "30bp"),
    ]
    for venue, pool, coins, fee in pools:
        shorts = []
        for t in coins:
            b = record(before_rows, venue, pool, t, names[t], fee)
            # tricrypto: top stable legs to TARGET; volatile legs to TARGET only if already ~equal seed
            nm = names[t]
            if nm in MARKS and b < TARGET // 100:
                # mark-sized — bump USD notional via stable only
                shorts.append(0)
                print(f"  skip mark-spoke {venue} {nm}={eth(b)}")
                continue
            shorts.append(max(0, TARGET - b))
        if any(shorts):
            for t, s in zip(coins, shorts):
                if s:
                    mint_to(t, s)
                    approve(t, pool, s)
            amts = "[" + ",".join(str(s) for s in shorts) + "]"
            print(f"  add_liquidity {venue} {amts}")
            rpc.send(pool, "add_liquidity(uint256[],uint256)", amts, "0")
        for t in coins:
            record(after_rows, venue, pool, t, names[t], fee)


def top_wombat(inc: dict, dep: dict, names: dict) -> None:
    print("\n== Wombat ==")
    pool = inc["wombat"]
    for t in [dep["usdc"], dep["usdt"], dep["usd1"], dep["usde"]]:
        b = record(before_rows, "Wombat", pool, t, names[t], "2bps")
        short = max(0, TARGET - b)
        if short:
            mint_to(t, short)
            approve(t, pool, short)
            rpc.send(pool, "deposit(address,uint256,uint256)", t, str(short), "0")
        record(after_rows, "Wombat", pool, t, names[t], "2bps")


def top_univ2(inc: dict, dep: dict, names: dict) -> None:
    print("\n== UniV2 ==")
    fac = inc["uniV2Factory"]
    stables = [dep[k] for k in ("usdc", "usdt", "usd1", "usde", "fdusd")]
    # All stable×stable + stable×volatile (USDC/USDT hubs) — same as coverage
    pairs: list[tuple[str, str]] = []
    for i, a in enumerate(stables):
        for b in stables[i + 1 :]:
            pairs.append((a, b))
    for hub in (dep["usdc"], dep["usdt"]):
        for v in (dep["btcb"], dep["eth"], dep["wbnb"], dep["xaut"]):
            pairs.append((hub, v))

    for a, b in pairs:
        pair = rpc.call(fac, "getPair(address,address)(address)", a, b)
        if int(pair, 16) == 0:
            print(f"  createPair {names[a]}/{names[b]}")
            rpc.send(fac, "createPair(address,address)", a, b)
            pair = rpc.call(fac, "getPair(address,address)(address)", a, b)
        t0 = rpc.call(pair, "token0()(address)")
        t1 = rpc.call(pair, "token1()(address)")
        b0 = record(before_rows, "UniV2", pair, t0, names.get(t0, t0[:8]), "0.30%")
        b1 = record(before_rows, "UniV2", pair, t1, names.get(t1, t1[:8]), "0.30%")

        n0, n1 = names.get(t0, ""), names.get(t1, "")
        # Target amounts
        if n0 in MARKS or n1 in MARKS:
            # mark-priced: 50k USD on stable side
            if n0 in MARKS:
                want1 = TARGET
                want0 = int((TARGET / MARKS[n0]) * 1e18)
            else:
                want0 = TARGET
                want1 = int((TARGET / MARKS[n1]) * 1e18)
        else:
            want0 = want1 = TARGET

        s0, s1 = max(0, want0 - b0), max(0, want1 - b1)
        if s0 or s1:
            print(f"  mint {n0}/{n1} +{eth(s0)}/+{eth(s1)}")
            if s0:
                mint_to(t0, s0)
                rpc.send(t0, "transfer(address,uint256)", pair, str(s0))
            if s1:
                mint_to(t1, s1)
                rpc.send(t1, "transfer(address,uint256)", pair, str(s1))
            rpc.send(pair, "mint(address)", DEPLOYER)
        record(after_rows, "UniV2", pair, t0, n0 or t0[:8], "0.30%")
        record(after_rows, "UniV2", pair, t1, n1 or t1[:8], "0.30%")


def top_litecl(inc: dict, dep: dict, names: dict) -> None:
    print("\n== LiteCL (legacy) ==")
    clf = inc["clFactory"]
    toks = [dep[k] for k in ("usdc", "usdt", "usd1", "usde", "fdusd")]
    fees = [str(inc["clFeeUltra"]), str(inc["clFee1bp"])]
    for i, a in enumerate(toks):
        for b in toks[i + 1 :]:
            for fee in fees:
                pool = rpc.call(clf, "getPool(address,address,uint24)(address)", a, b, fee)
                if int(pool, 16) == 0:
                    notes.append(f"LiteCL missing {names[a]}/{names[b]} fee={fee}")
                    continue
                t0 = rpc.call(pool, "token0()(address)")
                t1 = rpc.call(pool, "token1()(address)")
                b0 = record(before_rows, f"LiteCL-{fee}", pool, t0, names[t0], f"{int(fee)/10000}%")
                b1 = record(before_rows, f"LiteCL-{fee}", pool, t1, names[t1], f"{int(fee)/10000}%")
                s0, s1 = max(0, TARGET - b0), max(0, TARGET - b1)
                if s0 or s1:
                    a0, a1 = (s0 or 1), (s1 or 1)
                    mint_to(t0, a0)
                    mint_to(t1, a1)
                    approve(t0, pool, a0)
                    approve(t1, pool, a1)
                    rpc.send(pool, "mint(uint256,uint256,address)", str(a0), str(a1), DEPLOYER)
                record(after_rows, f"LiteCL-{fee}", pool, t0, names[t0], f"{int(fee)/10000}%")
                record(after_rows, f"LiteCL-{fee}", pool, t1, names[t1], f"{int(fee)/10000}%")


def redeploy_fluid(inc: dict, dep: dict, names: dict) -> list[str]:
    """Fluid has no addLiquidity — redeploy factory + all stable pairs at 50k."""
    print("\n== Fluid redeploy ==")
    old = list(inc.get("fluidPools", []))
    for i, pool in enumerate(old):
        try:
            t0 = rpc.call(pool, "token0()(address)")
            t1 = rpc.call(pool, "token1()(address)")
            record(before_rows, "Fluid-old", pool, t0, names.get(t0, "?"), "1bp")
            record(before_rows, "Fluid-old", pool, t1, names.get(t1, "?"), "1bp")
        except Exception as e:
            notes.append(f"Fluid old read fail {pool}: {e}")

    fac = rpc.forge_create("src/incumbents/fluid/FluidDexPool.sol:FluidDexFactory", [])
    print(f"  fluidFactory={fac}")
    toks = [dep[k] for k in ("usdc", "usdt", "usd1", "usde", "fdusd")]
    new_pools: list[str] = []
    # C(5,2)=10 would be a lot; keep the 6 canonical crosses matching prior deploy
    # Prior: all pairs among first 4 + some with fdusd — use all C(5,2)=10 for completeness? 
    # incumbents had nFluidPools=6. Match: USDC×{USDT,USD1,USDE,FDUSD}, USDT×{USD1,USDE}
    crosses = [
        (dep["usdc"], dep["usdt"]),
        (dep["usdc"], dep["usd1"]),
        (dep["usdc"], dep["usde"]),
        (dep["usdc"], dep["fdusd"]),
        (dep["usdt"], dep["usd1"]),
        (dep["usdt"], dep["usde"]),
    ]
    for a, b in crosses:
        print(f"  create Fluid {names[a]}/{names[b]}")
        # createPool(tokenA,tokenB,fee,upper,lower,center) fee=100 (1bp), range=50 (0.5%)
        rpc.send(
            fac,
            "createPool(address,address,uint256,uint256,uint256,uint256)",
            a,
            b,
            "100",
            "50",
            "50",
            str(10**27),
        )
        pool = rpc.call(fac, "getPool(address,address)(address)", a, b)
        t0 = rpc.call(pool, "token0()(address)")
        t1 = rpc.call(pool, "token1()(address)")
        mint_to(t0, TARGET)
        mint_to(t1, TARGET)
        approve(t0, pool, TARGET)
        approve(t1, pool, TARGET)
        rpc.send(pool, "initialize(uint256,uint256)", str(TARGET), str(TARGET))
        new_pools.append(pool)
        record(after_rows, "Fluid", pool, t0, names[t0], "1bp")
        record(after_rows, "Fluid", pool, t1, names[t1], "1bp")
        print(f"    -> {pool}")

    inc["fluidFactory"] = fac
    inc["fluidPools"] = new_pools
    inc["nFluidPools"] = len(new_pools)
    notes.append(f"Fluid redeployed factory={fac} pools={len(new_pools)} (old kept on-chain)")
    return new_pools


def deploy_univ4_stables(inc: dict, dep: dict, names: dict) -> list[dict]:
    print("\n== UniV4 (RangeCL) stable pools ==")
    fac = inc.get("rangeClFactory") or "0x0f03EB0F1282594B3AE3A636fc835EEe8575765F"
    toks = [dep[k] for k in ("usdc", "usdt", "usd1", "usde", "fdusd")]
    created: list[dict] = []
    for i, a in enumerate(toks):
        for b in toks[i + 1 :]:
            for fee in UNI_FEES:
                existing = rpc.call(fac, "getPool(address,address,uint24)(address)", a, b, str(fee))
                if int(existing, 16) != 0:
                    pool = existing
                    print(f"  exists {names[a]}/{names[b]} fee={fee} {pool}")
                else:
                    print(f"  create {names[a]}/{names[b]} fee={fee}")
                    rpc.send(fac, "createPool(address,address,uint24)", a, b, str(fee))
                    pool = rpc.call(fac, "getPool(address,address,uint24)(address)", a, b, str(fee))
                t0 = rpc.call(pool, "token0()(address)")
                t1 = rpc.call(pool, "token1()(address)")
                b0, b1 = bal(t0, pool), bal(t1, pool)
                record(before_rows, f"UniV4-{fee}", pool, t0, names[t0], f"{fee/10000}%")
                record(before_rows, f"UniV4-{fee}", pool, t1, names[t1], f"{fee/10000}%")
                # seed only if uninitialized (reserves 0)
                sqrt = rpc.call(pool, "sqrtPriceX96()(uint160)")
                if int(sqrt, 0) == 0:
                    mint_to(t0, TARGET)
                    mint_to(t1, TARGET)
                    approve(t0, pool, TARGET)
                    approve(t1, pool, TARGET)
                    # price1e18 = 1e18 (1:1 stables), range ±10%
                    rpc.send(
                        pool,
                        "seed(uint256,uint256,uint256,uint256)",
                        str(WAD),
                        str(RANGE_BPS),
                        str(TARGET),
                        str(TARGET),
                    )
                elif b0 < TARGET or b1 < TARGET:
                    notes.append(
                        f"UniV4 {names[a]}/{names[b]} fee={fee} already init "
                        f"bal={eth(b0)}/{eth(b1)} — cannot top (no mint)"
                    )
                record(after_rows, f"UniV4-{fee}", pool, t0, names[t0], f"{fee/10000}%")
                record(after_rows, f"UniV4-{fee}", pool, t1, names[t1], f"{fee/10000}%")
                created.append(
                    {
                        "tag": f"univ4-{names[a].lower()}-{names[b].lower()}-{fee}",
                        "address": pool,
                        "tokens": [a, b],
                        "fee": fee,
                        "feeLabel": f"{fee/10000}%",
                    }
                )
                print(f"    -> {pool}")
    return created


def top_range_volatile(dep: dict, names: dict, pools: list[dict]) -> None:
    print("\n== UniV4 volatile (record only; no mint path) ==")
    for p in pools:
        addr = p["address"]
        t0 = rpc.call(addr, "token0()(address)")
        t1 = rpc.call(addr, "token1()(address)")
        fee = rpc.call(addr, "fee()(uint24)")
        record(before_rows, "UniV4-vol", addr, t0, names.get(t0, "?"), f"{int(fee,0)/10000}%")
        record(before_rows, "UniV4-vol", addr, t1, names.get(t1, "?"), f"{int(fee,0)/10000}%")
        record(after_rows, "UniV4-vol", addr, t0, names.get(t0, "?"), f"{int(fee,0)/10000}%")
        record(after_rows, "UniV4-vol", addr, t1, names.get(t1, "?"), f"{int(fee,0)/10000}%")


def main() -> None:
    if not PK and not DRY:
        sys.exit("need DEPLOYER_PK")
    dep = json.loads((ROOT / "deployments/97.deploy.json").read_text())
    inc = json.loads((ROOT / "deployments/97.incumbents.json").read_text())
    pig = json.loads((ROOT / "deployments/97.uni-piggyback.json").read_text())
    names = {
        dep["usdc"]: "USDC",
        dep["usdt"]: "USDT",
        dep["usd1"]: "USD1",
        dep["usde"]: "USDE",
        dep["fdusd"]: "FDUSD",
        dep["btcb"]: "BTCB",
        dep["eth"]: "ETH",
        dep["wbnb"]: "WBNB",
        dep["cake"]: "CAKE",
        dep["xaut"]: "XAUT",
    }

    print(f"=== chapel_unify_50k TARGET={eth(TARGET)} rpc={rpc.url} dry={DRY} ===")
    try:
        bnb = subprocess.run(
            ["cast", "balance", DEPLOYER, "--rpc-url", rpc.url, "--ether"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        ).stdout.strip()
        print(f"BNB={bnb} nonce={rpc.call('nonce') if False else subprocess.run(['cast','nonce',DEPLOYER,'--rpc-url',rpc.url],capture_output=True,text=True).stdout.strip()}")
    except Exception as e:
        print("bnb check:", e)

    top_btr(dep, names)
    top_curve(inc, dep, names)
    top_wombat(inc, dep, names)
    top_univ2(inc, dep, names)
    top_litecl(inc, dep, names)
    fluid_pools = redeploy_fluid(inc, dep, names)
    univ4_stables = deploy_univ4_stables(inc, dep, names)

    vol_pools = [
        {"tag": "range-btcb-usdc", "address": pig["btcbUsdc"], "tokens": [dep["btcb"], dep["usdc"]]},
        {"tag": "range-eth-usdc", "address": pig["ethUsdc"], "tokens": [dep["eth"], dep["usdc"]]},
        {"tag": "range-wbnb-usdc", "address": pig["wbnbUsdc"], "tokens": [dep["wbnb"], dep["usdc"]]},
        {"tag": "range-xaut-usdc", "address": pig["xautUsdc"], "tokens": [dep["xaut"], dep["usdc"]]},
    ]
    top_range_volatile(dep, names, vol_pools)

    # Persist incumbents + uni-v4 stables catalog
    inc["rangeClFactory"] = pig.get("factory") or inc.get("rangeClFactory")
    inc["uniV4StablePools"] = univ4_stables
    inc["uniV4Fees"] = UNI_FEES
    (ROOT / "deployments/97.incumbents.json").write_text(json.dumps(inc, indent=2) + "\n")

    pig["stablePools"] = univ4_stables
    pig["fees"] = UNI_FEES
    (ROOT / "deployments/97.uni-piggyback.json").write_text(json.dumps(pig, indent=2) + "\n")

    # Merge before/after for report
    def key(r: dict) -> tuple:
        return (r["venue"], r["pool"].lower(), r["token"])

    before_map = {key(r): r for r in before_rows}
    report = []
    seen = set()
    for r in after_rows:
        k = key(r)
        if k in seen:
            continue
        seen.add(k)
        b = before_map.get(k)
        report.append(
            {
                "venue": r["venue"],
                "pool": r["pool"],
                "token": r["token"],
                "fee": r.get("fee", ""),
                "before": str(b["balance"]) if b else "",
                "after": str(r["balance"]),
                "beforeEth": eth(b["balance"]) if b else "",
                "afterEth": eth(r["balance"]),
                "ok": r["balance"] >= TARGET
                or (r["token"] in MARKS and r["balance"] > 0),
            }
        )

    out = {
        "target": TARGET,
        "targetEth": 50_000,
        "fluidPools": fluid_pools,
        "uniV4StablePools": univ4_stables,
        "notes": notes,
        "rows": report,
    }
    path = ROOT / "deployments/97.liquidity-audit.json"
    path.write_text(json.dumps(out, indent=2) + "\n")
    print(f"\nwrote {path}")
    print(f"Fluid pools: {len(fluid_pools)}")
    print(f"UniV4 stable pools: {len(univ4_stables)}")
    short = [r for r in report if not r["ok"]]
    print(f"sides OK: {len(report)-len(short)}/{len(report)}")
    if notes:
        print("NOTES:")
        for n in notes:
            print(" -", n)


if __name__ == "__main__":
    main()
