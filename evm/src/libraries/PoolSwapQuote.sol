// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Pricing} from "./Pricing.sol";
import {PoolHookExec} from "./PoolHookExec.sol";
import {PoolIO} from "./PoolIO.sol";

/// @title PoolSwapQuote -quoting + hook-fee post-processing extracted from PoolSwap.
/// @notice Phase 42K.10D.B2 — bytecode split. PoolSwap (hot exact-in path) DELEGATECALLs into
///         this library for the post-quote pipeline (hook fees, exec, oracle push) so its
///         standalone bytecode fits under EIP-170. Pure refactor; hook behavior unchanged.
library PoolSwapQuote {

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
        PoolIO.exec($, tk[0], tk[1], actualIn, q);

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
        PoolIO.pushOracle($, q);
    }
}
