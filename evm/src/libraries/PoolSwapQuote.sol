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
        out = q.amountOut;
        // Gas: skip ALL hook delegatecalls when neither token has a hook (the common case). When no
        // hook is set, preSwap returns (0,0), applyHookFee(0)=out, postSwap returns 0 — so the guard
        // is behavior-preserving and saves the 3 external DELEGATECALL hops (~8k gas/swap).
        bool hasHook = $.hooks[tk[0]] != address(0) || $.hooks[tk[1]] != address(0);

        if (hasHook) {
            (uint256 extraFee, uint16 feeOverride) = PoolHookExec.preSwap($, tk[0], tk[1], actualIn, q.amountOut);
            if (feeOverride > 0) {
                // R44-1 (T3-HIGH1): clamp hook-supplied `feeOverride` to in-token's admin-configured
                //   `maxFeeBps` (PBPS). Prevents a compromised hook from inflating q.protoFee + draining
                //   output reserves.
                uint16 cap = $.assets[tk[0]].maxFeeBps;
                if (cap != 0 && feeOverride > cap) feeOverride = cap;
                uint256 raw = out + q.protoFee + q.lpFee;
                uint256 fee = (raw * feeOverride) / 1_000_000;
                (q.protoFee, q.lpFee) = Pricing.splitFee(fee, $.feeParams.protoShare);
                q.spreadBps = feeOverride;
                q.amountOut = raw - fee;
                out = q.amountOut;
            }
            // R44-1: applyHookFee clamps extraFee ≤ 5% of `out` + routes to q.lpFee only.
            if (extraFee > 0) out = PoolHookExec.applyHookFee($, extraFee, q, out);
        }

        PoolIO.exec($, tk[0], tk[1], actualIn, q);

        if (hasHook) {
            int256 delta = PoolHookExec.postSwap($, tk[0], tk[1], actualIn, out);
            if (delta > 0) {
                out = PoolHookExec.applyHookFee($, uint256(delta), q, out);
            } else if (delta < 0) {
                // Symmetric to the positive-fee 5% cap (R44-1): a hook-supplied output BONUS drains the
                // output reserve, so bound it to 5% of `out` — a compromised hook cannot return an
                // arbitrary negative delta to empty the leg down to minLiquidity.
                uint256 bonus = uint256(-delta);
                uint256 cap = out / 20;
                if (bonus > cap) bonus = cap;
                out += bonus;
            }
        }

        _reconcile($.assets[tk[1]], out, q.amountOut);
    }
}
