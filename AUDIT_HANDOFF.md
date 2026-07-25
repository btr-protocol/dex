# BTR DEX — Cycle 9 Consolidated Report (5 Cohorts + Dual Cross-Validation)

**Purpose:** Single handoff after five independent Rush cohorts and two full-slate cross-validators. Every finding was reviewed against the combined slate. **No fixes applied.**  
**Tree:** on-disk dirty working tree · committed tip `7fce10a`  
**Confirm:** `git -C dex rev-parse --short HEAD && git -C dex status -sb`  
**Scope:** `evm/src` production (excl. incumbents / testnet / Mock)  
**Nature:** Agent-led. Not a firm audit.

---

## Method

| Phase | Cohorts | Mandate |
|---|---|---|
| Find | **1** Oracle · **2** AMM/Pricing · **3** Access/Admin/Hooks/Flash · **4** Gas · **5** Lean/consistency | Independent Grok 4.5 |
| Cross-val | **X1** · **X2** | Each reviews **all** findings from 1–5; CONFIRM / DOWNGRADE / REJECT |

Prior Cycle 8 items O-01/O-02 (empty-curve buy floor, maxDispersion cap): **CLOSED** on disk (`835cab6` + dirty floors). Verified by Cohorts 2, X1, X2.

---

## Snapshot (post dual cross-val)

| Class | Count |
|---|---:|
| Crit / High | **0** |
| Med (disputed) | **1 technical hole** — M-1a (X1 keeps Med; X2 → Low) |
| Low OPEN (both X agree CONFIRM) | **3–4** |
| Info / lean / gas KEEP | shortlist below |
| Discarded as noise / overgrade | listed |

**Headline:** No permissionless Crit/High. Primary eng fix: tighten M-1 abs-band validator (two-sided **or** refBand). Secondary: `RiskConfigUpdated` emit bug; hook `requireNoFlash`; three SAFE gas wins.

---

## Cohort IDs

| ID | Focus | Agent |
|---|---|---|
| [1](e05dea86-48fa-4f9c-8f41-1f324a5c5ab9) | Oracle security | Grok |
| [2](06c3283c-839a-4ff4-b1f9-e360669bbc72) | AMM / NUQuartic | Grok |
| [3](a86c61a2-6209-48d2-bea6-14963ff7c0ab) | Access / Admin / Flash / Hooks | Grok |
| [4](08ca0b26-82d8-4c8d-a794-853be6adb325) | Gas hot paths | Grok |
| [5](b1dbc269-6cb4-408f-bea7-854c84947610) | Lean / naming / events | Grok |
| [X1](81e5e2e7-3d34-4e74-8d4f-a4ad792cc48a) | Cross-val full slate | Grok |
| [X2](47cbc46f-7352-4469-8264-90d7afa77375) | Cross-val full slate (independent) | Grok |

---

## Cross-validation matrix (security)

| Finding | C1 | C2 | C3 | X1 | X2 | **FINAL** |
|---|---|---|---|---|---|---|
| **M-1a** one-sided abs as cumulative bound | Med | — | — | **CONFIRM Med** | CONFIRM ↓ **Low** | **OPEN — fix** (sev Med\|Low disputed; hole undisputed) |
| **M-1a-I** INTERNAL same OR | Med | — | — | fold into M-1a | ↓ Low | **Same fix as M-1a** |
| **GOV-10** untimelocked setAssetParams | — | — | Med | ↓ **Info** | ↓ **Info** | **Info / owner-trust** (not Fix-now vuln) |
| Factory orphans vs M-3 | — | — | Low | CONFIRM Low | CONFIRM Low | **OPEN Low** |
| Hook omit `requireNoFlash` | — | — | Low | CONFIRM Low | CONFIRM Low | **OPEN Low** |
| Hook code.length request-only | — | — | Low | ↓ Info | CONFIRM Low | **Info–Low** |
| flashFee uncapped | — | — | Low | ↓ Info | CONFIRM Low | **Info–Low** |
| YieldHook Merkl/cap untimelocked | — | — | Low | ↓ Info | ↓ Info | **Info** |
| Bootstrap seal optional | — | — | Info | DISCARD | CONFIRM Info | **Accepted policy** |
| Chainlink seq round completeness | Low | — | — | DISCARD | CONFIRM Low | **Optional Low** (split) |
| O-01 / O-02 closed | — | CONFIRM | — | CONFIRM | CONFIRM | **CLOSED** |
| AMM Crit/High | — | **0** | — | — | — | **None** |

---

## FINAL OPEN — eng shortlist (ranked)

### 1. M-1a — One-sided absolute reservation as M-1 “cumulative bound”
- **Status:** OPEN · hole **confirmed by C1, prior C, X1, X2**
- **Severity:** X1 = **Med** · X2 = **Low** (Chapel uses refBand; needs abs-only + quorum)
- **Where:** `PoolAdmin.requireExternalSpokeBound` `:123-124`; INTERNAL `:108`; `PoolIO.priceBandGuard` `:178` skips when `lo==0`
- **Claim:** Validator ORs `reservationPrice \|\| reservationPriceMax`. Ceiling-only does not halt downward walks.
- **Fix:** Require `(lo≠0 ∧ hi≠0) ∨ refBand` for EXTERNAL + INTERNAL; add opposite-direction regressions.
- **Challenge note for next team:** Decide Med vs Low; do not dispute the mechanism.

### 2. RiskConfigUpdated emit field swap
- **Status:** OPEN · **confirmed X1+X2+C5**
- **Sev:** Low (indexer)
- **Where:** `IAdmin.sol:180-182` `(minLiquidity, flags)` vs `Admin.sol:353` `emit(..., cfg.flags, 0)`
- **Fix:** Emit real asset `minLiquidity` (or drop field) + `cfg.flags`.

### 3. Hook writers omit `requireNoFlash`
- **Status:** OPEN · **confirmed X1+X2+C3**
- **Sev:** Low
- **Where:** `PoolAux` hookDeploy/Recall/CreditYield/WriteDown; flash mutex released after `flashSend` before callback
- **Fix:** `PoolIO.requireNoFlash()` on all four.

### 4. M-3 factory pre-registry orphans
- **Status:** OPEN · **confirmed X1+X2+C3**
- **Sev:** Low (ops DoS)
- **Where:** `createPool` append-only roster vs M-3 `spokes.length+2 == getPoolTokens.length`
- **Fix:** Completeness = listed spokes with `anchor==oldBase`, or register-on-init only.

### 5–7. SAFE gas (X1+X2 agree top)
| Rank | Item | Est |
|---|---|---:|
| 1 | Separate tcache for **refPrimary** | ~−2.1k / settle |
| 2 | Separate tcache for **INTERNAL breaker** (≠ peg key) | ~−2.1k |
| 3 | Dust buy: reuse mid `evalQ` when `width==0` | ~−1.0–1.2k |

**Reject as SAFE:** non-dust buy mid elimination (accuracy / O-01 adjacent).

### Lean KEEP (ship with next PR)
| Item | Why |
|---|---|
| Stale EXTERNAL no-op comment `PoolAdminWrite:147` | False post M-1 |
| `TreasuryUpdated` / `BaseTokenMigrated` `old*=0` | Indexer |
| Rename `validateInternalMode` | Now gates EXTERNAL |
| OBS-03 NatSpec on wrong event | Docs |
| `STALE_GRACE_CAP_S` share with lag | Ops coupling (Info) |
| Factor INTERNAL/EXTERNAL bound predicate | Prevents M-1a fork |
| Auth/zero dialect (Admin Ownable vs Err; ZeroAddr vs ZeroValue) | Consistency (optional) |

---

## DISCARDED / DOWNGRADED (do not re-litigate as Fix-now Med+)

| Item | Final |
|---|---|
| GOV-10 untimelocked setAssetParams as Med | **Info** — owner-trust (X1∩X2) |
| Bootstrap seal optional | Accepted policy |
| Auth/ZeroAddr/compute-calculate naming as security | Lean only |
| UniPool chainid literals | Intentional testnet gate |
| areaQ same-seg as headline gas | Micro backlog |
| AssetAdded minLiq=0 as bug | True today (never set) |
| Permissionless AMM drain in Pricing/NUQuartic | None found (C2) |

---

## Verified sound (multi-cohort)

Empty-curve floors · dispersion write-cap · k-of-n · sourceTs · σ floor · `Oracle.gate` · flash R13 + inflight on pull · M-3 atomic re-root (when roster clean) · R-1 B64 · wall-strip / FLAG_REQUIRES_WALL · cov-toll peg clamp · Lemma-B haircuts · UniPool chainid gate · Chainlink sequencer+grace (core).

---

## Suggested eng order

1. M-1a validator tighten + tests  
2. `RiskConfigUpdated` emit  
3. Hook `requireNoFlash`  
4. Gas SAFE 1→2→3 (GasProbe)  
5. Lean comment/events/rename  
6. M-3 orphan hygiene  

Then re-run ≥2 cohorts on the fixed tip until OPEN security = 0.

---

## Verify

```bash
cd dex && git rev-parse --short HEAD && git status -sb
cd evm && forge test --match-contract 'AuditPatchRegressions|ExternalOracle|Pricing|PoolAdmin|AimmInvariants|GasProbe' --summary
```

---

_End Cycle 9 five-cohort consolidated report. No code changes by this agent cycle._
