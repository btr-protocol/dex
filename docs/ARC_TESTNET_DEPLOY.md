# Arc Testnet deploy (5042002)

Prep notes for Stable Core + FX Core only. No volatile pool. Mirror of Sepolia ceremony with Arc deltas.

## Chain

| | |
|---|---|
| Chain ID | `5042002` |
| RPC | `https://rpc.testnet.arc.io` |
| Explorer | `https://testnet.arcscan.app` |
| Gas | native USDC (18d view) |
| ERC-20 USDC | `0x3600000000000000000000000000000000000000` (6d) |
| Faucet | `https://faucet.circle.com` |
| WETH9 | **none** → pool `wnative = address(0)` |

Confirmed: USDC proxy has no `deposit()` / `withdraw()`. Do not set `wrappedNative` to the USDC address.

## Pools

- **Stable Core:** USDC, USDT, USDe, USDS, USD1, USDG, PYUSD, RLUSD
- **FX Core:** USDC, EURC, QCAD, AUDF, BRLA, JPYC, KRW1
- **Volatile:** none

Risk SoT: `evm/deployments/arc-risk-params.json`.

## Scripts

```bash
cd ~/Work/btr/dex/evm

# 0. Seed marks (NXR snapshot) → deployments/5042002.seed-marks.json
#    bun run ~/Work/btr/sdk/scripts/fetch-seed-marks.ts  # ensure Arc roster covered

# 1. Predict oracle, fill NXR signed_quotes + keepers/oracle.arc.toml BEFORE broadcast
forge script script/ArcOracleDeploy.s.sol:ArcOracleDeploy \
  --sig "predictOracle()" --rpc-url arc

# 2. Oracle stack (AC + ExternalOracle + mocks except real USDC + feeds)
GUARDIAN=0x… forge script script/ArcOracleDeploy.s.sol:ArcOracleDeploy \
  --sig "deployOracle()" --rpc-url arc --slow   # simulate first
# then --broadcast --verify when Sepolia oracle is healthy and audit is green

# 3. Core + Stable pool (WNATIVE unset/0). No volatile.
WNATIVE=0x0000000000000000000000000000000000000000 \
GUARDIAN=0x… forge script script/ArcPoolDeploy.s.sol:ArcPoolDeploy \
  --sig "deployPools()" --rpc-url arc --slow

# 4. FX ceremony (if FX mocks/feeds not in phase-1): mintFxTokens → fetch marks → addFxFeeds → deployFxPool
```

## Keepers / k0s

| Artifact | Path |
|---|---|
| Primary oracle TOML | `keepers/oracle.arc.toml` |
| Ref oracle TOML | `keepers/oracle-reference.arc.toml` |
| Liquidity / flow | `keepers/liquidity.arc.toml` |
| Env example | `keepers/.env.arc.example` |

Helm: clone Sepolia values under `~/Work/nx/ops/k0s/services/` (`btr-keeper-oracle`, `btr-keeper-oracle-ref`, `btr-flow-bot`, …) with Arc RPC, chain_id `5042002`, image sha tags via BuildKit only. ns `btr`. Gas relay funded in **USDC**, not ETH.

NXR: new signed_quotes ConfigMap bound to predicted Arc oracle address + EIP-712 `chainId=5042002` (signatures do not cross from Sepolia).

## Predicted addresses (nonce 0, 2026-08-04)

| | |
|---|---|
| Deployer | `0x57b3771F6b772C52E81646Aa007D1Ab28d91B3Fe` |
| Guardian | `0xDc9478be9ceA6288574A45D9cD07C48F7f03ed73` |
| AccessControl (CREATE n=0) | `0xc74f321f0cfC6bd6437da7f7839907C85b049E27` |
| ExternalOracle (CREATE n=1) | `0x01a52C049896E36c00bd5FD3db788e4d11B216c5` |

Artifacts: `deployments/5042002.predict.json`, `5042002.seed-marks.json`. Dry-run SoT (not live): `5042002.deploy.DRY-RUN.json`. Sim of `deployOracle()` succeeded (~0.89 native USDC gas). **Do not send any deployer tx before broadcast** or prediction invalidates.

Same CREATE address as abandoned Sepolia primary is OK: EIP-712 binds `chainId`.

## Blockers before broadcast

1. ~~Sepolia primary oracle cutover~~ DONE 2026-08-04.
2. ~~Deployer funded on Arc~~ DONE 2026-08-04 (Circle faucet). Balances at check:
   - Native gas USDC (18d view): **10_000** (≥ ~1 needed; sim ~0.89).
   - ERC-20 USDC `0x3600…` (6d): **10_000** raw `1e10`.
   - Pool phase: `seedUsdPerLeg × 2` USDC (one USDC leg per Stable + FX; mocks minted). **`seedUsdPerLeg=4000` ⇒ 8_000 USDC 6d** of 10_000 held (2_000 buffer). Faucet top-up not required.
   - Nonce **0** ⇒ predicted AC/oracle addresses still valid.
3. ~~NXR Arc signed_quotes domain~~ CM LIVE (`nxr-signer-arc-config`); pods **replicas:0** (PARKED 2026-08-04 after Sepolia image-pull contention). Arm only when Sepolia primary is Ready; serial scale-up; image `nxr:arc5042002-2e5a0b4` (allowlist+5042002) must be cached first. See DRAFT arm checklist. **Do not arm until broadcast go.**
4. `5042002.seed-marks.json` refresh ≤5 min pre-broadcast (file present; `seedUsdPerLeg` must match risk JSON = **4000**).
5. Audit/Arc patches: A4-01 + partial ORA-MEV/DEN/hooks in tree; fix-agent cohort not closed/forge-green confirmed — **no broadcast until that cohort closes + commit**.

## One-shot broadcast (after faucet)

```bash
cd ~/Work/btr/dex/evm
set -a && source .env.arc && set +a
# refresh marks ≤5 min:
#   (Arc seed fetch path: regenerate deployments/5042002.seed-marks.json)
forge script script/ArcOracleDeploy.s.sol:ArcOracleDeploy \
  --sig "deployOracle()" --rpc-url arc --slow --broadcast --verify
# then fill keeper toml:
python3 ~/Work/btr/keepers/scripts/fill-oracle-config.py \
  --json deployments/5042002.deploy.json \
  --toml ~/Work/btr/keepers/oracle.arc.toml
# pools (Stable+FX only, WNATIVE=0):
forge script script/ArcPoolDeploy.s.sol:ArcPoolDeploy \
  --sig "deployPools()" --rpc-url arc --slow --broadcast
```

Post-fill: mount `oracle.arc.toml` as CM `btr-keeper-oracle-arc-config`, scale `btr-keeper-oracle-arc` replicas 1 (image sha via BuildKit).