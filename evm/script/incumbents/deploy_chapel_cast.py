#!/usr/bin/env python3
"""Deploy incumbents on Chapel via forge create + cast send (no forge-script fork)."""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RPC = os.environ.get("RPC_URL", "https://bsc-testnet.drpc.org")
PK = os.environ["DEPLOYER_PK"]
SEED = os.environ.get("SEED_USDC", "10000000000000000000000")  # 10k
GP = os.environ.get("GAS_PRICE", "100000000")
OUT_PATH = Path(os.environ.get("INCUMBENTS_OUT", str(ROOT / "deployments/97.incumbents.json")))

CURVE_A = "1000"
CURVE_FEE = "1000000"  # 1bp in 1e10 denom
FEE_ULTRA = "5"
FEE_1BP = "100"
TICK = "1"
WOMBAT_K = "100000000000000"  # 1e14
WOMBAT_FEE = "2"
FLUID_FEE = "100"
FLUID_RANGE = "50"
FLUID_CENTER = "1000000000000000000000000000"  # 1e27


def run(cmd: list[str], check: bool = True) -> str:
    shown = []
    skip_next = False
    for i, a in enumerate(cmd):
        if skip_next:
            shown.append("<redacted>")
            skip_next = False
            continue
        if a in ("--private-key", "-–private-key"):
            shown.append(a)
            skip_next = True
            continue
        shown.append(a)
    print("+", " ".join(shown[:12]), ("..." if len(shown) > 12 else ""))
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if p.returncode != 0 and check:
        sys.stderr.write(p.stdout + "\n" + p.stderr + "\n")
        raise SystemExit(f"cmd failed ({p.returncode}): {cmd[0]}")
    return p.stdout + p.stderr


def cast(*args: str, check: bool = True) -> str:
    return run(["cast", *args], check=check)


def forge_create(contract: str, ctor: list[str]) -> str:
    cmd = [
        "forge",
        "create",
        contract,
        "--rpc-url",
        RPC,
        "--private-key",
        PK,
        "--legacy",
        "--gas-price",
        GP,
        "--broadcast",
        "--json",
    ]
    if ctor:
        cmd += ["--constructor-args", *ctor]
    out = run(cmd)
    # forge create --json prints a JSON object; may be mixed with warnings
    m = re.search(r"\{[^{}]*\"deployedTo\"[^{}]*\}", out, re.S)
    if not m:
        # fallback non-json
        m2 = re.search(r"Deployed to:\s*(0x[0-9a-fA-F]+)", out)
        if not m2:
            print(out)
            raise SystemExit(f"could not parse deploy address for {contract}")
        return m2.group(1)
    data = json.loads(m.group(0))
    return data["deployedTo"]


def send(to: str, sig: str, *args: str) -> None:
    cast(
        "send",
        to,
        sig,
        *args,
        "--private-key",
        PK,
        "--rpc-url",
        RPC,
        "--legacy",
        "--gas-price",
        GP,
    )


def main() -> None:
    dep = json.loads((ROOT / "deployments/97.deploy.json").read_text())
    usdc, usdt, usd1, usde, fdusd = dep["usdc"], dep["usdt"], dep["usd1"], dep["usde"], dep["fdusd"]
    toks5 = [usdc, usdt, usd1, usde, fdusd]

    # Extra mint (idempotent enough; TestnetERC20 mint is open to deployer)
    mint_amt = str(int(SEED) * 20)
    for t in toks5:
        send(t, "mint(address,uint256)", dep.get("deployer", "0x57b3771F6b772C52E81646Aa007D1Ab28d91B3Fe"), mint_amt)

    print("== Curve 3pool ==")
    curve3 = forge_create(
        "src/incumbents/curve/StableSwapPool.sol:StableSwapPool",
        [f"[{usdt},{usdc},{usd1}]", CURVE_A, CURVE_FEE],
    )
    for t in (usdt, usdc, usd1):
        send(t, "approve(address,uint256)", curve3, SEED)
    # add_liquidity(uint256[] amounts, uint256 min_mint)
    send(curve3, "add_liquidity(uint256[],uint256)", f"[{SEED},{SEED},{SEED}]", "0")

    print("== Curve USDT/USDE ==")
    curve_usde = forge_create(
        "src/incumbents/curve/StableSwapPool.sol:StableSwapPool",
        [f"[{usdt},{usde}]", CURVE_A, CURVE_FEE],
    )
    for t in (usdt, usde):
        send(t, "approve(address,uint256)", curve_usde, SEED)
    send(curve_usde, "add_liquidity(uint256[],uint256)", f"[{SEED},{SEED}]", "0")

    print("== Curve USDC/FDUSD ==")
    curve_fd = forge_create(
        "src/incumbents/curve/StableSwapPool.sol:StableSwapPool",
        [f"[{usdc},{fdusd}]", CURVE_A, CURVE_FEE],
    )
    for t in (usdc, fdusd):
        send(t, "approve(address,uint256)", curve_fd, SEED)
    send(curve_fd, "add_liquidity(uint256[],uint256)", f"[{SEED},{SEED}]", "0")

    print("== LiteCL factory + pools ==")
    clf = forge_create("src/incumbents/univ4/LiteCLPool.sol:LiteCLFactory", [])
    n_cl = 0
    for i, a in enumerate(toks5):
        for b in toks5[i + 1 :]:
            for fee in (FEE_ULTRA, FEE_1BP):
                out = cast(
                    "send",
                    clf,
                    "createPool(address,address,uint24,int24)",
                    a,
                    b,
                    fee,
                    TICK,
                    "--private-key",
                    PK,
                    "--rpc-url",
                    RPC,
                    "--legacy",
                    "--gas-price",
                    GP,
                    "--json",
                )
                # decode pool from return or event — call getPool after
                pool = cast(
                    "call",
                    clf,
                    "getPool(address,address,uint24)(address)",
                    a,
                    b,
                    fee,
                    "--rpc-url",
                    RPC,
                ).strip()
                if pool == "0x0000000000000000000000000000000000000000":
                    # try reversed
                    pool = cast(
                        "call",
                        clf,
                        "getPool(address,address,uint24)(address)",
                        b,
                        a,
                        fee,
                        "--rpc-url",
                        RPC,
                    ).strip()
                print(f"  CL pool {a[:8]}…/{b[:8]}… fee={fee} -> {pool}")
                send(a, "approve(address,uint256)", pool, SEED)
                send(b, "approve(address,uint256)", pool, SEED)
                send(pool, "mint(uint256,uint256,address)", SEED, SEED, "0x57b3771F6b772C52E81646Aa007D1Ab28d91B3Fe")
                n_cl += 1

    print("== Wombat ==")
    wombat = forge_create(
        "src/incumbents/wombat/WombatLite.sol:WombatLite",
        [f"[{usdc},{usdt},{usd1},{usde}]", WOMBAT_K, WOMBAT_FEE],
    )
    for t in (usdc, usdt, usd1, usde):
        send(t, "approve(address,uint256)", wombat, SEED)
        send(wombat, "deposit(address,uint256,uint256)", t, SEED, "0")

    print("== Fluid factory + pools ==")
    ff = forge_create("src/incumbents/fluid/FluidDexPool.sol:FluidDexFactory", [])
    pairs = [
        (usdt, usdc),
        (usdt, usd1),
        (usdc, usd1),
        (usdt, usde),
        (usdc, fdusd),
        (usdt, fdusd),
    ]
    n_fluid = 0
    fluid_pools = []
    for a, b in pairs:
        cast(
            "send",
            ff,
            "createPool(address,address,uint256,uint256,uint256,uint256)",
            a,
            b,
            FLUID_FEE,
            FLUID_RANGE,
            FLUID_RANGE,
            FLUID_CENTER,
            "--private-key",
            PK,
            "--rpc-url",
            RPC,
            "--legacy",
            "--gas-price",
            GP,
        )
        pool = cast(
            "call",
            ff,
            "getPool(address,address)(address)",
            a,
            b,
            "--rpc-url",
            RPC,
        ).strip()
        if pool.endswith("000000000000000000000000"):
            pool = cast(
                "call",
                ff,
                "getPool(address,address)(address)",
                b,
                a,
                "--rpc-url",
                RPC,
            ).strip()
        print(f"  Fluid {a[:8]}…/{b[:8]}… -> {pool}")
        send(a, "approve(address,uint256)", pool, SEED)
        send(b, "approve(address,uint256)", pool, SEED)
        send(pool, "initialize(uint256,uint256)", SEED, SEED)
        fluid_pools.append(pool)
        n_fluid += 1

    out = {
        "chainId": 97,
        "usdc": usdc,
        "usdt": usdt,
        "usd1": usd1,
        "usde": usde,
        "fdusd": fdusd,
        "curve3pool": curve3,
        "curveUsdeUsdt": curve_usde,
        "curveFdusdUsdc": curve_fd,
        "clFactory": clf,
        "clFeeUltra": int(FEE_ULTRA),
        "clFee1bp": int(FEE_1BP),
        "nClPools": n_cl,
        "wombat": wombat,
        "fluidFactory": ff,
        "nFluidPools": n_fluid,
        "fluidPools": fluid_pools,
    }
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps(out, indent=2) + "\n")
    print("wrote", OUT_PATH)
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
