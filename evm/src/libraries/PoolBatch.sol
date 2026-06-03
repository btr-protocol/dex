// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Pricing} from "./Pricing.sol";
import {Maths as M} from "./Maths.sol";
import {Constants as C} from "./Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {PoolDecay} from "./PoolDecay.sol";
import {PoolIO} from "./PoolIO.sol";

/// @title PoolBatch -batchSwap implementation extracted from Pool.sol
/// @notice Wave-2 bytecode reduction. batchSwap routes through `PoolIO.exec`
///         (reserve accounting) but does **not** invoke `PoolHookExec` pre/post hooks;
///         single-leg `swap` uses `PoolSwapQuote.processSwap` with full hook dispatch.
///         External lib fn DELEGATECALL'd from Pool's `batchSwap` trampoline,
///         so msg.sender, msg.value, and storage context all match the
///         original inline path. Reentrancy is enforced by the trampoline.
library PoolBatch {
    function _processInput(
        IPool.PoolStorage storage $,
        address base,
        bytes calldata inputs,
        uint256 i
    ) private returns (uint256 baseDelta) {
        address tk; uint64 amtB64;
        assembly ("memory-safe") {
            let packed := calldataload(add(inputs.offset, mul(i, 32)))
            tk := shr(96, packed)
            amtB64 := and(shr(32, packed), 0xFFFFFFFFFFFFFFFF)
        }
        tk = PoolIO.wrap($, tk);
        IPool.Asset storage a = $.assets[tk];
        if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tk);

        PoolIO.checkRisk($, tk, C.SWAP_ENABLED_BIT);
        PoolDecay.applyDecay($, tk, a);

        uint256 amt = PoolIO.pull($, tk == $.wnative ? SC.NATIVE : tk, M.decodeB64(amtB64, a.decimals));

        if (tk == base) return amt;
        IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, tk, base, amt);
        PoolIO.exec($, tk, base, amt, q);
        PoolIO.pushOracle($, q);
        return q.amountOut;
    }

    function _processOutput(
        IPool.PoolStorage storage $,
        address base,
        bytes calldata outputs,
        uint256 baseTotal,
        uint256 j
    ) private returns (uint16 w, uint256 outAmt) {
        address tk; uint64 minB64;
        assembly ("memory-safe") {
            let packed := calldataload(add(outputs.offset, mul(j, 32)))
            tk := shr(96, packed)
            w := and(shr(80, packed), 0xFFFF)
            minB64 := and(packed, 0xFFFFFFFFFFFFFFFF)
        }
        tk = PoolIO.wrap($, tk);
        IPool.Asset storage a = $.assets[tk];
        if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tk);

        uint256 baseIn = (baseTotal * w) / SC.BPS;

        PoolIO.checkRisk($, tk, C.SWAP_ENABLED_BIT);
        PoolDecay.applyDecay($, tk, a);

        if (tk == base) {
            outAmt = baseIn;
        } else {
            IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, base, tk, baseIn);
            PoolIO.exec($, base, tk, baseIn, q);
            PoolIO.pushOracle($, q);
            outAmt = q.amountOut;
        }

        uint256 minOut = M.decodeB64(minB64, a.decimals);
        if (outAmt < minOut) revert Err.ThresholdViolation(outAmt, minOut);
    }

    function batchSwap(
        IPool.PoolStorage storage $,
        bytes calldata inputs,
        bytes calldata outputs,
        address recipient
    ) external returns (uint256[] memory amountsOut) {
        uint256 inLen = inputs.length / 32;
        uint256 outLen = outputs.length / 32;

        if (inputs.length % 32 != 0 || inLen == 0 || inLen > 8) revert Err.InvalidInput();
        if (outputs.length % 32 != 0 || outLen == 0 || outLen > 8) revert Err.InvalidInput();

        address base = $.baseToken;
        amountsOut = new uint256[](outLen);
        uint256 baseTotal;

        for (uint256 i; i < inLen;) {
            baseTotal += _processInput($, base, inputs, i);
            unchecked { ++i; }
        }

        if (baseTotal == 0) revert Err.ZeroValue();

        uint256 wSum;
        for (uint256 j; j < outLen;) {
            (uint16 w, uint256 outAmt) = _processOutput($, base, outputs, baseTotal, j);
            wSum += w;
            amountsOut[j] = outAmt;
            unchecked { ++j; }
        }

        if (wSum != SC.BPS) revert Err.InvalidInput();

        for (uint256 j; j < outLen;) {
            address tk;
            assembly ("memory-safe") { tk := shr(96, calldataload(add(outputs.offset, mul(j, 32)))) }
            tk = PoolIO.wrap($, tk);
            PoolIO.push($, tk == $.wnative ? SC.NATIVE : tk, recipient, amountsOut[j]);
            unchecked { ++j; }
        }

        emit IPool.BatchSwapped(msg.sender, recipient, inLen, outLen, baseTotal);
    }
}
