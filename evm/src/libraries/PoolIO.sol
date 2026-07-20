// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Constants as C} from "./Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Oracle} from "./Oracle.sol";
import {PoolHooks} from "./PoolHooks.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {TransientCache as TCache} from "./TransientCache.sol";

/// @title PoolIO
/// @notice Shared pool-local token I/O, risk gating, and swap accounting helpers.
library PoolIO {
  /// @dev Transient "flash in flight" flag (per Pool-clone address, tx-scoped). Set while a flash
  ///      loan's callback runs; blocks every reserve-mutating entrypoint so a borrower cannot
  ///      "repay" via deposit/donate/swap (a reserve-crediting path) and double-count the principal
  ///      that `flashSend` pushed out without debiting reserves. ERC-3156 borrowers repay by plain
  ///      transfer/approve, which is unaffected.
  /// @dev keccak256("btr.pool.flashInFlight.v1") — distinct from Solady's ReentrancyGuard slot.
  uint256 private constant FLASH_INFLIGHT_SLOT =
    0x9b4f3bbfca54a0e6e7a1f989e7a8421747090cf08b7f435d15e27a960bfc0532;

  function enterFlash() internal {
    assembly { tstore(FLASH_INFLIGHT_SLOT, 1) }
  }

  function exitFlash() internal {
    assembly { tstore(FLASH_INFLIGHT_SLOT, 0) }
  }

  function requireNoFlash() internal view {
    uint256 v;
    assembly { v := tload(FLASH_INFLIGHT_SLOT) }
    if (v != 0) revert Err.InvalidState();
  }

  function wrap(IPool.PoolStorage storage $, address token) internal view returns (address) {
    return token == SC.NATIVE ? $.wnative : token;
  }

  function _balanceOf(address token) private view returns (uint256) {
    return SafeTransferLib.balanceOf(token, address(this));
  }

  function pull(IPool.PoolStorage storage $, address token, uint256 amount)
    internal
    returns (uint256)
  {
    // Reserve-crediting inflow chokepoint (deposit/donate/swap/batchSwap). Blocked during a flash
    // callback so a borrower cannot repay by crediting reserves (double-count). Legit ERC-3156
    // repayment is a plain transfer, which never routes through pull.
    requireNoFlash();
    if (token == SC.NATIVE) {
      if (msg.value < amount) revert Err.InsufficientAmount(msg.value, amount);
      IWETH9($.wnative).deposit{value: amount}();
      unchecked {
        uint256 excess = msg.value - amount;
        if (excess > 0) SafeTransferLib.safeTransferETH(msg.sender, excess);
      }
      return amount;
    }

    // Payable entrypoints exist solely for the native sentinel. Accepting ETH alongside an ERC-20
    // pull would leave that value outside every reserve/protocol-fee ledger with no recovery path.
    if (msg.value != 0) revert Err.InvalidInput();

    uint256 balBefore = _balanceOf(token);
    SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
    return _balanceOf(token) - balBefore;
  }

  function push(IPool.PoolStorage storage $, address token, address to, uint256 amount) internal {
    if (token == SC.NATIVE) {
      IWETH9($.wnative).withdraw(amount);
      SafeTransferLib.safeTransferETH(to, amount);
    } else {
      SafeTransferLib.safeTransfer(token, to, amount);
    }
  }

  /// @notice Halt/flag gate on a caller-loaded RiskConfig (shared SLOAD with decay).
  function checkRiskFlags(IPool.RiskConfig storage risk, uint16 requiredFlag) internal view {
    if ((risk.flags & C.HALT_MASK) != 0) revert Err.FeatureDisabled(Err.Resource.ASSET);
    if (requiredFlag != 0 && (risk.flags & requiredFlag) == 0) {
      if (requiredFlag == C.SWAP_ENABLED_BIT) revert Err.FeatureDisabled(Err.Resource.SWAP);
      if (requiredFlag == C.LIABILITY_SWAP_ENABLED_BIT) {
        revert Err.FeatureDisabled(Err.Resource.LIABILITY_SWAP);
      }
    }
  }

  /// @notice Reuses caller-warmed Asset storage refs. `minReq` = the `need` the caller already computed
  ///         for preOutflow (out + protoFee + aOut.minLiquidity); threaded in to avoid re-reading
  ///         aOut.minLiquidity (Asset slot 1) across the intervening preOutflow external call.
  /// @dev Canonical settle idiom: need = out + protoFee + output floor, hard-recall via preOutflow,
  ///      then exec. Single source for the three swap-shaped settlement sites (swap + batch legs) so
  ///      the R_liq >= need invariant math can never drift between them.
  function settle(
    IPool.PoolStorage storage $,
    address tkIn,
    address tkOut,
    uint256 amtIn,
    IPool.SwapQuote memory q,
    IPool.Asset storage aIn,
    IPool.Asset storage aOut
  ) internal {
    uint256 need = q.amountOut + q.protoFee + aOut.minLiquidity;
    PoolHooks.preOutflow($, tkOut, msg.sender, need);
    exec($, tkIn, tkOut, amtIn, q, aIn, aOut, need);
  }

  function exec(
    IPool.PoolStorage storage $,
    address tkIn,
    address tkOut,
    uint256 amtIn,
    IPool.SwapQuote memory q,
    IPool.Asset storage aIn,
    IPool.Asset storage aOut,
    uint256 minReq
  ) internal {
    // Executable depth = R_liq (reserves − invested). Pricing still sees full reserves. minReq is the
    // caller's `need`; the liq<minReq check reads reserves/invested FRESH here (post-recall), so the
    // R_liq>=need invariant is unchanged — only the constant RHS is passed in instead of recomputed.
    uint256 inv = $.invested[tkOut];
    uint256 liq = aOut.reserves > inv ? uint256(aOut.reserves) - inv : 0;
    if (liq < minReq) revert Err.InsufficientAmount(liq, minReq);

    if (amtIn > type(uint128).max) revert Err.ExcessiveAmount(amtIn, type(uint128).max);
    aIn.reserves += uint128(amtIn);
    aOut.reserves -= uint128(q.amountOut + q.protoFee);
    if (q.protoFee != 0) $.protocolFees[tkOut] += q.protoFee;

    priceBandGuard($, tkOut, aOut);
    priceBandGuard($, tkIn, aIn);
  }

  /// @dev Depeg guard: absolute reservation band and/or refFeed band. 0 fields = skip.
  function priceBandGuard(IPool.PoolStorage storage $, address token, IPool.Asset storage a)
    internal
    view
  {
    uint64 lo = a.reservationPrice;
    uint64 hi = a.reservationPriceMax;
    IPool.OracleConfig storage oc = $.oracleConfigs[token];
    // refBandBps alone is a sufficient armed-flag: validateOracleConfig (PoolAdmin) enforces
    // refBandBps != 0 ⟹ refFeedId/refPrimary set + reachable. Reads only the warm slot (refBandBps
    // packs with primary/mode, warmed at quote time); avoids a cold SLOAD of refFeedId (own slot) to
    // discover a disabled band. Fail-closed: a corrupt refBandBps!=0/refFeedId==0 state now reverts in
    // getFeed(0) instead of silently disarming the depeg breaker.
    bool refBand = oc.refBandBps != 0;
    if (lo == 0 && hi == 0 && !refBand) return;

    // EXTERNAL mode: reuse the tx-scoped transient cache — Pricing._readOracle read, TTL/CI-gated
    // and cached this exact feed (same primary/feedId, keyed by token) while quoting earlier in
    // this tx, so a second external getFeed round-trip is pure waste (~1k gas). INTERNAL mode must
    // NOT touch the cache: there it holds the SYNTHETIC peg feed (the quote source), while this
    // guard needs the real external feed (the depeg breaker) — always read it fresh.
    IOracle.FeedData memory gf;
    bool cached;
    if (oc.mode != C.ORACLE_MODE_INTERNAL) (cached, gf) = TCache.tryLoadOracleFeed(token);
    if (!cached) {
      gf = IOracle(oc.primary).getFeed(oc.feedId);
      // Fail-closed on every cache miss (INTERNAL always misses; EXTERNAL miss if unprimed).
      // EXTERNAL cache hits were gated at quote prime. Prior code gated INTERNAL only (N-1).
      Oracle.gate(gf);
    }
    uint64 price = gf.lastPriceB64;
    // Compare in numeric (1e18) space, NOT raw uint64: B64 packs mantissa in the high bits, so
    // raw </> orders by mantissa first and is non-monotonic across a decimal-decade boundary — a
    // catastrophic depeg into a different decade would silently bypass the floor/ceiling.
    uint256 p = M.b64To1e18(price);
    if (lo != 0 && p < M.b64To1e18(lo)) revert Err.PriceOutsideReservation(price, lo);
    if (hi != 0 && p > M.b64To1e18(hi)) revert Err.PriceOutsideReservation(price, hi);
    if (refBand) {
      // Layer-3 (Ostium hardening): the reference is read from refPrimary — an oracle with an
      // INDEPENDENT signer set — so a compromised push quorum cannot walk the mark past refBandBps
      // of the reference without halting swaps. Validation requires a distinct refPrimary whenever
      // the band is armed, so refPrimary is never 0 here — fail-closed (no self-ref fallback).
      IOracle.FeedData memory ref = IOracle(oc.refPrimary).getFeed(oc.refFeedId);
      // ORC-10: fail-closed on a stale/dead/over-uncertain reference. The quoting path gates only
      // feedId — a dead/uncertain refFeed keeper would otherwise anchor the band to a corpse price.
      // Oracle.gate returns the reference mark (1e18).
      uint256 refP = Oracle.gate(ref);
      uint256 dev = p > refP ? p - refP : refP - p;
      if (dev * SC.BPS > refP * uint256(oc.refBandBps)) {
        revert Err.PriceOutsideReservation(price, uint64(refP));
      }
    }
  }
}
