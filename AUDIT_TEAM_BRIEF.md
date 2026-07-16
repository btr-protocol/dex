# BTR DEX — Team Review Brief (Audit from-scratch, 2026-07-10)

**Audience:** eng / security / ops reviewing this wave before merge or Chapel redeploy.  
**Author:** Cursor agent (Grok 4.5 cohorts) · **Date:** 2026-07-10  
**Companion:** technical cycle log in [`AUDIT_REPORT.md`](AUDIT_REPORT.md)

---

## 1. TL;DR (read this first)

We ran a **from-scratch multi-cohort audit** of the AIMM DEX + keeper oracle path (NX Rates → θ/heartbeat → `ExternalOracle`), with priorities:

1. **Minimize swap gas**
2. **Security**
3. **Lean / clean code**

**Outcome:** converged after **3 cycles**. **0 Critical / High / Med** open. Warm 1-hop swap gas down **≈10%**. Two Low bugs fixed (batchSwap WETH unwrap; decay re-enable catch-up).

| Metric | Result |
|---|---|
| Warm `base→spoke` swap | 61 243 → **54 890** (−10.4%) |
| Warm `spoke→base` swap | 55 827 → **49 499** (−11.3%) |
| Warm `spoke↔spoke` swap | 83 952 → **75 978** (−9.5%) |
| Forge tests | **332 passed** (excl. env-gated `DeployScript`) |
| EIP-170 | `PoolSwap` ~16.2 KB (headroom ~8 KB); `Pool` ~21.6 KB |

**What you should review:** the file map in §5, the two Low bug fixes in §4, and run the commands in §7.

---

## 2. What this audit is (and is not)

### Is
- Fresh security + gas + lean pass on **current** `dex/evm/src` (excl. incumbents/testnet) + `keepers/src/oracle` + `executor.rs`
- Iterative: 3 Grok 4.5 auditor lenses → challengers (≥2/3) → fix + regression → re-audit until a clean batch
- Builds on (does not re-litigate) the earlier 5-cycle report that already fixed the HIGH cross-exit haircut bypass, same-block oracle clamp, Spline overshoot, etc.

### Is not
- An external firm audit / formal verification
- A review of Chapel **incumbent forks** (Curve/UniV4/Wombat/Fluid) — out of product scope
- A guarantee that Chapel **already-deployed** clones pick up these bytecode changes (they need **redeploy** of Pool impl + libraries)

---

## 3. Method (so reviewers can trust the process)

```
P1 Discover → GasProbe baseline
     ↓
Cycle N:  Cohort A Security  |  Cohort B Gas-swap  |  Cohort C Lean
     ↓
          2–3 Challengers (adversarial refute / severity)
     ↓
          Fix only ≥2/3 confirmed  +  Foundry regressions
     ↓
Cycle N+1 on fixed tree … until CONVERGED
```

- Model constraint: **Grok 4.5 only** for auditors/challengers.
- Gas SSoT: [`evm/test/gas/GasProbe.t.sol`](evm/test/gas/GasProbe.t.sol) (cold = fresh tx; warm = same-tx repeat — note TransientCache warms on warm path).
- Prior accepted designs (single oracle key, owner=pauser, etc.) were **not** re-opened as findings.

---

## 4. What we fixed (review these)

### 4.1 Gas / lean (swap hot path) — largest wins

| ID | Change | Why it matters | Where |
|---|---|---|---|
| **G-1 / L-1** | **Deleted `PoolSwapQuote`**. `PoolSwap` calls `PoolIO.exec` directly | Removed ~1.5–2.5k gas DELEGATECALL + ABI encode of full `SwapQuote` every swap | `PoolSwap.sol`; file removed |
| **G-2** | Exec quotes skip `routeHops` / `hopAmounts` / `hopPrices` alloc | Arrays only needed for UI `getSwapQuote` (`analytics=true`) | `Pricing.sol` `_quotePath` / `_walkLegs` |
| **G-4 / G2-5** | One `riskConfigs` SLOAD shared by halt/swap gate + decay early-out | Was loaded twice per token on swap / batch / `swapLiability` | `PoolIO.checkRiskFlags`, `PoolDecay.applyDecay(asset, rc)`, `PoolSwap`, `PoolBatch`, `PoolLiquidity` |
| **G-5** | Dropped post-`exec` `minLiquidity` check | Strictly dominated by `exec`’s `minReq` gate | `PoolSwap.sol` |
| **G-6 / G-9** | `OracleConfig` / `RiskConfig` as **storage** refs on hot path | Avoided full struct memory copies | `Pricing._fetchFeed`, `_executeLeg` |
| **G-7** | `if (protoFee != 0)` before `protocolFees` SSTORE | No useless mapping write when fee rounds to 0 | `PoolIO.exec` |
| **G2-4** | `exec(..., aIn, aOut)` overload | Reuses Asset refs already warm after decay | `PoolIO`, callers |
| **L-4** | Deleted empty `IExchange` alias | Dead ABI surface | `interfaces/modules/IExchange.sol` gone |
| **L-6** | Removed dead `FLASH_ENABLED` branch in `checkRisk` | Flash gates the bit itself | `PoolIO.sol` |
| **L-12** | `calculateDepth`: `return 1` (was `? 1 : 1`) | Dead ternary | `Pricing.sol` |
| **L2-1** | Removed unreachable `profileAsset == base` branch | Depth-1 star ⇒ profile asset is always the spoke | `Pricing._legMarkAndFees` |

**Pricing math / quote outputs were not intentionally changed** for these gas wins (same marks, same spline, same fees). Reviewers: spot-check a few `getSwapQuote` golden cases if you have them.

### 4.2 Security / correctness — Low bugs

#### A-07 — `batchSwap` always unwrapped WETH → ETH
- **Bug:** packing the **wnative address** as an output still called `push(NATIVE)` → unwrap. Single-path `swap` does **not**.
- **Impact:** contract recipients / aggregators expecting WETH revert or get wrong asset.
- **Fix:** unwrap **only** if calldata packed `SC.NATIVE`; otherwise push ERC-20 (incl. wnative).
- **Regression:** [`evm/test/unit/BatchSwapNativeParity.t.sol`](evm/test/unit/BatchSwapNativeParity.t.sol)  
  `test_batchSwap_wnative_output_delivers_erc20_not_eth`

#### A2-1 — Decay catch-up across disabled windows
- **Bug:** while decay is off, hot path correctly does **0 SSTORE** (no `lastUpdate` bump). On (re)enable, first `applyDecay` used ancient `lastUpdate` → could socialize up to full deficit in one touch.
- **Fix (admin path, not hot path):**
  1. `initAsset` seeds `lastUpdate = now`
  2. `setRiskConfig`: if decay transitions off→on, reset `lastUpdate = now`
- **Hot path stays gas-clean** when decay disabled.
- **Regression:** `test_applyDecay_noRetroactiveCatchUpAfterReenable` in [`PoolDecay.t.sol`](evm/test/unit/PoolDecay.t.sol)

### 4.3 Explicitly NOT fixed (accepted / deferred)

| Item | Why left alone |
|---|---|
| Single oracle pusher key | Accepted; on-chain `maxDeviation` + 1 push/feed/block bounds P4 |
| Owner = pauser | Accepted; dedicated pauser = mainnet hardening |
| Untimelocked `setAssetParams` | Accepted owner trust model |
| Bootstrap `addAsset` until `sealBootstrap` | Accepted GOV-03 latch |
| Base `SWAP_ENABLED` vs hub flow | **By design:** hub kill = `HALT_MASK`, not clearing SWAP on base |
| `UniPoolOracle` spot manipulable | **Do not use as production primary** — keeper `ExternalOracle` is canonical |
| Storage: drop `lastLPStakeTime` / init `liquidityIndex` | Would shift slots on **live Chapel clones** |
| NatSpec archaeology trim | Cosmetic only |
| Keeper `PENDING_TTL` double-push under RPC flake | Bounded by `maxDeviation`; sync-from-chain deferred |
| Push confidence CI-halt DoS | Fail-closed under accepted pusher key |

---

## 5. File map — what to open in review

### Must-read (behavior / gas)

| File | What changed |
|---|---|
| [`evm/src/libraries/PoolSwap.sol`](evm/src/libraries/PoolSwap.sol) | Inline exec; shared risk+decay; Asset refs into exec; no post minLiq |
| [`evm/src/libraries/PoolIO.sol`](evm/src/libraries/PoolIO.sol) | `checkRiskFlags`; `exec` overload; `protoFee` guard |
| [`evm/src/libraries/PoolDecay.sol`](evm/src/libraries/PoolDecay.sol) | `applyDecay(asset, rc)` overload; disabled = full no-op |
| [`evm/src/libraries/Pricing.sol`](evm/src/libraries/Pricing.sol) | Analytics-gated hop arrays; storage cfg; dead base branch gone |
| [`evm/src/libraries/PoolBatch.sol`](evm/src/libraries/PoolBatch.sol) | Native unwrap parity; shared risk SLOAD; exec refs |
| [`evm/src/libraries/PoolAdmin.sol`](evm/src/libraries/PoolAdmin.sol) | Seed `lastUpdate` on init |
| [`evm/src/libraries/PoolAdminWrite.sol`](evm/src/libraries/PoolAdminWrite.sol) | Decay (re)enable clock reset |
| [`evm/src/libraries/PoolLiquidity.sol`](evm/src/libraries/PoolLiquidity.sol) | `swapLiability` shared risk SLOAD |

### Deleted

| File | Reason |
|---|---|
| `evm/src/libraries/PoolSwapQuote.sol` | Trampoline only — inlined |
| `evm/src/interfaces/modules/IExchange.sol` | Empty `IPool` alias |

### Tests added / extended

| File | Covers |
|---|---|
| `evm/test/unit/BatchSwapNativeParity.t.sol` | A-07 |
| `evm/test/unit/PoolDecay.t.sol` | A2-1 (+ existing decay no-op tests) |
| `evm/test/gas/GasProbe.t.sol` | Gas SSoT (may already be on branch) |

### Docs

| File | Role |
|---|---|
| [`AUDIT_REPORT.md`](AUDIT_REPORT.md) | Cycle-by-cycle auditor log + gas table |
| [`AUDIT_TEAM_BRIEF.md`](AUDIT_TEAM_BRIEF.md) | **This document** |
| `README.md` / `evm/README.md` | Dropped `PoolSwapQuote` from library list |

### Keepers (related, light touch this wave)

| File | Note |
|---|---|
| `keepers/src/executor.rs` | Chapel gas floor 0.1 gwei (ops; from Chapel bring-up) |
| `keepers/oracle.chapel.toml` | Live feed IDs for chain 97 (ops config) |

---

## 6. Git / working-tree state (important for reviewers)

`dex` is **ahead of `origin/main`** with recent commits that already include a large remediation + gas wave (incl. `PoolSwapQuote` deletion, batch unwrap, decay no-op).  

**Additional uncommitted deltas** from cycle 2 of this session (as of report write):

- `PoolAdmin.sol` / `PoolAdminWrite.sol` — A2-1 clock reset  
- `PoolIO` / `PoolSwap` / `PoolBatch` / `PoolLiquidity` / `Pricing` — G2-4/G2-5/L2-1  
- `BatchSwapNativeParity.t.sol` (untracked)  
- `PoolDecay.t.sol` A2-1 test  
- Rewritten `AUDIT_REPORT.md` + this brief  

```bash
cd ~/Work/btr/dex
git status -sb
git diff HEAD -- evm/src/libraries/ evm/test/unit/
```

**Ask before commit:** this brief does not create a git commit. When ready, commit the unstaged audit leftovers + tests + docs as one “audit cycle 2” commit (or squash with the prior remediation commit per your process).

**Chapel note:** deployed Pool clones still run **old** linked library bytecode until you redeploy the Pool implementation (+ linked libs) and point the factory / clones at it.

---

## 7. How to verify (copy-paste)

```bash
cd ~/Work/btr/dex/evm

# Full suite (skip env-gated deploy script)
forge test --no-match-path 'test/unit/DeployScript.t.sol'

# Targeted regressions
forge test --match-contract 'BatchSwapNativeParityTest|PoolDecayTest' -vv

# Gas probes (compare to table in §1)
forge test --match-contract GasProbeTest -vv | rg 'PROBE swap_'

# Bytecode sizes / EIP-170 headroom
forge build --sizes 2>&1 | rg 'PoolSwap|Pool '
```

**Manual review checklist**

- [ ] `batchSwap` with output = wnative **address** delivers WETH ERC-20 (not ETH)
- [ ] `batchSwap` with output = `SC.NATIVE` still unwraps to ETH
- [ ] Decay off → swap does not SSTORE `lastUpdate` (gas / storage)
- [ ] Decay off→on via `setRiskConfig` does not dump full deficit in one block
- [ ] `getSwapQuote` still returns hop arrays; `swap` path does not need them
- [x] No import of `PoolSwapQuote` / `IExchange` left in SDK/front (grep — docs swept 2026-07-16)

```bash
rg -n 'PoolSwapQuote|IExchange' ~/Work/btr/dex ~/Work/btr/sdk ~/Work/btr/front
```

---

## 8. Residual INFO (not blocking)

1. **Batch hub decay:** if base is only an interior hop, decay may not run on base that tx — OK with κ_base≡0.
2. **Payable ERC-20 entrypoints:** accidental `msg.value` can strand ETH (no sweep).
3. **`flashFeeBps` unbounded:** admin misconfig can DoS flash path, not drain reserves.

---

## 9. Suggested next steps for the team

1. **Code review** this brief’s must-read files (§5) + run §7.
2. **Commit** unstaged audit leftovers when happy.
3. **Decide Chapel redeploy** of Pool impl if you want gas/bugfixes on the live testnet instance (clones don’t auto-upgrade).
4. **Mainnet hardening backlog** (not this PR): dedicated pauser role; timelock fee/haircut/reservation; optional 2-of-N oracle; never wire `UniPoolOracle` as primary.
5. Optional micro gas (deferred): hoist `$.baseToken`, fixed-size `RoutePath`, EndpointCache mark pass — expected ≤500 warm gas.

---

## 10. One-paragraph status for Slack / standup

> From-scratch Grok 4.5 audit of AIMM DEX + keeper oracle path: 5 cycles on main, ~10% warm swap gas cut, Low bugs fixed (batchSwap WETH unwrap; decay re-enable clock), cycle-4 lean deletes, cycles 4–5 security/gas CONVERGED. Review `dex/AUDIT_TEAM_BRIEF.md` + `GasProbe`. Chapel needs Pool redeploy for bytecode.
---

*Questions / pushback: treat [`AUDIT_REPORT.md`](AUDIT_REPORT.md) as the finding ledger; this brief is the human review packet.*
