# 68: recovery from the absorbing zero index

Status: design only, awaiting sign-off. Nothing implemented. Written for the panel and the
independent auditor.

Paths relative to `dex/evm`.

## The defect, stated without reference to tokenization

`PoolAux.hookWriteDown` cuts `liabilities` by the loss and rescales the index. When the loss meets or
exceeds `liabilities`, `liabAfter == 0` and the index becomes **0**. That state is absorbing:

- `PoolLiquidity.mintIndex` reverts, so `deposit` is dead on that leg.
- `raiseIndex` routes through `mintIndex`, so `donate` and `hookCreditYield` are dead too. There is
  no recapitalisation path.
- `PoolAdminWrite.initAsset:68` reverts `AlreadyConfigured` when `decimals != 0`, so the leg cannot
  be re-listed.
- No event fires. (Fixed by `f1b83c3`: `IndexUpdated` with `reason = WRITEDOWN` now logs it.)

**One hook call permanently removes a leg from a pool, and until `f1b83c3` it did so silently.** The
caller is the registered asset hook, which is inside the trust set, but it is a contract, not a
human, and it is the component most likely to be wrong: it is the thing custodying funds at an
external venue.

This is true today with no LP token anywhere. It is a live protocol defect, not a tokenization
concern.

### What my own commits changed

Before `796ac93` the index floored at 1 instead of 0. The leg was not bricked, but outstanding shares
kept a live claim against the next depositor's money, which is the accounting leak `796ac93` fixed.
`c3691a7` then made `donate`/`hookCreditYield` revert on a wiped leg rather than silently booking
reserves and stranding the funds.

Both changes are right on their own terms (fail closed beats silent loss) and both make the terminal
state **more reachable and more visible**. The defect predates them; the priority does not.

This document predates `ad90d5e`, which fixed the mirror-image absorbing state at the **top** of the
range: `raiseIndex` used to revert once the index passed `type(uint64).max`, bricking every later
accrual on the leg. It now clamps (`PoolLiquidity.sol:109`). Nothing below changes: the floor at 0 is
a separate state and is still absorbing.

### Why it gets worse under tokenization

A receipt on a wiped leg cannot be burned: `withdrawValue` is 0 and the zero-value guard reverts. A
lending market that seized the collateral holds an unburnable zombie with no bid. That is the
mechanism behind the section 11 verdict that a leg with a hook installed is uncollateralisable
outright.

## Threat model for any recovery power

The reason this needs a design rather than a patch: **recovery is resurrection, and resurrection is
mint authority in disguise.** If governance can lift a leg's index off 0, governance can decide what
outstanding shares are worth. Concretely, if a wipe leaves supply `S` outstanding and governance sets
the index to `i`, it has just created `S * i / WAD` of claim out of nothing, payable from whoever
deposits next.

So the powers to bound are:

1. **Value creation.** Setting a nonzero index against nonzero stale supply mints claim.
2. **Selective revival.** Reviving a leg where an insider still holds shares transfers the next
   depositor's money to the insider. This is exactly the leak `796ac93` closed, re-opened by hand.
3. **Griefing in reverse.** If recovery is cheap and fast, a hook that wipes a leg is no longer a
   terminal event, which weakens the incentive to configure hooks conservatively.
4. **Timing.** A recovery executed while a liquidation or withdrawal is in flight changes the value
   of a position mid-transaction.

The current state satisfies 1 through 3 perfectly by making recovery impossible. The cost is
availability: a leg is lost forever over what may be a small write-down.

## Option A: prevent the wipe rather than recover from it

Do not let a routine loss reach the terminal state at all.

The reachability problem is real and was raised in the panel as a live objection: `cutLiab` is
`min(cut, liabBefore)`, so if `liabilities` are residual dust after LPs have exited while `reserves`
and `invested` are still large, an ordinary venue loss drives `liabAfter == 0` and bricks the leg
over a trivial write-down. That is a **disproportionate wipe**, and it is the most likely way the
terminal state is ever reached in practice.

Guard: only treat a write-down as total when it genuinely is. Require the loss to consume the book,
not merely the residual liabilities, before allowing the index to reach 0. Anything short of that
clamps the index to a floor and leaves the leg alive but deeply impaired.

- Cheap, local to `hookWriteDown`, no new admin power, no new storage.
- Does not resurrect anything, so it inherits none of the threat model above.
- **Does not fix the genuine total loss.** A leg that really did lose everything is still terminal.

I consider this **necessary regardless of what else is chosen**, because it addresses the reachable
case rather than the theoretical one.

## Option B: terminal is correct, make it explicit and safe

Accept that a genuine 100% loss is terminal, and make the state honest rather than recoverable:

- Set an explicit `TERMINAL` risk flag at the moment of the wipe so the state is a first-class fact
  rather than an emergent consequence of `index == 0`.
- Allow **burn at zero value** so receipt holders can clear a worthless position and integrators can
  close it out. This directly removes the unburnable-zombie problem without creating any claim: it
  destroys shares, it never mints them.
- Leave `deposit`, `donate` and `hookCreditYield` reverting.
- Recovery is out of band: list a new leg for the same underlying under a new address.

Threat model: creates no value, permits no selective revival. The only new power is a state
transition that is already reachable.

Cost: the pool permanently carries a dead entry per wiped leg, and the SDK, front and factory
enumeration must all render it. Listing a replacement leg for the same underlying may collide with
`PoolIO.wrap` normalisation and the factory discovery index, which needs checking before this is
called cheap.

## Option C: bounded resurrection, supply-gated

Allow re-initialisation of a wiped leg **only when no stale claim can benefit**:

- Require `totalSupply == 0` on the leg. With tokenization that is a single read; without it, there
  is no share total at all today, which is precisely why this option is hard right now.
- Behind the existing `Admin` timelock as its own op type, not folded into `setAssetParams`.
- Resets the index to `LIQUIDITY_INDEX_INIT` and clears the terminal flag.

The `totalSupply == 0` precondition is what makes this safe: with no outstanding shares there is
nothing to mint claim to, so threats 1 and 2 vanish by construction rather than by policy.

The catch: reaching `totalSupply == 0` requires every holder to burn a worthless position, which
needs option B's zero-value burn to be possible at all, and which nobody is incentivised to do. In
practice this is a governance-coordinated cleanup, not a live recovery. It also cannot be built
before the share total exists.

## Option D: no absorbing state, floor the index above zero

Return to a floor, but at a value that cannot create claim: floor the index at 1 as before, and
separately fix the accounting leak that the floor caused, by burning supply rather than by zeroing
the index.

This is the theoretically clean answer: a total loss should reduce every holder's **shares** to
nothing, not reduce the price of shares to nothing. It is not implementable against a mapping
ledger, because you cannot iterate holders. It becomes implementable if and only if a share total
exists and the ledger supports a supply-wide rebase, which is a real design decision for the token
shape the panel is weighing.

**Flagging this for the panel explicitly**: if they choose a shape with a single share ledger
(ERC-6909, or a pool-level ERC-4626), option D becomes available and is strictly better than B or C.
If they choose per-leg ERC-20 clones, it is available per leg. If they choose not to tokenize, it is
not available at all and the choice is between A plus B, or leaving the defect.

## Recommendation

**Ship option A now, independent of the panel.** It fixes the reachable case, needs no new authority,
and is correct under every token shape.

**Defer the choice between B, C and D until the panel settles the shape**, because D's availability
is a direct function of that decision and D is the best answer if it is available.

Do not ship a general admin "set the index" power in any form. Every version of it is mint authority
with extra steps, and the one thing the collateral verdict cannot survive is a governance key that
can decide what a receipt is worth.

## Open questions for sign-off

1. Does a genuine total loss deserve recovery at all, or is a new leg the right answer? This is a
   product call, not a security one.
2. If a wiped leg stays in storage forever, what should `previewWithdraw`, the SDK and the front
   render for it? Silence is how it became invisible in the first place.
3. Should the wipe itself require more than a hook call: a guardian confirmation, or a delay before
   it becomes terminal? A hook is a contract, and contracts are the component most likely to be
   wrong.
