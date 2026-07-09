// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {PoolIO} from "./PoolIO.sol";

/// @title PoolSwapQuote -quoting post-processing extracted from PoolSwap.
/// @notice Phase 42K.10D.B2 — bytecode split. PoolSwap (hot exact-in path) DELEGATECALLs into
///         this library for the post-quote pipeline (exec, oracle push) so its standalone
///         bytecode fits under EIP-170.
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
        PoolIO.exec($, tk[0], tk[1], actualIn, q);
        _reconcile($.assets[tk[1]], out, q.amountOut);
    }
}
