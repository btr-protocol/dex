// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
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
  // Events canonical @ IPool (Deposited / Withdrawn / LiabilitySwapped / Donated).
  function _checkCooldown(IPool.PoolStorage storage $, uint32 lastTs) private view {
    uint16 cooldown = $.flowCooldownSeconds;
    if (cooldown == 0 || lastTs == 0) return;
    unchecked {
      if (block.timestamp < lastTs + cooldown) {
        revert Err.CooldownActive(lastTs + cooldown - uint32(block.timestamp));
      }
    }
  }

  /// @dev Share-minting index. Reverts on a wiped leg (index 0 = total write-down): minting there
  ///      would divide by zero, and any share minted after a wipe would be diluted 1:0 against the
  ///      stale supply. A wiped leg is terminal; list a new one.
  function mintIndex(IPool.Asset storage asset) internal view returns (uint256 idx) {
    idx = asset.liquidityIndex;
    if (idx == 0) revert Err.InvalidState();
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

    uint256 lpAmt = (amt * SC.WAD) / mintIndex(asset);
    // ACC-03: a deposit too small to mint ≥1 LP share would still credit reserves+liabilities —
    // free liquidity donated to existing LPs. Reject the zero-share dust deposit.
    if (lpAmt == 0) revert Err.ZeroValue();

    asset.reserves += uint128(amt);
    asset.liabilities += uint128(amt);
    $.lpBalances[msg.sender][tkn] += lpAmt;
    $.lastDepositTime[msg.sender][tkn] = uint32(block.timestamp);

    PoolHooks.postInflow($, tkn, msg.sender, amt, lpAmt);

    emit IPool.Deposited(msg.sender, tkn, amt, lpAmt);
    return IPool.DepositResult({lpAmount: lpAmt, actualDeposit: amt});
  }

  /// @dev Raise an asset's liquidity index after `added` value accrues to LPs over `liabBefore`
  ///      (donate, hookCreditYield). Checked cast: liquidityIndex (uint64) is the sole share↔value
  ///      converter for all LPs of this asset; a raw cast would wrap on overflow and silently corrupt
  ///      every holder's balance. Fail closed instead — an accrual that would overflow the index reverts.
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
    if (newIndex > type(uint64).max) revert Err.ExcessiveAmount(newIndex, type(uint64).max);
    asset.liquidityIndex = uint64(newIndex);
    emit IPool.IndexUpdated(token, newIndex, asset.reserves, asset.liabilities, reason);
  }

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
    asset.reserves += uint128(amt);
    asset.liabilities += uint128(amt);
    raiseIndex(asset, tkn, liabBefore, amt, C.INDEX_REASON_DONATE);

    emit IPool.Donated(msg.sender, token, amt);
  }

  struct WithdrawCtx {
    address fromTk;
    address toTk;
    uint256 withdrawValue;
    uint256 amt;
    uint256 haircut;
    uint256 protoFee;
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

    _checkCooldown($, $.lastDepositTime[msg.sender][ctx.fromTk]);
    if ($.lpBalances[msg.sender][ctx.fromTk] < lpAmount) {
      revert Err.InsufficientAmount($.lpBalances[msg.sender][ctx.fromTk], lpAmount);
    }

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
    uint256 outNeed = ctx.amt + ctx.protoFee;
    if (assetTo.reserves < outNeed) revert Err.InsufficientAmount(assetTo.reserves, outNeed);
  }

  function _applyWithdraw(IPool.PoolStorage storage $, WithdrawCtx memory ctx, uint256 lpAmount)
    private
  {
    $.lpBalances[msg.sender][ctx.fromTk] -= lpAmount;
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

    // JIT flow-guard: subject to the same cooldown as withdrawTo, else deposit→swapLiability→withdraw
    // exits the position before the anti-JIT window elapses.
    _checkCooldown($, $.lastDepositTime[msg.sender][inTk]);

    IPool.RiskConfig storage rIn = $.riskConfigs[inTk];
    IPool.RiskConfig storage rOut = $.riskConfigs[outTk];
    PoolDecay.applyDecay(assetIn, rIn, inTk);
    PoolDecay.applyDecay(assetOut, rOut, outTk);
    PoolIO.checkRiskFlags(rIn, C.LIABILITY_SWAP_ENABLED_BIT);
    PoolIO.checkRiskFlags(rOut, C.LIABILITY_SWAP_ENABLED_BIT);

    if ($.lpBalances[msg.sender][inTk] < lpAmountIn) {
      revert Err.InsufficientAmount($.lpBalances[msg.sender][inTk], lpAmountIn);
    }

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
    // still charged the full spread (q.amountOut is net); the proto share stays as reduced net
    // liability = coverage to LPs (conservative, LP-safe). Audit-confirmed design choice, not a gap.
    // applyHaircut self-gates (identity when reserves >= liabilities) — no outer guard needed.
    (uint256 liabOut, uint256 haircut) =
      applyHaircut(q.amountOut, assetOut.reserves, assetOut.liabilities, assetOut.haircutSuppressor);

    lpAmountOut = (liabOut * SC.WAD) / mintIndex(assetOut);

    assetIn.liabilities -= uint128(liabIn);
    assetOut.liabilities += uint128(liabOut);
    if (lpAmountOut < minLpAmountOut) revert Err.ThresholdViolation(lpAmountOut, minLpAmountOut);

    $.lpBalances[msg.sender][inTk] -= lpAmountIn;
    $.lpBalances[msg.sender][outTk] += lpAmountOut;
    // Rebalanced position INHERITS the JIT cooldown (never resets it earlier): a later swapLiability
    // or withdraw on the destination is still gated by the original deposit's timestamp.
    uint32 prevOut = $.lastDepositTime[msg.sender][outTk];
    if (block.timestamp > prevOut) $.lastDepositTime[msg.sender][outTk] = uint32(block.timestamp);

    emit IPool.LiabilitySwapped(msg.sender, inTk, outTk, lpAmountIn, lpAmountOut, haircut);
    return lpAmountOut;
  }
}
