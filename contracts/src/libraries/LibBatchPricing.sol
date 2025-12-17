// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPoolV1} from "../interfaces/IPoolV1.sol";
import {IErrors} from "../interfaces/IErrors.sol";
import {LibMaths as M} from "./LibMaths.sol";
import {LibPricing as Pricing} from "./LibPricing.sol";

/// @title LibBatchPricing
/// @notice Batch swap quoting and calldata unpacking
/// @dev Input:  [address(20) | uint64 amountB64(8) | reserved(4)]
/// @dev Output (quote): [address(20) | uint16 weightBps(2) | uint16 slippageBps(2) | reserved(8)]
/// @dev Output (swap):  [address(20) | uint16 weightBps(2) | reserved(2) | uint64 minOutB64(8)]
library LibBatchPricing {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS_BASE = 10000;
    uint256 internal constant MAX_TOKENS = 8;

    /// @notice Batch quote result
    struct BatchQuote {
        uint256 totalValueIn;        // Total input value in base terms
        uint256[] amountsOut;        // Expected output per token (after impact)
        uint256[] minAmountsOut;     // With slippage applied
        uint256 avgSpreadBps;        // Value-weighted average spread
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CALLDATA UNPACKING (shared by quoteBatch and batchSwap)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Unpack input: [address(20) | uint64 amountB64(8) | reserved(4)]
    function unpackInput(bytes calldata data, uint256 i) internal pure returns (address token, uint64 amountB64) {
        assembly {
            let ptr := add(data.offset, mul(i, 32))
            let packed := calldataload(ptr)
            token := shr(96, packed)
            amountB64 := and(shr(32, packed), 0xFFFFFFFFFFFFFFFF)
        }
    }

    /// @notice Unpack output for quoting: [address(20) | uint16 weightBps(2) | uint16 slippageBps(2) | reserved(8)]
    function unpackQuoteOutput(bytes calldata data, uint256 i) internal pure returns (address token, uint16 weightBps, uint16 slippageBps) {
        assembly {
            let ptr := add(data.offset, mul(i, 32))
            let packed := calldataload(ptr)
            token := shr(96, packed)
            weightBps := and(shr(80, packed), 0xFFFF)
            slippageBps := and(shr(64, packed), 0xFFFF)
        }
    }

    /// @notice Unpack output for swap: [address(20) | uint16 weightBps(2) | reserved(2) | uint64 minOutB64(8)]
    function unpackSwapOutput(bytes calldata data, uint256 i) internal pure returns (address token, uint16 weightBps, uint64 minOutB64) {
        assembly {
            let ptr := add(data.offset, mul(i, 32))
            let packed := calldataload(ptr)
            token := shr(96, packed)
            weightBps := and(shr(80, packed), 0xFFFF)
            minOutB64 := and(packed, 0xFFFFFFFFFFFFFFFF)
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BATCH QUOTING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Quote batch swap: inputs → base (virtual) → outputs
    /// @param $ Pool storage
    /// @param inputs Packed, 32 bytes each: [address(20) | uint64 amountB64(8) | reserved(4)]
    /// @param outputs Packed, 32 bytes each: [address(20) | uint16 weightBps(2) | uint16 slippageBps(2) | reserved(8)]
    /// @return quote Batch quote with expected outputs
    function quoteBatch(
        IPoolV1.PoolStorage storage $,
        bytes calldata inputs,
        bytes calldata outputs
    ) internal returns (BatchQuote memory quote) {
        uint256 inLen = inputs.length / 32;
        uint256 outLen = outputs.length / 32;

        if (inputs.length % 32 != 0 || inLen == 0 || inLen > MAX_TOKENS) revert IErrors.InvalidInput();
        if (outputs.length % 32 != 0 || outLen == 0 || outLen > MAX_TOKENS) revert IErrors.InvalidInput();

        address baseToken = $.baseToken;

        // ═══════════════════════════════════════════════════════════════════
        // PHASE 1: Quote all sells (input → base) with full traversal impact
        // ═══════════════════════════════════════════════════════════════════

        uint256 totalBaseValue;

        for (uint256 i; i < inLen;) {
            (address token, uint64 amountB64) = unpackInput(inputs, i);

            IPoolV1.Asset storage asset = $.assets[token];
            if (asset.decimals == 0) revert IErrors.NotFound(IErrors.Resource.ASSET, token);

            uint256 amount = M.decodeB64(amountB64, asset.decimals);

            // Quote sell: token → base (with full anchor path traversal)
            if (token == baseToken) {
                totalBaseValue += amount;
            } else {
                IPoolV1.SwapQuote memory sellQuote = Pricing.getAnchorPathQuote($, token, baseToken, amount);
                totalBaseValue += sellQuote.amountOut;
            }

            unchecked { ++i; }
        }

        if (totalBaseValue == 0) revert IErrors.ZeroValue();
        quote.totalValueIn = totalBaseValue;

        // ═══════════════════════════════════════════════════════════════════
        // PHASE 2: Quote all buys (base → output) with full traversal impact
        // ═══════════════════════════════════════════════════════════════════

        quote.amountsOut = new uint256[](outLen);
        quote.minAmountsOut = new uint256[](outLen);

        uint256 weightSum;
        uint256 weightedSpread;

        for (uint256 j; j < outLen;) {
            (address token, uint16 weightBps, uint16 slippageBps) = unpackQuoteOutput(outputs, j);

            if ($.assets[token].decimals == 0) revert IErrors.NotFound(IErrors.Resource.ASSET, token);

            weightSum += weightBps;

            // Target base value for this output
            uint256 targetBaseValue = (totalBaseValue * weightBps) / BPS_BASE;

            // Quote buy: base → token (with full anchor path traversal)
            uint256 amountOut;
            uint256 spreadBps;

            if (token == baseToken) {
                amountOut = targetBaseValue;
                spreadBps = 0;
            } else {
                IPoolV1.SwapQuote memory buyQuote = Pricing.getAnchorPathQuote($, baseToken, token, targetBaseValue);
                amountOut = buyQuote.amountOut;
                spreadBps = buyQuote.spreadBps;
            }

            quote.amountsOut[j] = amountOut;

            // Apply slippage (default 50 = 0.5%)
            if (slippageBps == 0) slippageBps = 50;
            quote.minAmountsOut[j] = (amountOut * (BPS_BASE - slippageBps)) / BPS_BASE;

            // Accumulate weighted spread
            weightedSpread += spreadBps * weightBps;

            unchecked { ++j; }
        }

        if (weightSum != BPS_BASE) revert IErrors.InvalidInput();

        quote.avgSpreadBps = weightedSpread / BPS_BASE;
    }
}
