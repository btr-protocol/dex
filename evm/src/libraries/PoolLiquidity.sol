// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {ILPToken} from "../LPToken.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Pricing} from "./Pricing.sol";
import {Constants as C} from "./Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {PoolDecay} from "./PoolDecay.sol";
import {PoolIO} from "./PoolIO.sol";
import {PoolHooks} from "./PoolHooks.sol";

/// @title PoolLiquidity -deposit/donate/withdraw/swapLiability extracted from Pool.sol
/// @notice Wave-2 bytecode reduction. Pure refactor; behavior preserved.
///         External lib fns DELEGATECALL'd from Pool trampolines; reentrancy
///         + whenInitialized enforced at the trampoline.
library PoolLiquidity {
  // Events canonical @ IPool (Deposited / Withdrawn / LiabilitySwapped / Donated). Share movement
  // is logged by the leg receipt's own ERC-20 Transfer, which is the only complete record: the
  // cross-asset withdraw path burns fromTk shares while paying out toTk, so no single Withdrawn
  // log can carry both sides. The anti-JIT cooldown lives in that receipt too, as a frozen amount
  // per holder, so deposit no longer stamps the pool and withdraw no longer checks it.

  /// @dev Share-minting index. Reverts on a wiped leg (index 0 = total write-down): minting there
  ///      would divide by zero, and any share minted after a wipe would be diluted 1:0 against the
  ///      stale supply. A wiped leg is terminal; list a new one.
  function mintIndex(IPool.Asset storage asset) internal view returns (uint256 idx) {
    idx = asset.liquidityIndex;
    if (idx == 0) revert Err.InvalidState();
  }

  /// @dev #73: `raiseIndex` is a ratio off `liabilities`, so a leg whose liabilities can return to
  ///      dust is pinnable — donate/deposit/withdraw ratchets the index onto its ceiling for gas,
  ///      after which the clamp holds it flat while `accrueLpFee` keeps booking fees no share can
  ///      ever claim. Sink a permanent seed to address(0) on whatever FIRST credits the leg's
  ///      liabilities: address(0) is never msg.sender, both burn paths debit msg.sender only, and
  ///      the receipt refuses a user transfer to address(0), so the seed can never be redeemed nor
  ///      topped up with LP money. It is minted as REAL supply, or `totalSupply` would understate
  ///      outstanding shares by the seed and every wrapper would overstate NAV per share.
  ///      `liabilities` is then floored at deadShares·index/WAD, which tracks the index exactly, so
  ///      reaching the ceiling costs the whole terminal liability instead of dust.
  ///      Called from EVERY liability-credit site (deposit, swapLiability, donate, hookCreditYield),
  ///      not just the mints: donate credits liabilities while minting nothing, so a mint-only seed
  ///      left the share-free window wide open. The window is closed at the door, not gated
  ///      downstream: a `raiseIndex` gate would also have frozen every already-live leg on upgrade.
  ///      Callers SPLIT the seed out of what they were already crediting rather than adding to it,
  ///      so `S·index/WAD ≤ liabilities` holds by construction.
  /// @param value Leg-denominated value being credited; must be able to carry the seed.
  /// @param strict Reject a credit too small to carry the seed. The mint sites pass true (the dust
  ///        credit has nothing to mint anyway); `hookCreditYield` passes FALSE and skips, because it
  ///        runs inside the keeper's `rebalance()` and a revert there is the leg-wide denial of
  ///        service `accrueLpFee` already refuses to buy for gas.
  /// @return deadLp Shares minted to address(0); 0 if the leg was already seeded or the seed was
  ///         skipped. `seeded` disambiguates: false means NOTHING was seeded and the caller must not
  ///         book this credit to the index either.
  function seedDeadShares(
    IPool.PoolStorage storage $,
    IPool.Asset storage asset,
    address tkn,
    uint256 idx,
    uint256 value,
    bool strict
  ) internal returns (uint256 deadLp, bool seeded) {
    // The seed is unburnable, so a nonzero supply is an exact "already seeded" test.
    ILPToken lp = ILPToken($.lpTokens[tkn]);
    if (lp.totalSupply() != 0) return (0, true);
    // NOT asset.minLiquidity: that is the keeper reserve floor (Flash/PoolHooks read it in token
    // terms), and raising it would silently raise the first depositor's burn to five figures.
    uint8 pow10 = asset.deadSeedPow10;
    uint256 seed = pow10 == 0 ? 10 ** asset.decimals / C.DEAD_SHARE_SEED_DIV : 10 ** pow10;
    if (seed == 0) seed = 1; // decimals ≤ 3: 0.001 token is sub-wei, and a 0 seed is no seed
    // CEIL. A floored `seed*WAD/idx` hit 0 on any leg whose index outgrew the seed and then reverted
    // ZeroValue on EVERY credit: deposit, donate, swapLiability and hookCreditYield were bricked
    // forever, on exactly the legs the pin already pinned. Ceil always mints ≥ 1 share.
    deadLp = (seed * SC.WAD + idx - 1) / idx;
    if ((value * SC.WAD) / idx < deadLp) {
      if (strict) revert Err.InsufficientAmount(value, seed);
      return (0, false);
    }
    lp.mint(address(0), deadLp);
    emit IPool.DeadSharesSeeded(tkn, seed, deadLp);
    seeded = true;
  }

  function applyHaircut(uint256 amount, uint128 reserves, uint128 liabilities, uint16 suppression)
    internal
    pure
    returns (uint256 actualAmount, uint256 haircutAmount)
  {
    if (liabilities == 0 || reserves >= liabilities) return (amount, 0);
    uint256 deficit = ((uint256(liabilities) - uint256(reserves)) * 1e18) / uint256(liabilities);
    uint256 factor = suppression >= C.HAIRCUT_SUPPRESSOR_DISABLE
      ? 0
      : SC.WAD - (uint256(suppression) * SC.WAD / C.HAIRCUT_SUPPRESSOR_DISABLE);
    uint256 haircutRatio = (deficit * factor) / 1e18;
    if (haircutRatio > 1e18) haircutRatio = 1e18;
    // ACC-04: round the haircut UP so `actualAmount` rounds DOWN — a floored haircut let the
    // withdrawer over-draw ≤1 wei of an under-covered reserve. ceilDiv keeps the dust with the pool.
    haircutAmount = (amount * haircutRatio + 1e18 - 1) / 1e18;
    actualAmount = amount - haircutAmount;
  }

  function deposit(IPool.PoolStorage storage $, address token, uint256 amount)
    external
    returns (IPool.DepositResult memory)
  {
    if (amount == 0) revert Err.ZeroValue();

    address tkn = PoolIO.wrap($, token);
    IPool.Asset storage asset = $.assets[tkn];
    if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tkn);

    IPool.RiskConfig storage rc = $.riskConfigs[tkn]; // one SLOAD of the packed slot, shared below
    PoolDecay.applyDecay(asset, rc, tkn);
    PoolIO.checkRiskFlags(rc, 0);

    uint256 amt = PoolIO.pull($, token, amount);
    if (amt > type(uint128).max) revert Err.ExcessiveAmount(amt, type(uint128).max);

    uint256 idx = mintIndex(asset);
    uint256 lpAmt = (amt * SC.WAD) / idx;
    (uint256 deadLp,) = seedDeadShares($, asset, tkn, idx, amt, true);
    unchecked {
      lpAmt -= deadLp; // the seed gate is `amt*WAD/idx >= deadLp`, i.e. exactly `lpAmt >= deadLp`
    }
    // ACC-03: a deposit too small to mint ≥1 LP share would still credit reserves+liabilities —
    // free liquidity donated to existing LPs. Reject the zero-share dust deposit.
    if (lpAmt == 0) revert Err.ZeroValue();

    asset.reserves += uint128(amt);
    asset.liabilities += uint128(amt);
    ILPToken($.lpTokens[tkn]).mint(msg.sender, lpAmt);

    PoolHooks.postInflow($, tkn, msg.sender, amt, lpAmt);

    emit IPool.Deposited(msg.sender, tkn, amt, lpAmt);
    return IPool.DepositResult({lpAmount: lpAmt, actualDeposit: amt, deadLp: deadLp});
  }

  /// @dev Raise an asset's liquidity index after `added` value accrues to LPs over `liabBefore`
  ///      (donate, hookCreditYield, swap/flash fee). liquidityIndex (uint64) is the sole share↔value
  ///      converter for all LPs of this asset; a raw cast would wrap on overflow and silently corrupt
  ///      every holder's balance.
  ///      #73: the overflow used to REVERT, which made the ceiling an absorbing state — seed a leg
  ///      at 1 wei of liabilities, donate the index up against it, withdraw, and every later donate
  ///      and hookCreditYield on that leg reverted forever for the cost of gas. CLAMP instead. The
  ///      clamp is not a weakened guard: it is strictly downward, so `S*index/WAD <= liabilities`
  ///      still holds (shares under-claim, never over-claim) and no leg can be bricked. Value above
  ///      the clamp is stranded in `liabilities`, visible as a flat index in the IndexUpdated log.
  ///      Reaching the clamp is what `seedDeadShares` prices out: at a uint96 field over a WAD base
  ///      the attacker must carry the dead floor across 7.92e10x of headroom to get there.
  function raiseIndex(
    IPool.Asset storage asset,
    address token,
    uint256 liabBefore,
    uint256 added,
    uint8 reason
  ) internal {
    // A wiped leg (index 0) is terminal and multiplies back to 0: donate/hookCreditYield would book
    // reserves + liabilities, mint nothing, and strand the funds silently. Fail closed, like mintIndex.
    uint256 idx = mintIndex(asset);
    uint256 newIndex = liabBefore == 0 ? idx : (idx * (liabBefore + added)) / liabBefore;
    if (newIndex > type(uint96).max) newIndex = type(uint96).max;
    asset.liquidityIndex = uint96(newIndex);
    emit IPool.IndexUpdated(token, newIndex, asset.reserves, asset.liabilities, reason);
  }

  /// @notice Book an LP fee ALREADY retained in `asset.reserves` as LP-claimable value.
  /// @dev Caller must have credited the reserves first; this only moves the claim side, so coverage
  ///      stays flat. Value above `liabilities` is unreachable by every exit path (face-only
  ///      withdraw, haircut identity at c ≥ 1, decay gated below a coverage threshold, no sweep).
  ///      SKIPS, never reverts, on the degenerate books, because this runs inside swap/flash
  ///      settlement and a revert here is a leg-wide denial of service bought for gas:
  ///      - index 0 (wiped leg): the raise multiplies back to 0.
  ///      - liabilities 0 (all LPs exited): no shares to credit, so it would be phantom liability.
  ///      - fee > liabilities: a dust book (a 1-wei seed pins `liabilities` at 1). Uncapped, one
  ///        such accrual blows the uint64 index ceiling and bricks every later swap out of the leg.
  ///        Capping growth at 2x per call also bounds #73's seed-and-pin grief.
  ///      In all three the fee stays in reserves, exactly as before #71.
  function accrueLpFee(IPool.Asset storage asset, address token, uint256 fee) internal {
    uint256 liabBefore = asset.liabilities;
    if (fee == 0 || asset.liquidityIndex == 0 || liabBefore == 0 || fee > liabBefore) return;
    if (fee > type(uint128).max - liabBefore) {
      revert Err.ExcessiveAmount(fee, type(uint128).max - liabBefore);
    }
    asset.liabilities = uint128(liabBefore + fee);
    raiseIndex(asset, token, liabBefore, fee, C.INDEX_REASON_FEE);
  }

  /// @dev Donating to a leg that has never been credited STRANDS the gift: `liabBefore == 0` no-ops
  ///      the raise, so everything above the dead seed sits in `liabilities` backing no share and is
  ///      inherited by nobody, ever. Deposit first if the intent is to open a leg.
  function donate(IPool.PoolStorage storage $, address token, uint256 amount) external {
    if (amount == 0) revert Err.ZeroValue();

    address tkn = PoolIO.wrap($, token);
    IPool.Asset storage asset = $.assets[tkn];
    if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tkn);

    IPool.RiskConfig storage rc = $.riskConfigs[tkn]; // one SLOAD of the packed slot, shared below
    PoolDecay.applyDecay(asset, rc, tkn);
    PoolIO.checkRiskFlags(rc, 0);

    uint256 amt = PoolIO.pull($, token, amount);
    if (amt > type(uint128).max) revert Err.ExcessiveAmount(amt, type(uint128).max);

    uint256 liabBefore = uint256(asset.liabilities);
    uint256 idx = mintIndex(asset);
    (uint256 deadLp,) = seedDeadShares($, asset, tkn, idx, amt, true);
    uint256 seedVal = (deadLp * idx) / SC.WAD;
    asset.reserves += uint128(amt);
    asset.liabilities += uint128(amt);
    // The seed slice mints shares, so it joins the raise DENOMINATOR and leaves the numerator:
    // raising over its own backing would credit the dead shares twice and push total outstanding
    // claim above `liabilities`.
    raiseIndex(
      asset, tkn, liabBefore == 0 ? 0 : liabBefore + seedVal, amt - seedVal, C.INDEX_REASON_DONATE
    );

    emit IPool.Donated(msg.sender, token, amt);
  }

  struct WithdrawCtx {
    address fromTk;
    address toTk;
    uint256 withdrawValue;
    uint256 amt;
    uint256 haircut;
    uint256 protoFee;
    uint256 lpFee;
  }

  function withdrawTo(
    IPool.PoolStorage storage $,
    address tokenFrom,
    address tokenTo,
    uint256 lpAmount,
    uint256 minAmountOut
  ) external returns (IPool.WithdrawResult memory) {
    PoolIO.requireNoFlash();
    if (lpAmount == 0) revert Err.ZeroValue();

    WithdrawCtx memory ctx;
    ctx.fromTk = PoolIO.wrap($, tokenFrom);
    ctx.toTk = PoolIO.wrap($, tokenTo);

    // No balance pre-read and no cooldown check here: `_applyWithdraw` burns straight off the leg
    // receipt, which reverts internally on insufficiency AND on a share still inside its own
    // anti-JIT window.
    {
      IPool.Asset storage assetFrom = $.assets[ctx.fromTk];
      IPool.Asset storage assetTo = $.assets[ctx.toTk];
      if (assetFrom.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, ctx.fromTk);
      if (assetTo.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, ctx.toTk);
      // FROZEN/ASSET_PAUSED halt on BOTH endpoints: withdrawTo is a value-moving user
      // entrypoint (esp. cross-asset, priced off the output mark). Without this a guardian
      // freeze/pause is bypassed — draining a halted asset's reserves, or pushing a good asset
      // out priced by a halted/compromised feed. Interior-node halts (Pricing) don't cover
      // endpoints, and the direct spoke→base case has no interior node at all.
      // Cache each endpoint's packed RiskConfig slot once; halt-check + decay share the SLOAD.
      IPool.RiskConfig storage rcFrom = $.riskConfigs[ctx.fromTk];
      IPool.RiskConfig storage rcTo = $.riskConfigs[ctx.toTk];
      PoolIO.checkRiskFlags(rcFrom, 0);
      PoolIO.checkRiskFlags(rcTo, 0);
      PoolDecay.applyDecay(assetFrom, rcFrom, ctx.fromTk);
      PoolDecay.applyDecay(assetTo, rcTo, ctx.toTk);

      ctx.withdrawValue = (lpAmount * uint256(assetFrom.liquidityIndex)) / SC.WAD;
      // Mirror swapLiability's guard: shares may never claim more face than the leg owes. This was a
      // silent clamp in _applyWithdraw, which still pushed the full `amt` out while reducing
      // liabilities only to 0 — reserves left with no matching liability cut.
      if (ctx.withdrawValue > assetFrom.liabilities) {
        revert Err.InsufficientAmount(assetFrom.liabilities, ctx.withdrawValue);
      }
      if (ctx.withdrawValue == 0) revert Err.ZeroValue(); // ACC-03 symmetry: no zero-value burn
    }

    if (ctx.fromTk == ctx.toTk) {
      _quoteWithdrawSame($, ctx);
    } else {
      _quoteWithdrawCross($, ctx);
    }

    // Recall BEFORE ledger debit so post-debit R_liq ≥ minLiquidity (same as swap/flash).
    uint256 minLiq = $.assets[ctx.toTk].minLiquidity;
    uint256 cashNeed = ctx.amt + ctx.protoFee;
    PoolHooks.preOutflow($, ctx.toTk, msg.sender, cashNeed + minLiq);
    _applyWithdraw($, ctx, lpAmount);

    {
      uint256 liq = PoolHooks.liquidReserves($, ctx.toTk);
      if (liq < minLiq) revert Err.ThresholdViolation(liq, minLiq);
    }
    if (ctx.amt < minAmountOut) revert Err.ThresholdViolation(ctx.amt, minAmountOut);
    PoolIO.push($, tokenTo, msg.sender, ctx.amt);

    if (ctx.fromTk == ctx.toTk) {
      emit IPool.Withdrawn(msg.sender, ctx.fromTk, ctx.amt, lpAmount);
    } else {
      // lpAmount is fromTk shares; ctx.amt is toTk tokens. Emitting them together against toTk
      // told a log replayer that toTk shares were burned, so reconstructed balances were wrong on
      // both legs. LiabilitySwapped carries the fromTk burn (out = 0: nothing was minted); Withdrawn
      // carries the toTk payout with lpAmount 0, because no toTk share was burned.
      emit IPool.LiabilitySwapped(msg.sender, ctx.fromTk, ctx.toTk, lpAmount, 0, ctx.haircut);
      emit IPool.Withdrawn(msg.sender, ctx.toTk, ctx.amt, 0);
    }
    return IPool.WithdrawResult({amountOut: ctx.amt, lpBurned: lpAmount});
  }

  function _quoteWithdrawSame(IPool.PoolStorage storage $, WithdrawCtx memory ctx) private view {
    IPool.Asset storage assetFrom = $.assets[ctx.fromTk];
    (ctx.amt, ctx.haircut) = applyHaircut(
      ctx.withdrawValue, assetFrom.reserves, assetFrom.liabilities, assetFrom.haircutSuppressor
    );
    if (assetFrom.reserves < ctx.amt) revert Err.InsufficientAmount(assetFrom.reserves, ctx.amt);
    if (ctx.amt > type(uint128).max) revert Err.ExcessiveAmount(ctx.amt, type(uint128).max);
  }

  function _quoteWithdrawCross(IPool.PoolStorage storage $, WithdrawCtx memory ctx) private {
    IPool.Asset storage assetFrom = $.assets[ctx.fromTk];
    IPool.Asset storage assetTo = $.assets[ctx.toTk];
    // From-asset coverage haircut BEFORE the mark conversion, mirroring same-asset: an LP exiting an
    // under-covered asset converts only face·c_from and leaves its deficit socialized (liabilities still
    // drop by the FULL face below, so the index invariant holds). Without this the cross path pays full
    // face out of the healthy output asset — an under-covered LP escapes the haircut (Lemma B) and dumps
    // its deficit onto the output asset's LPs (bank-run bypass).
    (uint256 fairValue,) = applyHaircut(
      ctx.withdrawValue, assetFrom.reserves, assetFrom.liabilities, assetFrom.haircutSuppressor
    );
    IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, ctx.fromTk, ctx.toTk, fairValue);
    // Depeg breaker on BOTH legs, AFTER the quote so the guards hit the tx-primed transient feed
    // cache (swapLiability ordering): the conversion is priced off fromTk's mark, so a wrong-but-
    // fresh fromTk mark (above its refBand / reservationPriceMax) over-delivers the healthy output
    // asset — the same drain the exec/swapLiability input-leg guard closes. Reverting after the
    // quote is state-identical to reverting before it (all-or-nothing tx).
    PoolIO.priceBandGuard($, ctx.fromTk, assetFrom);
    PoolIO.priceBandGuard($, ctx.toTk, assetTo);
    (ctx.amt, ctx.haircut) =
      applyHaircut(q.amountOut, assetTo.reserves, assetTo.liabilities, assetTo.haircutSuppressor);
    ctx.protoFee = q.protoFee;
    ctx.lpFee = q.lpFee;
    uint256 outNeed = ctx.amt + ctx.protoFee;
    if (assetTo.reserves < outNeed) revert Err.InsufficientAmount(assetTo.reserves, outNeed);
  }

  function _applyWithdraw(IPool.PoolStorage storage $, WithdrawCtx memory ctx, uint256 lpAmount)
    private
  {
    ILPToken($.lpTokens[ctx.fromTk]).burn(msg.sender, lpAmount);
    IPool.Asset storage assetFrom = $.assets[ctx.fromTk];
    // withdrawValue ≤ liabilities is enforced at the quote (no clamp): the full face is always burned.
    if (ctx.fromTk == ctx.toTk) {
      assetFrom.reserves -= uint128(ctx.amt);
      assetFrom.liabilities -= uint128(ctx.withdrawValue);
    } else {
      IPool.Asset storage assetTo = $.assets[ctx.toTk];
      assetFrom.liabilities -= uint128(ctx.withdrawValue);
      if (ctx.protoFee > 0) $.protocolFees[ctx.toTk] += ctx.protoFee;
      assetTo.reserves -= uint128(ctx.amt + ctx.protoFee);
      accrueLpFee(assetTo, ctx.toTk, ctx.lpFee); // spread is charged on the OUTPUT leg, as in exec
    }
  }

  function swapLiability(
    IPool.PoolStorage storage $,
    address tokenIn,
    address tokenOut,
    uint256 lpAmountIn,
    uint256 minLpAmountOut
  ) external returns (uint256 lpAmountOut) {
    PoolIO.requireNoFlash();
    if (lpAmountIn == 0) revert Err.ZeroValue();

    address inTk = PoolIO.wrap($, tokenIn);
    address outTk = PoolIO.wrap($, tokenOut);
    if (inTk == outTk) revert Err.InvalidInput();

    IPool.Asset storage assetIn = $.assets[inTk];
    IPool.Asset storage assetOut = $.assets[outTk];
    if (assetIn.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, inTk);
    if (assetOut.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, outTk);

    IPool.RiskConfig storage rIn = $.riskConfigs[inTk];
    IPool.RiskConfig storage rOut = $.riskConfigs[outTk];
    PoolDecay.applyDecay(assetIn, rIn, inTk);
    PoolDecay.applyDecay(assetOut, rOut, outTk);
    PoolIO.checkRiskFlags(rIn, C.LIABILITY_SWAP_ENABLED_BIT);
    PoolIO.checkRiskFlags(rOut, C.LIABILITY_SWAP_ENABLED_BIT);

    uint256 liabIn = (lpAmountIn * uint256(assetIn.liquidityIndex)) / SC.WAD;
    if (liabIn > assetIn.liabilities) revert Err.InsufficientAmount(assetIn.liabilities, liabIn);

    // In-asset coverage haircut BEFORE the mark conversion, mirroring _withdrawSame: re-denominate only
    // face·c_in of an under-covered position (liabIn is still burned in FULL below). Else a swapLiability
    // out of an under-covered asset escapes the haircut (Lemma B) and dumps its deficit onto the
    // destination asset's LPs — the same bank-run bypass the cross-withdraw path guards.
    (uint256 fairIn,) =
      applyHaircut(liabIn, assetIn.reserves, assetIn.liabilities, assetIn.haircutSuppressor);
    IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, inTk, outTk, fairIn);
    // Depeg breaker on both legs — liability re-denomination is priced off both marks, so a
    // wrong-but-fresh mark must halt it exactly like swap/withdrawTo (which gate the output leg).
    PoolIO.priceBandGuard($, outTk, assetOut);
    PoolIO.priceBandGuard($, inTk, assetIn);
    // Liability re-denomination is deliberately protocol-fee-EXEMPT (unlike swap/withdrawTo-cross):
    // it moves no reserves, so there is no physical outflow to skim q.protoFee from — capturing it
    // would debit the output reserve with no matching inflow and degrade coverage. The swapper is
    // still charged the full spread (q.amountOut is net); both fee legs stay as reduced net liability.
    // NOT routed through accrueLpFee, unlike exec/flash/cross-withdraw: there is no retained token
    // here to back an index raise, so booking it would mint claim against nothing. It lands as a
    // global coverage gain instead, which is only realisable while some leg sits under-covered.
    // applyHaircut self-gates (identity when reserves >= liabilities) — no outer guard needed.
    (uint256 liabOut, uint256 haircut) =
      applyHaircut(q.amountOut, assetOut.reserves, assetOut.liabilities, assetOut.haircutSuppressor);

    uint256 idxOut = mintIndex(assetOut);
    lpAmountOut = (liabOut * SC.WAD) / idxOut;
    // Before the slippage check, so minLpAmountOut is measured on what the swapper receives.
    (uint256 deadOut,) = seedDeadShares($, assetOut, outTk, idxOut, liabOut, true);
    unchecked {
      lpAmountOut -= deadOut;
    }

    assetIn.liabilities -= uint128(liabIn);
    assetOut.liabilities += uint128(liabOut);
    if (lpAmountOut < minLpAmountOut) revert Err.ThresholdViolation(lpAmountOut, minLpAmountOut);

    // The burn is gated by the in-leg's own lock and reverts on insufficiency; the mint arms a
    // fresh lock over the destination shares, so the rebalanced position cannot exit the round trip
    // any earlier than the original deposit could have.
    ILPToken($.lpTokens[inTk]).burn(msg.sender, lpAmountIn);
    ILPToken($.lpTokens[outTk]).mint(msg.sender, lpAmountOut);

    emit IPool.LiabilitySwapped(msg.sender, inTk, outTk, lpAmountIn, lpAmountOut, haircut);
    return lpAmountOut;
  }
}
