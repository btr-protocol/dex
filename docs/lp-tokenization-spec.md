# Task 64: tokenized LP legs (per-leg ERC-20 receipts)

Status: stage 1 spec, awaiting sign-off. No code staged. Reviewed by four independent design
reviewers (cooldown, migration, accounting, integration); disagreements are recorded inline.

Paths are relative to `dex/evm` unless noted.

## 0. Verdicts up front

1. **Cooldown: holder-keyed with transfer bypass is rejected.** So is the lead's own transfer-gate.
   Ship a **frozen-amount lock** (option E) held in the LP token. Section 4.
2. **Migration: there is nothing to migrate.** Only Sepolia and anvil are deployed, and every
   `lpBalances` entry there was written by the deploy script against mock tokens. Redeploy clean.
   Section 6.
3. **Steady-state gas cost is +15.5k on deposit (+11.4%) and +17.2k on withdraw (+15.3%)**
   (re-measured, section 7). **This corrects an earlier figure of +3.7k/+3.4k in this spec, which was
   wrong by roughly 5x**: the first probe credited and debited in the same transaction, so the
   tokenized path was measured against warm accounts and dirty slots that a real transaction never
   gets. The reviewer who estimated +8k was closer than the lead's measurement. Still affordable on
   BSC, but it is a real cost and must not be sold as 2.7%.
4. **Four pre-existing bugs block this work.** Two of them break the `totalSupply` invariant the
   ERC-20 introduces, so they are prerequisites, not follow-ups. Section 8.
5. **Consensus was NOT reached.** All three panel experts objected on at least one axis. The
   surviving objections are recorded in section 16, not averaged away.

## 0.1 Why the wrapper DoS decides D versus E: scope, not delay

The fair objection is: if a receipt is untransferable for the cooldown anyway, why does freezing a
wrapper matter? Because the two options freeze **different things**.

- **Option D keys the cooldown to the ACCOUNT.** A mint stamps the recipient address, and while that
  stamp is live **the whole balance at that address** is frozen. Route a $1 deposit through an
  ERC-4626 wrapper and the wrapper's address is stamped, so the wrapper's **entire pooled balance**
  is frozen, including every other user's share. Repeat once per window: about 5,760 transactions a
  day on BSC at roughly $0.013 each, about **$75/day to keep every pooled LP wrapper permanently
  frozen**.
- **Option E keys the cooldown to the MINTED AMOUNT.** The same $1 deposit freezes $1. The wrapper's
  pre-existing balance stays transferable and every other user redeems normally.

Three details that make this worse than a delay, and that the delay framing hides:

1. **The griefer does not own the frozen funds.** They spend $1 of their own to freeze other
   people's balances. It is a third-party attack, not a self-inflicted wait.
2. **It is not one cooldown, it is permanent.** Re-stamping once per window renews the freeze
   indefinitely at a fixed daily cost. The victim never reaches the other side of the delay.
3. **Wrappers cannot refuse the deposit.** Accepting permissionless deposits is what an ERC-4626
   wrapper is. There is no configuration that opts out.

Both options carry the identical anti-JIT invariant (no share may leave within `cooldown` of its
mint), so E gives up nothing in security to remove this. That is the whole argument for E.

**E is not a simplification, and the earlier claim in this spec that it was is withdrawn.** Measured
honestly: E deletes about 19 lines and three enforcement sites from the pool (`_checkCooldown`, the
two call sites, the `swapLiability` timestamp carry, the `lastDepositTime` mapping) and adds about
15 to 18 lines to the token (the packed lock slot, the mint-side accumulate, the transfer/burn
check), plus the cooldown cap and the timelock routing of section 4.4. That is roughly line-neutral
and **concept-negative**: it removes the pool-side cooldown and the inherit rule but adds a frozen
accumulator that never decays, and it asks the reader to carry a non-obvious equivalence (bounding
outflow by `balance - frozen` is the same thing as "no share leaves within `cooldown` of its mint").
E is strictly option D plus a `uint224` field, an accumulate branch and a second compare clause, so
it is never simpler than D.

The credit for "it also removes the all-or-nothing cooldown defect" was double-counted, and the
credit for deleting the dead `lastLPStakeTime` does not belong to E at all: that field is dead
today and should be deleted regardless of this task.

**E is carried on its security merit alone**: it removes a permanent, $75/day, third-party freeze of
every pooled LP wrapper, at the cost of one extra storage field and a slightly harder mental model.
That is a good trade, but it is a trade, not a free simplification.

## 1. Confirmed: no snapshot, no transfer hook needed for value

Verified rather than assumed. The share to value converter is

```
value(user, leg) = shares * effIndex(assets[leg].liquidityIndex) / 1e18
```

Four call sites, all identical, all a function of `(shares, per-asset index)` and nothing else:
`libraries/PoolLiquidity.sol:160`, `:282`, `:307`, `libraries/PoolView.sol:20`.

Every accrual mutates the asset index, never a holder slot: `PoolLiquidity.sol:89` `raiseIndex`
(donate, `PoolAux.sol:325` `hookCreditYield`), `PoolDecay.sol:27`, `PoolAux.sol:356`. There is no
reward-per-share checkpoint and no accrual debt. **No `_beforeTokenTransfer` value hook, no
snapshotting.** The only per-holder state is the share balance and `lastDepositTime`, and the
latter gates access, not value.

Two consequences the brief did not anticipate:

- `IPool.sol:145 lastLPStakeTime` is **dead** (no reader, no writer, repo-wide). Delete it.
- The `R16 staking lpBalances drain` concern from `test/DistributorBridgeIntegration.t.sol:245` is
  **stale**: the `stakingAdjustLpBalance` callback is gone and Staking is `IStakable`-keyed. Nothing
  on chain reads `lpBalances` outside `PoolLiquidity` and the `Pool.sol:215` view.
- Value is **not monotone** (decay and write-down lower the index; the haircut is coverage
  dependent and is not in the index at all). That does not affect transferability, but it means
  `shares * index / 1e18` is the wrong price for any integrator. Section 5.

## 2. Architecture

**Per-leg satellite ERC-20, sole ledger. Not an adapter over `lpBalances`.**

The adapter alternative (pool keeps the ledger, token proxies writes back in) was evaluated and
**rejected on a hard blocker**: `PoolAux.sol:253` states the Solady reentrancy guard slot is shared
with `Pool` under DELEGATECALL, and `PoolHooks.postInflow` / `preOutflow` already call out to
external hook targets inside `nonReentrant` (`PoolLiquidity.sol:75`, `:175`). Any LP transfer
originating from a hook or from a wrapper reacting in the same transaction would re-enter
`Pool.lpTransfer` and revert. `PoolIO.requireNoFlash()` would additionally make transfers fail
non-deterministically during flash loans. An ERC-20 whose `transfer` fails unpredictably is not
integrable.

Deployment: **EIP-1167 clone with immutable args**, `LibClone.cloneDeterministic(impl, args, salt)`,
already imported at `PoolFactory.sol:11`. Salt `keccak256(pool, leg)`, so addresses are derivable
off chain with no registry read. Deployed from `PoolAux.adminInitAsset`, the point a leg is listed.

Args layout (45-byte 1167 prefix, args from offset 45):

| offset | width | field |
|---|---|---|
| 45 | 20 | `pool` |
| 65 | 20 | `asset` (post-`PoolIO.wrap`, so the native leg maps to wnative and gets one receipt) |
| 85 | 1 | `decimals` |
| 86 | 32 | `symbol` (bytes32, right-padded) |
| 118 | 32 | `name` (bytes32) |

Read with `extcodecopy` into scratch, not `LibClone.argsOnClone`: the latter allocates memory and
measured ~105 gas more per hot-path read.

**Disagreement recorded.** The migration reviewer argues for plain 1167 plus a storage `name`/
`symbol` set by an `initialize` call, because Etherscan reliably auto-detects the canonical 45-byte
1167 but frequently fails on 1167-with-args, leaving the token page unverified and possibly
breaking the token tracker. Cost of their option: about +25k per leg, roughly +0.8M for the fleet.
**Lead's decision: ship clone-with-args, and verify one clone manually on the explorer during the
testnet deploy.** If the explorer does not resolve it, fall back to plain 1167 plus `initialize`
before mainnet. This is cheap to reverse and expensive to over-plan.

## 3. Storage layout

### 3.1 `IPool.PoolStorage`

`test/PoolStorageLayout.t.sol:37-44` pins slots 3..8, 14, 15. Deleting `lpBalances` would shift
`protocolFees` from 8 to 7 and renumber everything after it, breaking the pin and the SDK map for
no benefit.

```solidity
// slot 7: was `mapping(address => mapping(address => uint256)) lpBalances`
uint256 __reserved_lpBalances;              // pin holder; never read, never written
...
// slot 11: was `mapping(user => mapping(asset => uint32)) lastDepositTime`  -> DELETED
// slot 12: was `mapping(user => mapping(lpToken => uint32)) lastLPStakeTime` -> DELETED (dead)
...
mapping(address leg => address) lpTokens;   // appended at tail
```

`lastDepositTime` is deleted from the pool because the cooldown state moves into the token
(section 4). Deleting slots 11 and 12 renumbers `factory` 13 to 11, `assetHooks` 14 to 12,
`invested` 15 to 13. Full redeploy is authorised, so this is free on chain, but it **must** be
mirrored in `sdk/src/pool/storage.ts:29-48` and `test/PoolStorageLayout.t.sol` in the same commit.

### 3.2 LP token storage

```solidity
struct Lock { uint32 stamp; uint224 frozen; }   // one slot
mapping(address => Lock) locks;                 // slot 0 of the clone
// + Solady ERC20's own balance/allowance/nonce/totalSupply slots (hashed, no collision)
```

`uint224` never truncates: `PoolLiquidity.sol:62` bounds the underlying at `uint128`, and shares are
`amt * 1e18 / index`, which at the post-change index base (section 5.1) equals `amt`.

### 3.3 `IPool.Asset` repack

Slot 1 today is `minLiquidity(128) + liquidityIndex(64) + lastUpdate(32) + presetId(16)` = 240 bits.
Repack to `minLiquidity(96) + liquidityIndex(96) + lastUpdate(32) + presetId(16) + deadSeedPow10(8)`
= 248 bits, same slot. Then set `LIQUIDITY_INDEX_INIT = 1e18`. Rationale in section 5.1.

The repack is **not** value-preserving, so it carries a storage migration. `lastUpdate` and `presetId`
keep their offsets (96+96 = 128+64), and `minLiquidity` keeps its low bit at 0, but `liquidityIndex`
moves its low bit from 128 to 96: a word written by the old impl reads back as `oldIndex << 32`, and
every share claims 2^32x its backing until it is corrected. `deadSeedPow10` occupies bits the old
word left zero, so a legacy leg reads the default seed. `PoolAux.adminRebaseIndexWidth` shifts each
listed leg back and must be batched into the beacon-upgrade transaction. A full redeploy would avoid
it, which is why this only bites when the repack ships ahead of section 3.1.

The rebase is a **shift only**. `LIQUIDITY_INDEX_INIT = 1e18` applies to newly listed legs; a legacy
leg keeps the 1e12 base, because rescaling its index without rescaling its shares multiplies every
claim by 1e6. Pinned by `test/AuditIndexRebaseClaim.t.sol`.

#### The zero-index legs

30 of the 33 live Sepolia legs store `liquidityIndex == 0`, verified read-only over `eth_call`
against 11155111. They are healthy: the deployed impl lazy-inits a stored 0 to 1e12 at read time
(DAI on the stable pool reconciles exactly, `getLPBalance * 1e12 / WAD == liabilities`). The explicit
`liquidityIndex = INIT` write at `PoolAdmin.sol:185` landed in `796ac93`, **after** those legs were
deployed.

This impl redefines 0 as "written down to a total loss, terminal". Skipping a zero leg in the rebase
would therefore zero it permanently: `mintIndex` reverts, withdraw computes `lp * 0 / WAD = 0` and
reverts, and no writer can restore it because every index writer multiplies an existing value. The
rebase **writes `LEGACY_LIQUIDITY_INDEX` back** for those legs.

A real wipe must still not be revived. It is distinguishable without a share supply, which does not
exist yet: both writers that can drive the index to 0 (`PoolDecay`, `hookWriteDown`) scale it by
`newLiabilities / oldLiabilities`, so index 0 implies liabilities 0; and after a wipe every credit
path fails closed on `mintIndex`, so liabilities can never return. The discriminator is therefore
`liabilities != 0`, and a wiped or never-credited leg stays terminal and must be re-listed.

### 3.4 Upgrade runbook

The atomic transaction is **upgrade + rebase only**. Seeding is a separate, later step.

Validator 1 was right that the seeding `donate` cannot be batched in: it calls
`PoolIO.checkRiskFlags`, so it reverts on any FROZEN or ASSET_PAUSED leg and would abort the whole
upgrade. Validator 2 was right that an unseeded migrated leg was unsafe, but only because
`seedDeadShares` reverted where the codebase's own policy is to skip. With the fail-closed defects
fixed (`PoolLiquidity.sol` ceil-divide, `PoolAux.hookCreditYield` skip), an unseeded leg is safe:
deposits, donates and swaps work, and the keeper's harvest skips the raise instead of reverting until
a credit large enough to carry the seed arrives.

**Pre-flight assertions**, over every live leg, read-only, before broadcasting anything:

- `minLiquidity == 0` on every leg (`SeedRiskFences.s.sol:149` already asserts the reservation-band
  half of this). Anything above `2**96` would wrap; anything nonzero means the word is not the shape
  the rebase assumes.
- `liquidityIndex` in `{0} union (2**32, 2**64)`. `0` is the lazy-init cohort; the open interval is a
  live 1e12-base index read through the OLD layout. A value at or below `2**32`, or at or above
  `2**64`, is outside the band the shift is exact for and must be triaged by hand.
- For each zero-index leg, `getLPBalance(deployer, leg) * 1e12 / WAD == liabilities`, off-chain. This
  is the reconciliation the on-chain `liabilities != 0` check stands in for; on-chain there is no
  share supply to compute it from.

**Sequence:**

1. Read-only pre-flight above. Halt on any leg that fails.
2. One transaction: `upgradeBeacon(newImpl)` then `adminRebaseIndexWidth(legs)` for every pool, all
   legs, owner-signed. Nothing else may touch a pool between the two calls.
3. Verify post-rebase: every leg's `previewWithdraw(leg, shares)` matches the value recorded in step
   1, to the wei. `adminRebaseIndexWidth` is not re-runnable and reverts `InvalidState` on a second
   pass, which is the intended idempotency guard.
4. Set `adminSetDeadSeedPow10` per leg (section 5.4) BEFORE seeding: the override only applies while
   the leg is unseeded.
5. Seed, later and per leg: unpause/unfreeze if needed, `donate` at least the seed, re-apply the risk
   flags. A leg left unseeded is safe indefinitely; it simply carries no pin floor yet.

Never: a rebase in a different transaction from the upgrade, a rescale to 1e18, or a `donate`
batched into the upgrade transaction.

## 4. Cooldown resolution

### 4.1 What the cooldown actually defends

`879577a` reversed the premise an earlier version of this section rested on. Swap, flash and
cross-withdraw LP fees now reach the index: `PoolIO.sol:140`, `PoolEdge.sol:62` and
`PoolLiquidity.sol:297` all call `PoolLiquidity.sol:126 accrueLpFee`, which books the retained fee
into `liabilities` and raises the index with `INDEX_REASON_FEE` (`Constants.sol:27`). The LP receipt
carries a continuous coupon, triggerable by any swapper or flash borrower.
`docs/dex/3. Security/3.4. Flow Guards.md:154-167` is therefore correct in kind: JIT fee capture is a
live shape on this AMM. This spec was the document that was wrong.

Three writers raise `liquidityIndex`, from five call sites:

| site | trigger | caller | attacker-triggerable in-tx |
|---|---|---|---|
| `PoolLiquidity.sol:126` `accrueLpFee` | every swap, flash and cross-withdraw | any swapper or flash borrower | **yes** |
| `PoolLiquidity.sol:153` `donate` | permissionless (`Pool.sol:106`) | anyone | yes, but self-funded |
| `PoolAux.sol:338` `hookCreditYield` | `YieldHook.sol:303` `_harvest` | keeper or owner only | no |

Two lower it (`PoolDecay.sol:31-32`, `PoolAux.sol:374-375`), neither profitably.

The JIT shape is `capture = F * D / (L + D)`, `F` = fees accrued while the JIT LP is present,
`L` = leg liabilities, `D` = JIT deposit. Deposit and **same-asset** withdraw are still exactly
zero-fee in an over-covered leg (no entry fee, no exit fee, `applyHaircut` is the identity when
`r >= l`: `PoolLiquidity.sol:42`), and there the cooldown is the only friction on the round trip.
Same-asset is the odd one out of three exit paths: cross-withdraw (`PoolLiquidity.sol:297`) and
`swapLiability` (`:344-358`) both charge the full path spread. What stops the extraction is not the
clock. It is the following three, in descending order of strength.

**1. The exit haircut, 1155:1 on volatile legs and 22500:1 on stables.** A swap debits the **output**
leg's reserves (`PoolIO.sol:137`) and books the LP fee as liability on that same leg (`:140`), so the
leg the attacker farms is exactly the leg whose coverage the swap destroys. The attacker must exit
through the deficit they helped create:

```
capture = f_lp * V * D / (L + D)
loss    = k * D * V / (L + D)        k = 1 - suppressor/20000  (PoolLiquidity.sol:44-47, Constants.sol:64)
loss / capture = k / f_lp            independent of D, L and V
```

`f_lp = (1 - protoShare/100) * spread`, `protoShare = 20` (`script/SepoliaPoolDeploy.s.sol:392`).
At `k = 1`: volatile legs floor at ~1082 PBPS (`deployments/sepolia-risk-params.json` `minFeePbps`,
WETH through EURC), so `f_lp = 866 PBPS` and the attacker loses **1155** per 1 captured; the
USDC/USDT stable path floors at ~55 PBPS, so **22500:1**. The deployed `haircutSuppressor` is 10000
on every volatile and fx leg and on USDC, halving `k` and so halving those ratios to 577:1 and
11250:1. Three orders of magnitude underwater either way.

This is the actual guard. It is a pricing invariant, unbounded in time, and no cooldown value
changes it.

**2. Capture is hard-capped at `F`.** `Pricing.sol:357-370` builds the spread from sigma, vega,
staleness and confidence: it is **depth-independent**. A JIT deposit cannot enlarge the fee it farms,
so `capture = F * D / (L + D) < F` for any `D`. There is no v3-style concentration multiplier here.
Matching `L` buys half of `F` at the cost of carrying the whole leg's risk.

**3. The clock prices the round trip at $0.04.** Carry on $1M held 15s at 5% funding is $0.024; BSC
gas for the deposit/withdraw pair is about $0.02. To price a $185k volatile swap on carry alone
(capture at `D = L = $2M` is $80) the cooldown would have to be **seven hours**. 15s is not a
carry-based defence and must not be sold as one. It is worth keeping for the degenerate case only:
it forecloses the same-transaction round trip outright, and one block of ordering risk on chains
where 15s spans blocks.

**A fourth mechanism already implements the obvious fix.** `PoolLiquidity.sol:72` mints
`lpAmt = amt * WAD / mintIndex(asset)`, so a depositor buys in at the live index and captures only
index growth **after** entry. Index-checkpointing at deposit is not an alternative to build: it is
what the share ledger has always done. The JIT LP earns only the fees accrued during its own
presence, which is the whole reason capture is bounded by `F` rather than by the leg's history.

**Flash loans do not make this capital-free.** `PoolIO.sol:37 requireNoFlash` reads a BTR-private
transient slot, so an Aave or Balancer loan does bypass it. But the profitable shape needs the victim
transaction to land **between** the attacker's deposit and withdraw, which is three transactions in
one block (buildable on BSC via 48Club Puissant or bloXroute). A flash loan cannot span two
transactions. The attacker needs real inventory held for one block: whales and market makers, not any
anon with a router.

**The step vectors that remain.** `donate` and `hookCreditYield` still move the index in a lump, and
neither pays the haircut toll of finding 1, because neither is a swap: they credit reserves and
liabilities together and leave coverage flat. Sizing, with `YieldHook.sol:22` targeting 65% invested:

- Steady state, daily harvest, 5% venue APY, L = $10M: `Y = $890`, capture with matched capital
  `$445`. Dust.
- **Lapsed-harvest tail**: 73 days of no harvest at 5% APY on a $6.5M invested book accrues
  `Y = $65,000`, capture `$32,500`. L = $50M gives `Y = $325,000`, capture **$162,500**.
- `donate` is uncapped. A large protocol-revenue donation is the fattest target in the system.

Those figures are genuine accrued NAV over the lapse, **not cap artifacts**. `ee26ab5` made
`maxHarvestCreditBps` a per-DAY rate (`YieldHook.sol:299`,
`maxCredit = book * capBps * dt / (BPS * 1 days)`, default 100 bps at `:25`), so the cap no longer
binds by lapsing: over 73 days it permits 73% of book, against an actual credit of 1%. It binds only
on a NAV move faster than 1%/day.

That correctness came with a tail cost, and it should be stated plainly: because allowance accrues
linearly in `dt` with no ceiling, **a longer lapse permits a larger single credit**. The old flat cap
bounded any one step at ~1% of book regardless of how long the keeper had been down. Today a
year-long outage permits a single step of 365% of book. The bound on the sandwich is now the real NAV
gain, not a constant.

Target chain is **BSC** (`Constants.sol:78-80` "verify BSC live address at deploy", VenusHook, the
BNB-chain stableswap tape study in `research/stable-core/`). Post-Maxwell block time is 0.75s, so 15s
is **20 blocks**, not an atomicity guard. Sepolia at 12s is the only place 15s is roughly same-block.

**Verdict: keep `DEFAULT_FLOW_COOLDOWN = 15` and add no new instrument.** Every premise of the
earlier version of this conclusion changed; the conclusion does not. On the new grounds: the guard
against fee JIT is `applyHaircut`, which is a price and not a timer, so raising the cooldown buys
nothing against the dominant vector. Capture is capped at `F` and sublinear in `D`, so there is no
threshold the clock could sit above. Pricing the residual on carry needs seven hours, which is not a
shippable withdraw latency at any pool size. Entry/exit fees and TWA-share weighting tax every honest
LP to price a $0.04 attack; index-checkpointing is already built (`PoolLiquidity.sol:72`);
minimum-duration accrual is the seven-hour number wearing a different hat. **Doing nothing is
correct.** 15s survives because it kills the same-transaction shape for $0.024, not because it
defends fee JIT.

### 4.2 The options, ranked

**E > D >> A > B > C.**

- **A, holder-keyed with bypass: reject.** `deposit -> transfer to fresh address -> withdraw` is one
  transaction and reduces the cooldown to zero for everyone at the cost of ~50k gas. The lead's
  objection is upheld. (Honest caveat: with the cooldown at zero the same-*transaction* extraction
  is still nil, but no longer because nothing self-triggerable raises the index: since `879577a` it
  does. A self-swap pays `feeOut = protoFee + lpFee` (`Pricing.sol:335`) plus the coverage toll
  `_covToll` (`Pricing.sol:333`) and recaptures at most `lpFee * D / (L + D) < lpFee`. There is no
  break-even `D/L`, and flash-funding `D` changes nothing because the shortfall scales with `D`.
  What A unlocks is the same-block three-transaction sandwich around a third party's swap or a
  keeper credit, which is the whole ballgame in the lapsed-harvest tail.)
- **B, recipient inherits `max(ts, now)`: reject.** Turns any 1-wei transfer into a targeted freeze
  of any address. With the setter's current unbounded `uint16`, $0.01 buys an 18.2h freeze of an
  arbitrary address. It adds an attack instead of removing one.
- **C, share-weighted-average acquisition timestamp: reject.** Broken by trivially small
  pre-positioned capital. A holder with aged balance `Bw` absorbing `D` fresh shares clears the
  average when `a >= cooldown * (Bw + D) / Bw`; at one day of age and a 15s cooldown the attacker
  needs an aged parcel of only `D / 5760`, that is 0.017% of the JIT size, and the fresh shares then
  transfer out freely in the same transaction.
- **D, gate transfers during the sender's cooldown (the lead's proposal): sound invariant,
  unacceptable availability.** It survives every attack thrown at it, including the flash-loanable
  aged-LP laundering: harming LPs requires increasing the share count before the credit and
  decreasing it after, which requires a mint, and D stamps every mint. But it loses on three counts.
  (i) Any ERC-4626 wrapper accepts permissionless deposits by definition, so routing one minimum
  deposit through the wrapper per cooldown window freezes the wrapper's **entire** balance for every
  user: ~5,760 tx/day on BSC at ~$0.013 is about **$75/day to permanently brick every pooled LP
  wrapper**. That is a shipped denial of service, not an accepted hole. (ii) It turns the
  untimelocked `Admin.sol:228 setFlowCooldown` into an instant 18.2h global freeze of a transferable
  token. (iii) It inherits the existing all-or-nothing defect where a fresh $1 deposit freezes an
  aged $10M position, which buys nothing because a sophisticated attacker just splits addresses.

### 4.3 Decision: option E, frozen-amount lock

Freeze the minted **amount**, not the account. State lives in the LP token, not the pool.

```solidity
// per holder, one slot: uint32 stamp | uint224 frozen
mint(to, n):
  frozen = (block.timestamp >= stamp + cd) ? n : frozen + n;
  stamp  = block.timestamp;

transfer or burn from `s` of `a`:
  require(block.timestamp >= stamp + cd || balanceOf(s) - a >= frozen);
```

Why it is correct: shares are fungible, so bounding total outflow by `balance - frozen` is exactly
equivalent to "no share leaves within `cooldown` of its mint". Every mint raises the floor by
exactly the minted quantity. All of option D's attack analysis carries over verbatim, because E has
D's invariant.

That invariant still **holds exactly** under the continuous coupon of section 4.1: "no share leaves
within `cooldown` of its mint" is a statement about the share ledger and is indifferent to what moves
the index. `879577a` did not break it. It made it a less relevant invariant, because the dominant
guard against fee JIT is `applyHaircut` rather than any lock. Stated here so this is not reopened.

What it fixes that D does not:

- **Wrapper grief is dead.** A dust deposit routed through a wrapper locks the dust, not the
  wrapper. Proven by `test_lock_dust_deposit_cannot_freeze_a_wrapper`, which passes.
- **The all-or-nothing defect is fixed.** A fresh mint no longer freezes an aged position in the
  same leg. Proven by `test_lock_allows_aged_balance_while_fresh_mint_locked`. This is a **trade, not
  pure upside**: today `PoolLiquidity.sol:80` overwrites the stamp, so a fresh top-up freezes the
  whole aged position, which also means an LP cannot run on an observed depeg. E deliberately removes
  that, which improves a pre-positioned attacker's bank-run position. Recorded because it is real,
  not because it argues against E: the incumbent behaviour buys nothing against a sophisticated
  attacker, who splits addresses, and costs every honest LP their exit.
- **Burn is gated by the same check**, so `withdrawTo` and `swapLiability` are covered without the
  pool reading anything cross-contract. This is why `lastDepositTime` leaves pool storage.
- Same gas as D: the transfer path is one SLOAD and a compare on the same slot D would read; the
  mint path writes one slot D already writes.

### 4.4 Mandatory accompanying changes

1. **Cap `flowCooldownSeconds <= 300`** at `libraries/PoolAdminWrite.sol:95`, reverting
   `Err.InvalidInput`. `Admin.sol:228` is `_onlyAdmin()` with no timelock, so this ceiling is exactly
   the worst-case unavailability one compromised key can impose: five minutes, not 18.2 hours. 300s
   is 400 blocks on BSC and is already documented as the practical ceiling in
   `docs/dex/3. Security/3.4. Flow Guards.md:258`. Zero stays permitted as an explicit disable.
2. **Do not timelock `setFlowCooldown` at all.** Section 4.1 prices the whole round trip it guards at
   $0.03 to $0.04, so the setter is not a value lever and does not earn governance latency. If a
   timelock is ever added it must sit on the **decrease**, not the increase: a decrease toward zero is
   the value direction, while an increase is capped at 300s by rider 1 and is pure availability that a
   guardian needs to be able to impose immediately.
3. **Do not build `depositFor(to)`. If it is ever built, it must require `to == msg.sender`.**
   The earlier version of this rider said only "stamp `to`, never `msg.sender`", which is necessary
   but not sufficient and re-opens option B's attack. E's mint rule refreshes the stamp
   (`frozen += n; stamp = now`), so a third party who can mint to an arbitrary address can dust-mint
   to a victim once per window and hold the victim's **entire recently minted balance** frozen
   indefinitely for the cost of the dust. Stamping `msg.sender` collapses E's invariant; stamping an
   attacker-chosen `to` re-creates the grief vector E exists to remove. Only same-address minting is
   safe under a single-parcel lock. A per-parcel (amount, expiry) lock would also close it, at the
   cost of unbounded storage per holder, which is not worth it for a deposit-on-behalf convenience.
   Write this at the mint site as a comment; it is a constraint the code cannot show.
4. **The lock check goes in `_beforeTokenTransfer`, and must early-return when `from == address(0)`.**
   Solady calls that hook on `_mint` with `from == 0` (`ERC20.sol:497`), so without the carve-out
   `balanceOf(0) - amount` underflows and every mint reverts. It must **not** skip when
   `to == address(0)`: burn is the redeem path and is exactly what the lock must gate. Solady passes
   the real `from` on `transferFrom` (`ERC20.sol:258`), not `msg.sender`, so there is no
   approved-spender or Permit2 bypass.
5. `PoolLiquidity.sol:368-369`'s comment claims the swapLiability position "INHERITS" the cooldown
   and "never resets it earlier", but `:371` writes `now` whenever `now > prev`, which is plain
   `max(prev, now) = now`. Harmless direction, but the comment is false. It disappears with E.
6. **Separate ticket:** `Pool.sol:106 donate` is permissionless and `raiseIndex` is uncapped, unlike
   `hookCreditYield` which `YieldHook.sol:299` bounds to 100 bps of book **per day** and which,
   post-`ee26ab5`, permits a step proportional to the lapse. A large revenue donation is sandwichable
   by anyone holding inventory across one block, and no cooldown protects the donor's intent. Out of
   scope here, but it is the fattest target in the system.

## 5. Decimals, rounding, and the supply invariant

### 5.1 Decimals: fix the index base, do not ship `decimals = 24`

There is no decimal normalisation anywhere: `PoolIO.sol:50` `pull` returns a raw balance delta, and
`reserves`/`liabilities` are raw token units. With `LIQUIDITY_INDEX_INIT = 1e12`
(`Constants.sol:21`) and `lpAmt = amt * 1e18 / index` (`PoolLiquidity.sol:64`), one share is 1e-6
of a raw token unit, so the honest LP decimals are **underlying + 6**: 12 for USDC, 24 for WETH.

`decimals() = 24` is correct and unshippable. It underflows every integrator that computes
`10 ** (18 - decimals)` and breaks most lending oracles. Hardcoding 18 instead misprices every UI
and every wrapper by 1e6.

**Decision: repack `Asset` slot 1 to widen `liquidityIndex` to 96 bits and set
`LIQUIDITY_INDEX_INIT = 1e18`** (section 3.3). Then `lpAmt = amt` at init, `decimals() =
underlying.decimals()`, and one LP token is one underlying token at genesis. Headroom improves
rather than degrades: index max `7.9e28 / 1e18 = 7.9e10x` growth against `1.8e7x` today.
`minLiquidity` at 96 bits still holds 7.9e10 WETH.

This is only affordable because redeploy is authorised. It is the difference between a receipt an
integrator can price and one they cannot.

Residual honesty requirement: `PoolAux.sol:356` can set the index to 1 on a total write-down, which
changes shares-per-underlying by up to 1e18x permanently. No fixed `decimals()` survives that
event. Document it on the token.

### 5.2 Rounding

**A deposit followed by an immediate withdraw can never return more than was deposited.** Proof:
`lp = floor(amt * W / i)` implies `lp <= amt * W / i` implies `lp * i / W <= amt`, so
`wv = floor(lp * i / W) <= amt`. Floor composed with floor, conservative in both directions. The
haircut at `:43` is a ceilDiv that subtracts more, which only tightens it.

- Worst-case dust per round trip: `ceil((i - 1) / 1e18)` wei of underlying. At the new index base
  that is **at most 1 wei**.
- Who eats it: the withdrawer. `reserves` and `liabilities` both fall by the same amount, but the
  burned shares' exact value exceeded the recorded `wv`, so the residual stays in `reserves` with no
  shares behind it and accrues to remaining LPs as coverage. Correct direction.
- `swapLiability` loses dust twice, both times to the **out-leg's** existing LPs: `liabIn`'s floor
  leaves under 1 wei of in-leg liability unbacked, and `lpAmountOut`'s floor mints shares worth
  slightly less than `liabOut`. Bounded at 1 wei per operation, never adversarially amplifiable, and
  `minLpAmountOut` at `:312` lets the user bound it.
- ACC-03 (`:68`) survives unchanged: it guards mint only.
- **Gap to close:** `withdrawTo` rejects `lpAmount == 0` at `:131` but has no zero-**value** guard. A
  1-wei share balance withdraws 0 tokens and emits `Withdrawn(..., 0, 1)`. Harmless to the pool (the
  caller pays every SSTORE) but add `if (ctx.withdrawValue == 0) revert Err.ZeroValue()` for
  symmetry with ACC-03.

### 5.3 The new `totalSupply` invariant

Introducing an ERC-20 creates a per-leg share total that does not exist today. The invariant is
**`<=`, not `==`**:

```
totalSupply[leg] * effIndex(leg) / 1e18  <=  assets[leg].liabilities
```

Equality holds only transiently. Every operation preserves `<=` because every share-side conversion
floors: deposit `:64`, `raiseIndex` `:87`, `PoolDecay:26`, `withdrawTo` `:232-239`, `swapLiability`
`:310-315`. **Transfers do not touch it at all**, so transferability is invariant-neutral.

Three existing code paths break it. They are section 8's P0 items.

**Open item, for whoever lands the ERC-20 (#64).** `PoolLiquidity.sol:70` writes
`lpBalances[address(0)][token]` raw, and no `totalSupply` exists today. When the token lands, that
write must also bump `totalSupply`, or the invariant above understates outstanding shares by the
dead seed and every wrapper overstates NAV per share by the same. Section 11 additionally makes
`address(0)` the burn sink, so a plain `transfer(address(0), x)` would silently grow the dead pile
and lift the pin floor with LP money. Both are one line each at the mint and burn sites, and both
are invisible until a wrapper divides by `totalSupply`.

### 5.4 Denominating the dead seed in value, not token units

The dead-share seed prices an index pin at `seed x headroom`, where
`headroom = (2**96 - 1) / 1e18 = 7.92e10`. That product is a **value**, but the default seed
(`10**decimals / 1000`, i.e. 0.001 token) is denominated in token units, so it is only right where
one token is worth about one dollar. At either tail it is wrong in a different direction: 0.001 WBTC
burns ~$64 of the first depositor's deposit, and 0.001 KRW1 prices permanent destruction of 100% of
a leg's fee stream at $54k. $54k is not an acceptable floor, and the only "recovery" from a pinned
leg (`hookWriteDown` / decay) destroys LP principal to buy the headroom back.

`Asset.deadSeedPow10` (8 bits, in slot 1's spare bits, no new slot) overrides the seed per leg as a
power of ten of the token's own unit. `0` means "use the default", which is what every legacy word
reads. It is bounded at `decimals + 3` so it can never become a listing toll, and it only applies
while the leg is unseeded.

Marks from `deployments/11155111.seed-marks.json` (2026-07-28), legs from
`deployments/11155111.pools.json`. Sepolia's `TestnetERC20` mints 18 decimals for **every** listing
(`script/SepoliaPoolDeploy.s.sol:642`), so the whole live fleet is 18-decimal:

| leg | mark $ | default burn $ | default pin $ | `pow10` | seed (tok) | burn $ | pin $ |
|---|---|---|---|---|---|---|---|
| USDC | 1.0000 | 0.0010 | 7.92e7 | 15 | 0.001 | 0.0010 | 7.92e7 |
| DAI | 0.9998 | 0.0010 | 7.92e7 | 15 | 0.001 | 0.0010 | 7.92e7 |
| syrupUSDC | 1.1756 | 0.0012 | 9.31e7 | 15 | 0.001 | 0.0012 | 9.31e7 |
| EURC | 1.1388 | 0.0011 | 9.02e7 | 15 | 0.001 | 0.0011 | 9.02e7 |
| QCAD | 0.7094 | 0.0007 | 5.62e7 | 15 | 0.001 | 0.0007 | 5.62e7 |
| AUDF | 0.6976 | 0.0007 | 5.53e7 | 15 | 0.001 | 0.0007 | 5.53e7 |
| BRLA | 0.1949 | 0.0002 | 1.54e7 | 16 | 0.01 | 0.0019 | 1.54e8 |
| JPYC | 0.006108 | 0.0000061 | **4.84e5** | 17 | 0.1 | 0.0006 | 4.84e7 |
| KRW1 | 0.000688 | 0.00000069 | **5.45e4** | 18 | 1 | 0.0007 | 5.45e7 |
| WETH | 1911.42 | **1.91** | 1.51e11 | 12 | 1e-6 | 0.0019 | 1.51e8 |
| BNB | 569.17 | **0.57** | 4.51e10 | 12 | 1e-6 | 0.0006 | 4.51e7 |
| XAUT | 4015.62 | **4.02** | 3.18e11 | 11 | 1e-7 | 0.0004 | 3.18e7 |
| PAXG | 4018.75 | **4.02** | 3.18e11 | 11 | 1e-7 | 0.0004 | 3.18e7 |
| WBTC | 63689.28 | **63.69** | 5.05e12 | 10 | 1e-8 | 0.0006 | 5.05e7 |
| cbBTC | 63689.28 | **63.69** | 5.05e12 | 10 | 1e-8 | 0.0006 | 5.05e7 |

At mainnet-canonical decimals the same two tails move but do not change sign: USDC at 6 decimals
takes `pow10 = 3` (unchanged economics), WBTC and cbBTC at 8 decimals take `pow10 = 1` (10 wei, a
$0.0064 burn, a $5.05e8 pin). `pow10 = 0` cannot be used there because 0 is the default sentinel;
1 wei is the effective floor either way and the difference is one order of magnitude of pin cost.

The rule for a new listing: `pow10 = round(log10(0.001 / mark) + decimals)`, clamped to
`[1, decimals + 3]`. Set it before the leg is seeded, per the section 3.4 runbook.

## 6. Migration: none

- `deployments/` holds only `11155111` (Sepolia) and `31337` (anvil). `broadcast/` has three
  scripts, all chainId 11155111. No mainnet, no L2.
- Every Sepolia `lpBalances` entry was written by the deploy script itself:
  `script/SepoliaPoolDeploy.s.sol:554-556` mints `TestnetERC20` to the broadcaster and deposits.
  33 `deposit()` calls, one EOA, all against mocks. Faucet-user deposits, if any, are worthless.

**Redeploy the fleet with the ERC-20 ledger native from block zero.** Do not build a migration path,
a `migrated` flag, or a holder snapshot.

Recorded for completeness, since the owner asked for the double-credit proof: a bulk mint would need
the invariant `for all (u, leg): lpBalances[u][leg] + lpToken[leg].balanceOf(u)` constant with at
most one term nonzero, enforceable only if the mint reads and zeroes `lpBalances` in the same
transaction behind a flag that reverts `deposit`/`withdrawTo`/`swapLiability`. 33 legs times N
holders does not fit one transaction, so the pause would be mandatory. Lazy mint is worse: it needs
a token-to-pool callback on every transfer, which reintroduces the reentrancy deadlock of section 2,
and `totalSupply` would understate outstanding shares for the whole window, breaking every wrapper.
Both are moot.

One finding that survives the redeploy, because it affects indexing either way:
`PoolLiquidity.sol:189` emits `Withdrawn(sender, ctx.toTk, ctx.amt, lpAmount)` on the cross-asset
path, where `lpAmount` is **fromTk** shares paired with the **toTk** address. Log-based balance
reconstruction is wrong today unless the indexer pairs it with the `LiabilitySwapped` at `:188`.
ERC-20 `Transfer` events fix this for free.

## 7. Gas, measured

Measured with `forge test --match-path test/gas/LpTokenGasProbe.t.sol -vv` (solc 0.8.35, via_ir,
`optimizer_runs = 10000`). The probe is a measurement prototype and is **not staged**; it compares
the exact storage operations of today's nested mapping against a real Solady clone with the E-lock.

Baselines from the existing suite (`forge test --gas-report`, `test/gas/GasProbe.t.sol` and
`test/unit/AimmInvariants.t.sol`):

| entrypoint | min | mean | max |
|---|---|---|---|
| `deposit` | 127,205 | 135,755 | 161,165 |
| `withdrawTo` | 93,130 | 112,480 | 127,881 |
| `swapLiability` | n/a | n/a | 142,469 |

Ledger deltas:

Every measured operation below is the FIRST operation in its transaction, with all priming done in
`setUp` (a prior transaction), so accounts start cold and slots start clean. This matters: the
earlier version of this table primed in the same transaction and understated the tokenized path by
about 5x, because the clone and implementation accounts were already warm and the balance,
`totalSupply` and lock slots were already dirty (EIP-2200 charges 100 instead of 5,000 on a slot
whose original value was 0 at transaction start).

| operation | mapping today | tokenized | delta |
|---|---|---|---|
| credit, new user, live leg | 49,959 | 65,421 | **+15,462** |
| debit (withdraw or swapLiability in-leg) | 10,774 | 27,956 | **+17,182** |
| transfer, recipient already holds | n/a | 22,466 | new |
| credit, first user of a virgin leg | 49,946 | 82,500 | +32,554 (one-time per leg) |

Effective entrypoint impact: **deposit +11.4%, withdraw +15.3%**. `swapLiability` pays one debit plus
one credit against two different tokens, so about **+30k, or +21%**.

Where the debit delta goes, derived and then confirmed by measurement: `lpTokens` registry cold
SLOAD 2,100, CALL to the cold clone 2,600, the clone's DELEGATECALL to the cold implementation
2,600, `totalSupply` cold SLOAD plus SSTORE 5,000, the E-lock cold SLOAD and compare 2,327, the
ERC-20 `Transfer` LOG3 1,756, dispatch and immutable-arg read about 840.

**About 7.9k of that is intrinsic to any external-token architecture** (two cold accounts, the
registry read, the log) rather than to option E. The E-lock itself is 2,327, one cold SLOAD.

Deployment, 33 legs across 3 pools:

| pattern | per token | fleet |
|---|---|---|
| full contract | 670,221 | ~22.1M |
| **1167 clone with args** | **58,041** | **~1.92M** |

The earlier claim that 22.1M "exceeds a block" is wrong on BSC, whose limit is far higher. The
choice still stands on cost: ~1.92M against ~22.1M is not close.

**Open item carried into stage 2.** The measurement prototype hardcodes the cooldown as a constant.
`flowCooldownSeconds` actually lives in pool storage (`IPool.sol:142`) with no external getter, so
the token must obtain it. A cross-contract read on every transfer costs about 12k and re-enters the
reentrancy problem of section 2, so the token will hold its own copy, written at clone time and
updated by a pool-only setter that `Admin.setFlowCooldown` fans out across the leg tokens (a rare
admin action, about 33 SSTOREs). That adds roughly one cold SLOAD (~2,100) to the transfer and debit
rows above. Budget +19.3k on debit, not +17.2k.

Deployment, 33 legs across 3 pools:

**Disagreement resolved, against the lead.** The migration reviewer estimated the withdraw delta at
about +8k. The lead's first measurement said +3,389 and dismissed the estimate. Re-measured cold,
the answer is **+17,182**: the reviewer was closer, and the lead's rebuttal ("cold accesses are paid
once per transaction, not once per operation") is simply false for withdraw, where there is one
debit per transaction and nothing to amortise. The +8k estimate was itself low because it counted
only the `totalSupply` SSTORE and one cold account, missing the second cold account, the registry
SLOAD, the lock SLOAD and the log. The burn-not-read call shape the reviewer recommended is correct
and is what the probe measures: `withdrawTo` must call `lpToken.burn(msg.sender, lpAmount)` and let
it revert internally on insufficiency, never read `balanceOf` and then burn.

## 8. Prerequisites: existing bugs

The first two break the `totalSupply` invariant of section 5.3, so they are prerequisites rather
than follow-ups. All four were found during this review and are independent of tokenization.

- **P0, `PoolLiquidity.sol:234-235`, the `liabRed` clamp fails open.** `withdrawTo` silently clamps
  `liabRed = min(withdrawValue, liabilities)` and still debits `reserves -= amt` where `amt` can
  exceed `liabilities`. Reserves leave with no matching liability reduction: the post state shows
  `liabilities = 0` and perfect coverage while other holders' reserves were extracted.
  `swapLiability.sol:285` reverts on the identical condition. **Make `withdrawTo` revert too.**
- **P0, `PoolAux.sol:353-356`, a total write-down does not burn shares.** `liabAfter == 0` sets
  `liquidityIndex = 1` and leaves `lpBalances` untouched, so stale holders keep a claim against the
  next depositor's money, redeemable through exactly the clamp above. Same class at
  `PoolDecay.sol:27` and `PoolAux.sol:360` (`scaled == 0 ? 1`), where the floor at 1 forces the
  index above the proportional value.
- **P1, `PoolAux.sol:307-326 hookCreditYield` omits `PoolDecay.applyDecay`.** `deposit:58` and
  `donate:100` both call it first. Yield credited onto a stale index and liabilities pair is then
  written down by the pending decay. It also never touches `a.lastUpdate`.
- **P2, `README.md:33-46` slot table is stale** (lists `bridge`, `profiles`, `lpBalances = 8`,
  `assetHooks = 15`). Truth is `sdk/src/pool/storage.ts:29-48` and `PoolStorageLayout.t.sol:152`.

## 9. Mint and burn access control

**One immutable check, nothing else:**

```solidity
if (msg.sender != _pool()) revert Err.NotAuth();   // _pool() from immutable args, no SLOAD, no CALL
```

Rejected alternatives: a `PoolFactory.isPool` lookup makes mint authority mutable by the factory
owner, which is exactly the widening this must prevent; an `AccessControl` role puts the AC owner in
the supply-inflation trust set and costs an external call.

Honest caveat: pools are ERC-1967 **beacon** proxies (`PoolFactory.sol:115`) and
`executeReferenceUpgrade` (`:326`) re-points the whole fleet, so the immutable argument pins the
*address*, not the bytecode that may mint. Real mint authority is "whatever the beacon points at",
gated by the factory's timelocked upgrade. That is still strictly the best available: it removes
both the factory owner and the AC owner from the trust set.

**No admin mint, no admin burn, no blacklist. Firm.** Burn is a 100% loss lever with no timelock
counterpart, and any lending market listing a receipt with an admin burn must price a total
admin-loss tail, which means LTV 0. It destroys the collateral thesis this task exists to build.
Rescue does not need it (a mistaken accrual is corrected by `donate()`, and losses already socialise
through the index). The guardian is 1-of-1 by default; handing one key mint or burn over LP
principal is indefensible.

## 10. EIP-2612 permit

**The brief's premise was wrong.** The vendored Solady is 0.1.26 and its `ERC20.sol` contains zero
`tstore`/`tload`: `allowance` (`:170`), `approve` (`:184`), `transferFrom` (`:267`) and `permit`
(`:461`) are **already persistent**. Nothing needs overriding for persistent approvals.

What does need attention:

- **`_givePermit2InfiniteAllowance()` (`ERC20.sol:667`) defaults to `true`.** Every leg receipt would
  ship an unrevocable infinite allowance to Permit2, and `approve(PERMIT2, x != max)` would revert.
  **Override to `false`** unless Permit2 routing is a deliberate product decision.
- **Leave `_constantNameHash()` (`:355`) returning 0.** `DOMAIN_SEPARATOR()` (`:472`) and `permit`
  (`:408`) recompute the name hash and read `chainid()` **per call**, so a `name()` sourced from
  immutable args is handled correctly and cross-chain replay is already prevented. Solady invites
  you to override it with a compile-time constant for gas; with 33 clones sharing one
  implementation that constant would be shared, and `DOMAIN_SEPARATOR()` would disagree with
  `name()`, so EIP-712 wallets recomputing from `name()` would produce signatures the contract
  rejects. Replay stays blocked either way because `verifyingContract` differs per clone, but the
  wallet breakage is real.
- `nonces` (`:374`) is a per-owner SLOAD. Fine.

## 11. Redeemability versus transferability

A transferable receipt that cannot always be redeemed trades below NAV. Every blocking condition:

| # | condition | site | controller | max duration | on-chain readable |
|---|---|---|---|---|---|
| 1 | coverage haircut (cuts value, does not block) | `PoolLiquidity.sol:29` | market, plus `haircutSuppressor` (owner, instant) | while c < 1 | yes, `previewWithdraw` |
| 2 | `reserves < amt` | `PoolLiquidity.sol:199`, `:226` | market | until refill | yes, `getAsset` |
| 3 | `minLiquidity` floor | `PoolLiquidity.sol:173-181` | **owner, instant, no timelock** | **forever** | value yes, effect not in `previewWithdraw` |
| 4 | FROZEN / ASSET_PAUSED | `PoolIO.checkRiskFlags:87` | **guardian, 1-of-1 default**; unpause is owner-only | **unbounded, asymmetric** | yes, `getRiskFlags` |
| 5 | depeg / price band | `PoolIO.priceBandGuard:145` | owner sets bands, instant | while depegged | **no** |
| 6 | oracle stale / confidence / feed pause | `Oracle.sol:43-55` | keeper liveness | keeper outage | **no** |
| 7 | hook `preOutflow` / `invested` | `PoolHooks.sol:68-97` | hook target, an illiquid venue | **arbitrary** | yes, `getBuffer`, not in `previewWithdraw` |
| 8 | `requireNoFlash` | `PoolIO.sol:36` | protocol | intra-tx | no |
| 9 | flow cooldown | section 4 | owner, capped at 300s per section 4.4 | 300s | **new**, see below |

Note 5 applies to the cross-asset path only; a same-asset withdraw is not band-guarded.

**`previewWithdraw` (`PoolView.sol:14`) is a trap.** It models condition 1 only and ignores 2, 3, 4,
6, 7 and 9, so it looks like ERC-4626 `previewRedeem` and systematically **overstates** what is
redeemable.

Minimal read surface to add. Reuse first: keep `previewWithdraw` as is and document it as "value,
ignoring liquidity and halt constraints", then add exactly two functions:

```solidity
function maxRedeem(address owner, address token) external view returns (uint256 lpShares);
function withdrawUnlockTime(address owner, address token) external view returns (uint32 ts);
```

`maxRedeem` collapses conditions 1, 2, 3, 4, 7 and 9 into one number, where 0 means "cannot redeem
now". `withdrawUnlockTime` exposes the cooldown, which has **no read path at all** today, so an
integrator cannot schedule a liquidation. No status bitmap: `getRiskFlags` and `getBuffer` already
carry that state and a bitmap creates a second place to keep in sync. Conditions 5 and 6 stay
unobservable on chain and are documented as such rather than mirrored.

### DeFi integration matrix

| integrator | verdict | requirement |
|---|---|---|
| lending market, collateral | **not safe as currently specified** | see below |
| ERC-4626 wrapper | workable | must price off `previewWithdraw`, never `shares * index`; must handle non-monotone value |
| AMM secondary market | workable | expect a persistent discount to NAV; the E-lock can revert a transfer for up to 300s |
| yield aggregator | workable | must read `maxRedeem` before sizing an exit |

### The P0 fix made the collateral story WORSE, not better

This must not be buried. Commit `796ac93` was the right fix for pool solvency (stale shares can no
longer eat the next depositor's money) and is **strictly worse for the collateral thesis**. Both are
true at once.

Before: a write-down floored the index at 1, so a receipt decayed continuously and always redeemed
for something, and a `donate()` could recapitalise the leg. After: a total write-down sets the index
to exactly **0**, and that state is **absorbing and unrecoverable**:

- `raiseIndex` multiplies by 0, so `donate` and `hookCreditYield` can never lift a wiped leg. The
  P0 commit made these revert rather than silently strand the funds, but reverting is not recovery.
- `PoolAdminWrite.sol:68` rejects re-listing an existing asset, so there is no governance path back.
- A wiped leg's receipts cannot even be burned: `withdrawValue` is 0 and the new zero-value guard
  reverts. A liquidator who seized the collateral holds an unburnable zombie.

So the risk profile changed from "decays, always worth something" to "**jumps to exactly 0 in one
hook call, with no event, permanently**". That is precisely the profile a lending market cannot
price or liquidate. Making index 0 recoverable, or forbidding it entirely, is a **prerequisite** for
any LTV above 0, and it is added to the hardening list below.

**Honest answer on collateral: no, not yet.** Six independent reasons, any one sufficient: the
guardian pause is 1-of-1, instant, unbounded, and asymmetric (unpause is owner-only, verified at
`shared/evm/src/access/AccessControl.sol:72` and `:213`), and a halt correlates exactly with the
moment a liquidation is needed; `minLiquidity` is owner-settable instantly and untimelocked
(`Admin.sol:239` reaches `adminSetAssetParams` directly with no queue, despite living in
`AdminTimelock.sol`), so setting it to `reserves` is a complete soft-rug with no notice; the index
can be marked to exactly **0** by a hook target in one transaction with no event, permanently; no
index event means no TWAP and no manipulation-resistant oracle; the haircut is a bank-run amplifier
that destroys collateral value exactly when all liquidations fire; and the **beacon upgrade is a
governance-mint tail**, because `PoolFactory.sol:326 executeReferenceUpgrade` re-points the whole
fleet, so "the immutable pool address may mint" pins an address whose bytecode is mutable by
timelocked governance. "No admin mint, firm" is true only for the fast path.

**One reason from the earlier draft is struck as overstated.** `requireNoFlash` does **not** break
flash liquidation generally: `PoolIO.sol:25` reads a BTR-private transient slot set only inside
BTR's own ERC-3156 callback, so an Aave, Balancer or Morpho funded liquidation never trips it. It
restricts one funding route. This spec asserted the correct version in section 4.1 and then
contradicted itself here; the section 4.1 version is right.

It becomes acceptable collateral only when **all** of: index 0 is made recoverable or forbidden
outright (see above); the pause auto-expires on chain and unpause is symmetric; `minLiquidity`,
`haircutSuppressor` and `flowCooldownSeconds` are timelocked with LP exit notice; and index moves
emit events. Until then the correct LTV is 0.

If a market lists it anyway: **a leg with a hook installed is uncollateralisable outright**, not a
0% tier alongside a 50% one, because `hookWriteDown` is the only path to index 0 and a hook being
installed *is* the entire jump-to-zero risk. For a hookless leg with `c >= 1`, cap LTV at 50%, price
off `maxRedeem`-gated `previewWithdraw` with a downward-fast / upward-slow filter, and liquidate by
seizing and auctioning the receipt rather than redeeming it. Note that auctioning only works while
`index > 0`: on a wiped leg the receipt is unburnable and worth 0, there is no bid, and the debt is
unrecoverable.

State this in the token's documentation. It is the price of shipping transferability before the
governance hardening.

## 12. Events and indexing

**The blocking gap is not tokenization, it is that no event is emitted anywhere when
`liquidityIndex` moves.** Writers `PoolLiquidity.sol:89`, `PoolDecay.sol:27`, `PoolAux.sol:356-360`
all emit nothing; `Donated` carries the amount but never the resulting index. So an indexer cannot
compute historical NAV per share, cannot detect a write-down, cannot compute APR, and no lending
market can build a TWAP. ERC-20 `Transfer` gives positions but not value.

Current indexer state (`back/services/collector/src/protocol-ingest/`): only `Swapped`, `Deposited`,
`Withdrawn` and seven oracle events are actually fetched. `Donated`, `LiabilitySwapped`,
`BatchSwapped` and every admin freeze event are decoded in `decode.ts:20-43` but **absent from the
topic filter**, so `loop.ts:434 SNAPSHOT_TRIGGER_TOPICS` is a dead branch. `rollup.ts:188-218`
`HolderLedger` never reads a balance on chain: it is a running USD cost-basis sum with a $1 dust cut
and a 30-day TTL, and `swapLiability` is invisible to it.

Minimal event set to add:

1. **`IndexUpdated(address indexed token, uint96 index, uint128 reserves, uint128 liabilities,
   uint8 reason)`** at all three index writers, `reason` in `{DONATE, YIELD, DECAY, WRITEDOWN}`.
   **Mandatory.** Each site already branches on "index actually changed", so emit inside that
   branch; the cost is log data only. This alone unblocks historical NAV, APR and the haircut curve.
2. **`InvestedUpdated(address indexed token, uint128 invested)`** at `PoolHooks.sol:60`, `:91` and
   `PoolAux.sol:262`, `:290`. Needed to reconstruct historical redeemable depth (condition 7), which
   changes silently today.
3. **ERC-20 `Transfer`** on the leg tokens, including mint from zero and burn to zero. Reconstructs
   exact share positions at any block for any holder.

Becoming redundant: `Deposited.lpAmount` and `Withdrawn.lpAmount` duplicate the mint and burn
`Transfer` (keep the events, they carry the underlying amount `Transfer` does not, but the indexer
must stop deriving positions from them), and `LiabilitySwapped.lpAmountIn/Out` is duplicated by a
burn and a mint across two leg tokens. **Delete `rollup.ts:188-218 HolderLedger`** and source
balances from `Transfer`, which also fixes the 30-day truncation and the `swapLiability` blind spot.

Indexer files to change: `decode.ts` (the single topic choke point for both `hypersync.ts` and
`rpc-logs.ts`), `ddl.ts`, `qdb.ts`, `loop.ts:400-440`, `aggregations.ts`, `rollup.ts`.

Also note: the off-chain `Distributor` TWAB reconstructs balances from `Deposited`/`Withdrawn`/
`LiabilitySwapped` today. Once shares are transferable it **must** consume `Transfer` or campaign
rewards misattribute. The contract is unaffected; the indexer is not.

## 13. Naming

Collision is real: all three pools list USDC, so `btrLP-USDC` is ambiguous. Use a pool tag.

| pool | symbol | name |
|---|---|---|
| stable | `bLP-s-USDC` | `BTR Stable LP: USDC` |
| volatile | `bLP-v-WETH` | `BTR Volatile LP: WETH` |
| fx | `bLP-f-EURC` | `BTR FX LP: EURC` |

Both fit `bytes32` immutable args. The SDK should derive display strings from the leg's own symbol
plus the pool tag and never depend on the on-chain string.

## 14. Off-chain surface

`Pool.getLPBalance` (`Pool.sol:215`) is **kept** as a proxying view over the leg token. That makes
the SDK, front and keepers zero-diff at the call sites and is worth the few hundred bytes.

Still must change:

- `sdk/src/pool/storage.ts:29-48` and `storage.test.ts:29`: slot 7 becomes reserved and slots 13, 14,
  15 renumber to 11, 12, 13 (section 3.1). This is the one unavoidable break.
- `sdk/src/pool/index.ts:137-155`, `sdk/src/abis/Pool.ts:341`, `sdk/src/eth/abi.ts:70`: only if the
  proxying view is dropped, which it is not.
- `front/src/hooks/usePoolData.ts:538-608 useUserLpPositions`: the shares-to-underlying conversion at
  `:600-602` stays; add the leg token addresses so wallets can display balances.
- `keepers/bots/src/lp-keeper.ts:121,255` and `lp.ts:36`: money path, unchanged by the proxying view,
  but must be re-tested against the redeployed fleet.

Docs asserting the opposite, all needing correction: `docs/guides/faq.md:33`,
`docs/guides/troubleshooting.md:54` (both state LP shares are not ERC-20 and will not appear in
wallets), `docs/dex/1. AIMM/1.3. Integration/1.3.1. Composability.md` (many lines),
`sdk/README.md:43`, `docs/reference/sdk.md:44`, `dex/evm/README.md:26`.

## 15. Stage 2 plan, on approval

1. Fix the P0 and P1 bugs of section 8, with regression tests. Separate commit, `fix(pool):`.
2. `Asset` repack and `LIQUIDITY_INDEX_INIT = 1e18`. Separate commit, `refac(pool):`.
3. `LPToken.sol` plus the E-lock, `feat(lp):`.
4. `PoolLiquidity` diffs and the `lpTokens` registry, `feat(lp):`.
5. `maxRedeem`, `IndexUpdated`, `InvestedUpdated`, `feat(pool):`.
6. Cooldown cap and timelock routing, `fix(risk):`.
7. SDK, front, indexer, docs.
8. Two independent reviewers on the implementation diff before any deploy.

## 16. Panel review: consensus NOT reached

Three experts reviewed on security, optimization and minimalism. **None signed all three axes.**
Recorded rather than averaged, per the owner's standing instruction.

| axis | security expert | optimization expert | minimalism expert |
|---|---|---|---|
| security | **OBJECT** (3 items) | OBJECT (2 narrow) | sign off, 1 flag |
| optimization | sign off (deferred) | **OBJECT** (gas table) | OBJECT (deferred) |
| minimalism | OBJECT (1 item) | OBJECT (2 narrow) | **OBJECT** (7 items) |

### Accepted and already actioned

- **Gas table wrong by ~5x.** Corrected in section 7. The lead's measurement was contaminated by
  same-transaction warming; the +8k reviewer was closer than the lead.
- **`raiseIndex` silently no-oped on a wiped leg** (index 0 multiplies to 0), so `donate` and
  `hookCreditYield` would book reserves and liabilities, mint nothing and strand the funds. Found in
  code the lead had already committed. Now fails closed via `mintIndex`.
- **`hookWriteDown` did not settle pending decay** while `hookCreditYield` now does. Fixed.
- **E is not a net simplification.** Claim withdrawn, section 0.1. E is carried on security merit.
- **`depositFor` rider was necessary but not sufficient** and re-opened option B's grief vector.
  Tightened to "do not build it; if built, require `to == msg.sender`", section 4.4.
- **P0 made the collateral story worse**, and the spec did not say so. Now section 11, up front.
- **`requireNoFlash` reason struck** as overstated and self-contradictory with section 4.1.
- **Beacon upgrade added as collateral reason 7** (governance-mint tail).
- **Solady hook carve-out** (`from == address(0)` on mint, no skip on burn) written into section 4.4.
- **`withdrawUnlockTime` deleted** from the read surface. Under E a single timestamp understates
  availability, since an aged balance is redeemable while a fresh mint is locked. Replaced by making
  the token's `locks` mapping public plus a `flowCooldownSeconds()` getter the pool lacks today.

### Surviving objections, unresolved, for the owner

1. **`maxRedeem` is a second source of truth** for six independently mutating gates, in a spec that
   rejects a status bitmap on exactly that reasoning. Raised by two of three experts. The lead's
   position is that integrators need one number and `previewWithdraw` cannot be made honest about
   guardian state without becoming a second bitmap anyway. **Not resolved. Owner call.**
2. **Terminal wiped legs have no recovery path at all.** Deliberate, but it means one hook call can
   permanently kill a leg. The security expert wants a governance recovery path before mainnet; the
   lead's view is that a total loss genuinely is terminal and recovery re-opens the stale-share leak.
   **Not resolved, and it gates any LTV above 0.**
3. **Disproportionate wipe on a low-liability leg**: if `liabilities` are residual dust after a full
   LP exit while `reserves` and `invested` are large, a routine venue loss drives `liabAfter == 0`
   and bricks the leg over a trivial write-down. Needs a guard. **Accepted as real, not yet fixed.**
4. **Delete `lpBalances` outright** rather than keeping `__reserved_lpBalances`, since the storage
   pin and the SDK map break anyway under a clean redeploy. Lead leans agree; costs a wider diff.
5. **`extcodecopy` over `argsOnClone` for `_pool()`** saves 293 gas (not the 105 claimed) at the cost
   of hand-rolled offset arithmetic on the mint-authority address, where a wrong offset is a total
   supply compromise. Security expert wants `argsOnClone` for `_pool()` specifically.
6. **`uint224 frozen` justification is wrong** (the index falls under decay, so shares per unit
   rise). It still fits, but the cast should be checked.
7. **`minLiquidity` narrowing to `uint96`** silently truncates the `uint128` admin setters and breaks
   an equality check in `AdminRiskSteward.sol:62`. Needs a bound check at the setter.
8. Minor deletions proposed and not yet taken: the `name` immutable arg, the `lpAmount` event fields,
   `Pool.getLPBalance`, and folding `InvestedUpdated` into a single `_setInvested` writer.
