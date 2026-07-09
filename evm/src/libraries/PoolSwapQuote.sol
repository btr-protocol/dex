// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {PoolIO} from "./PoolIO.sol";

/// @title PoolSwapQuote -post-quote swap execution extracted from PoolSwap.
/// @notice Phase 42K.10D.B2 — bytecode split. PoolSwap (hot exact-in path) DELEGATECALLs here for the
///         post-quote exec step so its standalone bytecode fits under EIP-170.
library PoolSwapQuote {
    function processSwap(
        IPool.PoolStorage storage $,
        address[2] memory tk,
        uint256 actualIn,
        IPool.SwapQuote memory q
    ) external returns (uint256 out) {
        out = q.amountOut;
        PoolIO.exec($, tk[0], tk[1], actualIn, q);
    }
}
