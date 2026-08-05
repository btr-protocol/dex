# Satellite CDP: LP collateral → btrUSD / btrBTC / btrETH / btrGOLD

Status: design + scaffolding plan. Not shipping on Arc/Sepolia V1.
Sources: LP mechanics / risk / architecture expert panels (2026-08-04). Not a security audit.

## 0. Verdict

| Decision | Choice |
|---|---|
| Placement | **Satellite** singleton (`CDPEngine`); pool unchanged for MVP |
| LOC budget | ~1.0–1.5k Solidity (+ tests separate) |
| Collateral | Per-leg `LPToken` receipts only |
| Debt | Four ERC-20s: `btrUSD`, `btrBTC`, `btrETH`, `btrGOLD` |
| Matching | **Same-denom only** (USD-like LP → btrUSD, …) |
| Hooked legs | **LTV 0 in V1** (hookless collateral only) |
| Params | **Separate collateral registry** (not `Pool.RiskConfig`) |
| Launch LTV | Stable Core canonical **85 / 90**, not 95% |
| V1 ship | **No** (after audits + Arc ceremony on explicit go) |

## 1. LP receipt facts (collateral input)

- Non-rebasing ERC-20 per `(pool, leg)`. Balance fixed; claim = $S \cdot I / 10^{18}$.
- Fees / yield raise $I$; decay / `hookWriteDown` lower $I$ (can hit **0**, terminal wipe).
- Exit may apply coverage haircut (`previewWithdraw`); face ≠ cash when $R < L$.
- Transferable subject to frozen-amount JIT lock (≤300s). CDP can hold LP; no pool hook needed on transfer.
- Price collateral via `previewWithdraw` (+ pending decay / liquid capacity checks), never `decimals()` or raw index alone.

## 2. Risk model (V1)

### Health

$$
F = s I_t / 10^{18},\quad R = F(1-h_c),\quad V = R \cdot \min(1,p_b) \cdot (1-h_l-h_o)
$$

$$
D \le V \cdot \mathrm{LTV},\qquad HF = V \cdot LT / D
$$

Collateral rounds down; debt rounds up. Never credit upward basis ($p_b > 1 \Rightarrow 1$).

### Tiers (initial)

| Collateral class | LTV | LT | Bonus |
|---|---|---|---|
| Stable Core canonical (e.g. USDC leg, hookless) | **85%** | **90%** | 3% |
| Stable Core non-canonical USD-like | 75–80% | 85% | 5% |
| Matched asset from volatile pool (incl. volatile USDC) | 70–75% | 80% | 7% |
| Gold wrappers | 50–60% | 68% | 10% |
| **Any hooked leg** | **0%** | — | — |

Reject 95% LTV at launch: with LT 97% + 2% bonus, liquidation consumes ~99% of collateral; residual cannot absorb oracle lag, write-down, or exit friction. Bound enforced on-chain: $\mathrm{LTV} \le (1-S-M)/(1+B)$ with $S{=}5\%$, $M{=}2\%$, $B{=}$liq bonus (see `CdpDefaults.TIER_S_BPS` / `TIER_M_BPS` / `CdpValuation.maxLtvForBonus`). Hard cap formerly 90% alone; formula is now the gate (canonical 85/90/3 ⇒ max LTV ≈ 90.29%).

### Marks (mint vs liq)

- **Mint / LTV enforce:** `Oracle.gate` fail-closed (stale TTL, same-block signed, paused, zero).
- **Liquidate:** last-good mark if only TTL/same-block would fail (`resolveBasisLiq`); paused / zero still revert (INT-10).

### Capacity (`maxRedeem`)

Liquid $R_{\mathrm{liq}}-\mathrm{minLiquidity}$ and anti-JIT only. Hook recall omitted (INT-09); hooked legs are mint-ineligible via live `getAssetHook`. Capacity short blocks **new debt** only; repay / add-collateral still allowed (C14-04).

### Liquidation

- Liquidator repays matching btr* debt; receives **LP receipts** (do not force synchronous `pool.withdraw` if paused / hook-illiquid).
- Close factor 50% for $0.95 \le HF < 1$; full below 0.95 or dust.
- Penalty split ~80% liquidator / 20% denom backstop. Bad debt stays inside that synthetic family.

### Ceilings (sketch)

- Per collateral: ≤5% of leg liabilities and ≤10% of liquid exit capacity (Stable Core); tighter on volatile/gold.
- Per vault ≤10% of that collateral’s ceiling; per collateral ≤40% of synthetic supply.
- No liquid btr* market ⇒ do not raise ceilings.

## 3. Architecture

```
CDPEngine (singleton)
  ├─ CollateralRegistry: lpToken → {pool, leg, denom, LTV, LT, bonus, ceiling, hooked?}
  ├─ positions: owner × (lpToken, debtToken) → {coll, debt}
  └─ valuation: previewWithdraw + mark (respect usdQuoted / same-denom)
       │
       ├─ mint/burn → DebtToken {btrUSD, btrBTC, btrETH, btrGOLD}
       └─ custody   → LPToken (transferFrom; no pool mutate on open)
```

**Surface:** `open` / `adjust` / `repay` / `close` / `liquidate` / `healthFactor` / views.

**Pool touch:** 0 required. Optional later: `maxRedeem` view (~80–120 LOC). Reject embedding borrow in `PoolStorage` or LP transfer hooks.

## 4. Invariants (MVP)

1. Debt denom matches collateral registry denom (same-denom hard gate).
2. Hooked / wiped (`I==0`) / frozen / paused legs: mint LTV = 0.
3. $D \le V\cdot\mathrm{LTV}$ after every open/adjust; liquidate only if $HF < 1$.
4. Debt token `mint`/`burn` only from `CDPEngine`.
5. Ceilings enforced per collateral and globally per synthetic.
6. No recursive leverage privilege: minted btr* buying more LP is market risk, not a protocol loop.

## 5. Do not

- Ship CDP on Arc/Sepolia V1 ceremony.
- 95% LTV at launch; hooked collateral in V1; basket / cross-denom mint.
- Force redeem through pool on every liquidation.
- Put LTV inside `Pool.RiskConfig` (couples beacon upgrades to CDP policy).
- Treat `previewWithdraw` alone as liquid capacity proof.
- OPT-01 / G02 / Arc broadcast / Sepolia scale-to-0 as part of this track.

## 6. Scaffolding plan (implementation order)

Paths relative to `dex/evm` unless noted.

| Phase | Deliverable | Notes |
|---|---|---|
| **D0** | This doc | done |
| **D1** | `src/interfaces/ICdp.sol` | Types, events, errors; no logic |
| **D2** | `src/DebtToken.sol` | Solady ERC-20; engine-only mint/burn; factory or ×4 |
| **D3** | `src/CollateralRegistry.sol` | Owner/timelocked listing; hooked flag; ceilings |
| **D4** | `src/CDPEngine.sol` | Positions + valuation + liq; ~600–900 LOC |
| **D5** | `src/libraries/CdpValuation.sol` | Library: haircut, basis clamp, denom mark |
| **D6** | Tests | Same-denom reject; LTV fence; hook LTV0; wipe $I{=}0$; liq close factor |
| **D7** | Optional pool `maxRedeem` | Only if liquidation UX needs it |
| **D8** | Keepers | Liquidation bot; debt ceiling monitors (separate from oracle pusher) |

Suggested layout:

```
dex/evm/src/
  CDPEngine.sol
  CollateralRegistry.sol
  DebtToken.sol
  interfaces/ICdp.sol
  interfaces/ICdpPoolView.sol
  interfaces/IDebtToken.sol
  libraries/CdpValuation.sol
  libraries/CdpTimelock.sol
  libraries/CdpConstants.sol
dex/evm/test/cdp/
  CdpSameDenom.t.sol
  CdpLtv.t.sol
  CdpLiquidation.t.sol
dex/docs/cdp-lp-satellite-design.md   ← this file
```

Governance: reuse shared `AccessControl` + LOW/HIGH timelock for registry / LTV changes; guardian can freeze minting per debt token.

## 7. Open questions (block implementation kickoff)

1. Exact USD-like allowlist per pool (USDC-only vs USDT/DAI/GHO on Stable Core).
2. btrGOLD underlying (XAUT vs PAXG) and custody basis oracle.
3. Interest / stability fee: 0 in V1 vs small rate to backstop.
4. Whether liquidators must be whitelisted keepers on testnet.
5. Cross-chain: one engine per chain; no shared debt until bridge design exists.

## 8. Sequencing vs rest of stack

1. Finish audit Medium residuals (done in working tree; uncommitted).
2. This CDP design (here).
3. Arc deploy only on explicit user go.
4. CDP implementation after Arc/oracle maturity + hookless Stable Core live.
