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

/// @title PoolBatch — batchSwap via PoolIO.exec (DELEGATECALL from Pool trampoline).
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
        // ACC-07: batch inputs are ERC-20 ONLY. Routing the native sentinel through pull(NATIVE) re-reads
        // the FULL msg.value and refunds the excess PER LEG, draining the contract to stray ETH so a 2nd
        // native leg steals stranded ETH or reverts; it also conflated wnative-as-ERC-20 input with native.
        // Wrap ETH→WETH off-chain and pass wnative as a normal ERC-20 leg (pulled via safeTransferFrom).
        if (tk == SC.NATIVE) revert Err.InvalidInput();
        IPool.Asset storage a = $.assets[tk];
        if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tk);

        IPool.RiskConfig storage rc = $.riskConfigs[tk];
        PoolIO.checkRiskFlags(rc, C.SWAP_ENABLED_BIT);
        PoolDecay.applyDecay(a, rc);

        uint256 amt = PoolIO.pull($, tk, M.decodeB64(amtB64, a.decimals));

        if (tk == base) return amt;
        IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, tk, base, amt);
        PoolIO.exec($, tk, base, amt, q, a, $.assets[base]);
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

        IPool.RiskConfig storage rc = $.riskConfigs[tk];
        PoolIO.checkRiskFlags(rc, C.SWAP_ENABLED_BIT);
        PoolDecay.applyDecay(a, rc);

        if (tk == base) {
            outAmt = baseIn;
        } else {
            IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, base, tk, baseIn);
            PoolIO.exec($, base, tk, baseIn, q, $.assets[base], a);
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
        // Hub halt gate: every batch transits base (inputs accumulate into it, outputs draw from it),
        // but each leg prices base as an ENDPOINT, so Pricing's interior-node HALT_MASK check never
        // fires — a frozen/paused base would still route spoke↔spoke. Mirror the single-swap interior
        // gate here (base as an explicit input/output is halt-checked per-entry regardless).
        PoolIO.checkRisk($, base, 0);
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
            address rawTk;
            assembly ("memory-safe") { rawTk := shr(96, calldataload(add(outputs.offset, mul(j, 32)))) }
            // Unwrap only when caller packed the native sentinel — passing wnative as ERC-20
            // must deliver WETH (parity with single-path swap).
            address pushTk = rawTk == SC.NATIVE ? SC.NATIVE : PoolIO.wrap($, rawTk);
            PoolIO.push($, pushTk, recipient, amountsOut[j]);
            unchecked { ++j; }
        }

        emit IPool.BatchSwapped(msg.sender, recipient, inLen, outLen, baseTotal);
    }
}
