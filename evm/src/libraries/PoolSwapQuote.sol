// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Pricing} from "./Pricing.sol";
import {Constants as C} from "./Constants.sol";
import {PoolOracle} from "./PoolOracle.sol";
import {PoolHookExec} from "./PoolHookExec.sol";

/// @title PoolSwapQuote -quoting + hook-fee post-processing extracted from PoolSwap.
/// @notice Phase 42K.10D.B2 — bytecode split. PoolSwap (hot exact-in path) DELEGATECALLs into
///         this library for the post-quote pipeline (hook fees, exec, oracle push) so its
///         standalone bytecode fits under EIP-170. Pure refactor; behavior preserved.
library PoolSwapQuote {

    function _exec(
        IPool.PoolStorage storage $,
        address tkIn,
        address tkOut,
        uint256 amtIn,
        IPool.SwapQuote memory q
    ) private {
        IPool.Asset storage aIn = $.assets[tkIn];
        IPool.Asset storage aOut = $.assets[tkOut];

        uint256 minReq = q.amountOut + q.protoFee + aOut.minLiquidity;
        if (aOut.reserves < minReq) revert Err.InsufficientAmount(aOut.reserves, minReq);

        uint256 inFee = (amtIn * q.spreadBps / 2) / 1_000_000;
        aIn.reserves += uint128(amtIn - inFee);
        $.protocolFees[tkIn] += inFee;
        aOut.reserves -= uint128(q.amountOut + q.protoFee);
        $.protocolFees[tkOut] += q.protoFee;

        uint64 floor = aOut.reservationPrice;
        if (floor != 0) {
            uint64 price = PoolOracle.readOracle($, address(this), tkOut).lastPriceB64;
            if (price < floor) revert Err.PriceBelowReservation(price, floor);
        }
    }

    function _reconcile(IPool.Asset storage a, uint256 actual, uint256 expected) private {
        if (actual == expected) return;
        uint256 d = actual > expected ? actual - expected : expected - actual;
        if (d > type(uint128).max) revert Err.ExcessiveAmount(d, type(uint128).max);
        if (actual > expected) a.reserves -= uint128(d);
        else a.reserves += uint128(d);
    }

    function processSwap(
        IPool.PoolStorage storage $,
        address[2] memory tk,
        uint256 actualIn,
        IPool.SwapQuote memory q
    ) external returns (uint256 out) {
        (uint256 extraFee, uint16 feeOverride) = PoolHookExec.preSwap($, tk[0], tk[1], actualIn, q.amountOut);
        out = q.amountOut;

        if (feeOverride > 0) {
            // R44-1 (T3-HIGH1): clamp hook-supplied `feeOverride` to in-token's admin-configured
            //   `maxFeeBps` (stored in PBPS, 1e6 = 100%). Prevents a compromised hook from
            //   returning an arbitrarily large fee override that would inflate q.protoFee + drain
            //   output reserves under the prior accounting.
            uint16 cap = $.assets[tk[0]].maxFeeBps;
            if (cap != 0 && feeOverride > cap) feeOverride = cap;
            uint256 raw = out + q.protoFee + q.lpFee;
            uint256 fee = (raw * feeOverride) / 1_000_000;
            (q.protoFee, q.lpFee) = Pricing.splitFee(fee, $.feeParams.protoShare);
            q.spreadBps = feeOverride;
            q.amountOut = raw - fee;
            out = q.amountOut;
        }

        // R44-1 (T3-HIGH1): applyHookFee now (a) clamps extraFee ≤ 5% of `out` and (b) routes
        //   to q.lpFee only (no q.protoFee bump) → no protocolFees[tkOut] drain vector.
        out = PoolHookExec.applyHookFee($, extraFee, q, out);
        _exec($, tk[0], tk[1], actualIn, q);

        int256 delta = PoolHookExec.postSwap($, tk[0], tk[1], actualIn, out);
        if (delta > 0) {
            // R44-1: same clamp applies to post-swap-returned extra fees. LP-side credit only.
            out = PoolHookExec.applyHookFee($, uint256(delta), q, out);
        } else if (delta < 0) {
            out += uint256(-delta);
        }

        _reconcile($.assets[tk[1]], out, q.amountOut);
    }

    /// @notice Push hop prices to the oracle accumulator post-swap.
    function pushOracle(IPool.PoolStorage storage $, IPool.SwapQuote memory q) external {
        if (q.routeHops.length < 2 || q.hopPrices.length == 0) return;
        address base = $.baseToken;

        for (uint256 i; i < q.routeHops.length - 1;) {
            address a = q.routeHops[i];
            address b = q.routeHops[i + 1];
            uint64 p = q.hopPrices[i];

            // R44-9 (Pass-44B): sentinel 0 = reserve-clamped hop. Skip TWAP push to prevent
            // pool-emptying oracle poisoning. Pricing._executeLeg sets execPriceB64=0 when
            // amountOut > toRes clamp engaged.
            if (p == 0) { unchecked { ++i; } continue; }

            if (a == base) PoolOracle.pushFeedInternal($, b, address(0), p, 0);
            else if (b == base) PoolOracle.pushFeedInternal($, a, address(0), p, 0);
            else PoolOracle.pushFeedInternal($, a, b, p, p);

            unchecked { ++i; }
        }
    }
}
