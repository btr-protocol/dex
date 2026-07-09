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
import {Maths as M} from "./Maths.sol";
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

    function pull(IPool.PoolStorage storage $, address token, uint256 amount) internal returns (uint256) {
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

    function checkRisk(IPool.PoolStorage storage $, address token, uint16 requiredFlag) internal view {
        IPool.RiskConfig storage risk = $.riskConfigs[token];
        // FROZEN (per-asset risk) OR PROTOCOL_PAUSED (guardian emergency halt) both block the asset.
        // Compile-time const mask ⇒ same single AND+ISZERO as before ⇒ +0 runtime gas, no new SLOAD.
        if ((risk.flags & C.HALT_MASK) != 0) revert Err.FeatureDisabled(Err.Resource.ASSET);
        if (requiredFlag != 0 && (risk.flags & requiredFlag) == 0) {
            if (requiredFlag == C.SWAP_ENABLED_BIT) revert Err.FeatureDisabled(Err.Resource.SWAP);
            if (requiredFlag == C.LIABILITY_SWAP_ENABLED_BIT) revert Err.FeatureDisabled(Err.Resource.LIABILITY_SWAP);
            if (requiredFlag == C.FLASH_ENABLED_BIT) revert Err.FeatureDisabled(Err.Resource.FLASH);
        }
    }

    function exec(
        IPool.PoolStorage storage $,
        address tkIn,
        address tkOut,
        uint256 amtIn,
        IPool.SwapQuote memory q
    ) internal {
        IPool.Asset storage aIn = $.assets[tkIn];
        IPool.Asset storage aOut = $.assets[tkOut];

        uint256 minReq = q.amountOut + q.protoFee + aOut.minLiquidity;
        if (aOut.reserves < minReq) revert Err.InsufficientAmount(aOut.reserves, minReq);

        // The full amtIn is credited to reserves; the swap fee is charged ONCE on the output side
        // (q.protoFee is the protocol's share of feeOut, q.lpFee stays in reserves). Skimming a
        // separate input-side half-spread here double-counts the fee and drains LP into the treasury.
        aIn.reserves += uint128(amtIn);
        aOut.reserves -= uint128(q.amountOut + q.protoFee);
        $.protocolFees[tkOut] += q.protoFee;

        // Depeg breaker on BOTH endpoints: a wrong-but-fresh mark on the INPUT asset (its refBand /
        // reservation band) lets a depegged token be dumped into the pool at a stale-high price and
        // drain the output reserve, so the input leg must clear its own band too (not just the output).
        // Both feeds were primed into the tx cache during quoting, so each guard is a cache hit.
        priceBandGuard($, tkOut, aOut);
        priceBandGuard($, tkIn, aIn);
    }

    /// @dev Depeg guard on the OUTPUT asset's fresh mark: an absolute floor/ceiling (reservationPrice /
    ///      reservationPriceMax) AND an optional feed-relative band (mark within refBandBps of a
    ///      reference feed — e.g. WBTC vs the BTC feed, XAUT vs a gold feed). 0 fields = disabled;
    ///      when none is set we skip the oracle read entirely (the swap-path freshness/confidence gate
    ///      already ran during quoting via Pricing._readOracle). Shared by swap (`exec`) and cross-
    ///      asset `withdrawTo` — both deliver output-token reserves to the user.
    function priceBandGuard(IPool.PoolStorage storage $, address token, IPool.Asset storage a) internal view {
        uint64 lo = a.reservationPrice;
        uint64 hi = a.reservationPriceMax;
        IPool.OracleConfig storage oc = $.oracleConfigs[token];
        bool refBand = oc.refFeedId != 0 && oc.refBandBps != 0;
        if (lo == 0 && hi == 0 && !refBand) return;

        // EXTERNAL mode: reuse the tx-scoped transient cache — Pricing._readOracle read, TTL/CI-gated
        // and cached this exact feed (same primary/feedId, keyed by token) while quoting earlier in
        // this tx, so a second external getFeed round-trip is pure waste (~1k gas). INTERNAL mode must
        // NOT touch the cache: there it holds the SYNTHETIC peg feed (the quote source), while this
        // guard needs the real external feed (the depeg breaker) — always read it fresh.
        IOracle.FeedData memory gf;
        bool cached;
        if (oc.mode != C.ORACLE_MODE_INTERNAL) (cached, gf) = TCache.tryLoadOracleFeed(token);
        if (!cached) gf = IOracle(oc.primary).getFeed(oc.feedId);
        // INTERNAL mode quotes off the constant peg and NEVER freshness-gates the external feed on the
        // swap path (Pricing._readOracle returns a synthetic peg feed). Here that external feed is the
        // depeg breaker, so a STALE gate must FAIL-CLOSED (revert) — not silently anchor the band to a
        // corpse price. EXTERNAL mode already TTL-gated feedId while quoting, so this is internal-only.
        if (oc.mode == C.ORACLE_MODE_INTERNAL) {
            uint256 gAge = block.timestamp >= gf.updatedAt ? block.timestamp - gf.updatedAt : type(uint32).max;
            if (gAge > gf.ttl) revert Err.StaleData(gAge > type(uint32).max ? type(uint32).max : uint32(gAge), gf.ttl);
        }
        uint64 price = gf.lastPriceB64;
        // Compare in numeric (1e18) space, NOT raw uint64: B64 packs mantissa in the high bits, so
        // raw </> orders by mantissa first and is non-monotonic across a decimal-decade boundary — a
        // catastrophic depeg into a different decade would silently bypass the floor/ceiling.
        uint256 p = M.b64To1e18(price);
        if (lo != 0 && p < M.b64To1e18(lo)) revert Err.PriceBelowReservation(price, lo);
        if (hi != 0 && p > M.b64To1e18(hi)) revert Err.PriceBelowReservation(price, hi);
        if (refBand) {
            IOracle.FeedData memory ref = IOracle(oc.primary).getFeed(oc.refFeedId);
            // Fail-closed on a stale reference (same per-feed TTL convention as Pricing._readOracle):
            // the quoting path freshness-gates only feedId — a dead refFeedId keeper would otherwise
            // anchor the band to a corpse price and pass/halt against dead data.
            uint256 refAge = block.timestamp >= ref.updatedAt ? block.timestamp - ref.updatedAt : type(uint32).max;
            if (refAge > ref.ttl) revert Err.StaleData(refAge > type(uint32).max ? type(uint32).max : uint32(refAge), ref.ttl);
            uint256 refP = Oracle.mark(ref);
            uint256 dev = p > refP ? p - refP : refP - p;
            if (dev * SC.BPS > refP * uint256(oc.refBandBps)) revert Err.PriceBelowReservation(price, uint64(refP));
        }
    }
}
