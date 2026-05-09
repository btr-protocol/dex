// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Base} from "./Base.sol";
import {InternalOracle} from "./InternalOracle.sol";
import {Err} from "../Errors.sol";
import {IExchange} from "../interfaces/modules/IExchange.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IPoolHooks} from "../interfaces/IPoolHooks.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LibPricing as Pricing} from "../libraries/LibPricing.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";

/// @title Exchange — swap, batchSwap, quotes, views
contract Exchange is Base {
    using SafeTransferLib for address;
    using {M.b64To1e18} for uint64;

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external payable nonReentrant whenInitialized returns (uint256 out) {
        IPool.PoolStorage storage $ = _s();
        address[2] memory tk = [_wrap($, tokenIn), _wrap($, tokenOut)];

        if (tk[0] == tk[1]) revert Err.InvalidInput();
        if (amountIn == 0) revert Err.ZeroValue();

        _checkRisk($, tk[0], C.SWAP_ENABLED_BIT);
        _checkRisk($, tk[1], C.SWAP_ENABLED_BIT);
        _applyDecay($, tk[0], $.assets[tk[0]]);
        _applyDecay($, tk[1], $.assets[tk[1]]);

        uint256 actualIn = _pull(tokenIn, amountIn);
        IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, tk[0], tk[1], actualIn);

        out = _processSwap($, tk, actualIn, q);

        // Post-exec floor check (hooks can mutate reserves via _postSwap)
        if ($.assets[tk[1]].reserves < $.assets[tk[1]].minLiquidity) {
            revert Err.ThresholdViolation($.assets[tk[1]].reserves, $.assets[tk[1]].minLiquidity);
        }

        _oracle(q);
        if (out < minAmountOut) revert Err.ThresholdViolation(out, minAmountOut);

        _push(tokenOut, recipient, out);
        emit IExchange.Swapped(msg.sender, recipient, tk[0], tk[1], actualIn, out, q.spreadBps, q.protoFee, q.lpFee);
    }

    function _processSwap(
        IPool.PoolStorage storage $,
        address[2] memory tk,
        uint256 actualIn,
        IPool.SwapQuote memory q
    ) private returns (uint256 out) {
        (uint256 extraFee, uint16 feeOverride) = _preSwap($, tk[0], tk[1], actualIn, q.amountOut);
        out = q.amountOut;

        if (feeOverride > 0) {
            uint256 raw = out + q.protoFee + q.lpFee;
            uint256 fee = (raw * feeOverride) / 1_000_000;
            (q.protoFee, q.lpFee) = Pricing.splitFee(fee, $.feeParams.protoShare);
            q.spreadBps = feeOverride;
            q.amountOut = raw - fee;
            out = q.amountOut;
        }

        out = _applyHookFee($, extraFee, q, out);
        _exec($, tk[0], tk[1], actualIn, q);

        int256 delta = _postSwap($, tk[0], tk[1], actualIn, out);
        if (delta > 0) out = _applyHookFee($, uint256(delta), q, out);
        else if (delta < 0) out += uint256(-delta);

        _reconcile($.assets[tk[1]], out, q.amountOut);
    }

    function getSwapQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external returns (IPool.SwapQuote memory) {
        IPool.PoolStorage storage $ = _s();
        return Pricing.getAnchorPathQuote($, _wrap($, tokenIn), _wrap($, tokenOut), amountIn);
    }

    function batchSwap(
        bytes calldata inputs,
        bytes calldata outputs,
        address recipient
    ) external payable nonReentrant whenInitialized returns (uint256[] memory amountsOut) {
        IPool.PoolStorage storage $ = _s();
        uint256 inLen = inputs.length / 32;
        uint256 outLen = outputs.length / 32;

        if (inputs.length % 32 != 0 || inLen == 0 || inLen > 8) revert Err.InvalidInput();
        if (outputs.length % 32 != 0 || outLen == 0 || outLen > 8) revert Err.InvalidInput();

        address base = $.baseToken;
        amountsOut = new uint256[](outLen);
        uint256 baseTotal;

        for (uint256 i; i < inLen;) {
            address tk; uint64 amtB64;
            assembly {
                let packed := calldataload(add(inputs.offset, mul(i, 32)))
                tk := shr(96, packed)
                amtB64 := and(shr(32, packed), 0xFFFFFFFFFFFFFFFF)
            }
            tk = _wrap($, tk);
            IPool.Asset storage a = $.assets[tk];
            if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tk);

            _checkRisk($, tk, C.SWAP_ENABLED_BIT);
            _applyDecay($, tk, a);

            uint256 amt = _pull(tk == $.wnative ? C.NATIVE : tk, M.decodeB64(amtB64, a.decimals));

            if (tk == base) {
                baseTotal += amt;
            } else {
                IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, tk, base, amt);
                _exec($, tk, base, amt, q);
                _oracle(q);
                baseTotal += q.amountOut;
            }
            unchecked { ++i; }
        }

        if (baseTotal == 0) revert Err.ZeroValue();

        uint256 wSum;
        for (uint256 j; j < outLen;) {
            address tk; uint16 w; uint64 minB64;
            assembly {
                let packed := calldataload(add(outputs.offset, mul(j, 32)))
                tk := shr(96, packed)
                w := and(shr(80, packed), 0xFFFF)
                minB64 := and(packed, 0xFFFFFFFFFFFFFFFF)
            }
            tk = _wrap($, tk);
            IPool.Asset storage a = $.assets[tk];
            if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tk);

            wSum += w;
            uint256 baseIn = (baseTotal * w) / 10000;

            _checkRisk($, tk, C.SWAP_ENABLED_BIT);
            _applyDecay($, tk, a);

            if (tk == base) {
                amountsOut[j] = baseIn;
            } else {
                IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, base, tk, baseIn);
                _exec($, base, tk, baseIn, q);
                _oracle(q);
                amountsOut[j] = q.amountOut;
            }

            uint256 minOut = M.decodeB64(minB64, a.decimals);
            if (amountsOut[j] < minOut) revert Err.ThresholdViolation(amountsOut[j], minOut);
            unchecked { ++j; }
        }

        if (wSum != 10000) revert Err.InvalidInput();

        for (uint256 j; j < outLen;) {
            address tk;
            assembly { tk := shr(96, calldataload(add(outputs.offset, mul(j, 32)))) }
            tk = _wrap($, tk);
            _push(tk == $.wnative ? C.NATIVE : tk, recipient, amountsOut[j]);
            unchecked { ++j; }
        }

        emit IExchange.BatchSwapped(msg.sender, recipient, inLen, outLen, baseTotal);
    }


    function owner() external view returns (address) { return _s().owner; }
    function baseToken() external view returns (address) { return _s().baseToken; }
    function wnative() external view returns (address) { return _s().wnative; }

    function getAsset(address tk) external view returns (IPool.Asset memory) {
        IPool.PoolStorage storage $ = _s(); return $.assets[_wrap($, tk)];
    }
    function getLPBalance(address u, address tk) external view returns (uint256) {
        IPool.PoolStorage storage $ = _s(); return $.lpBalances[u][_wrap($, tk)];
    }
    function getProtocolFees(address tk) external view returns (uint256) {
        IPool.PoolStorage storage $ = _s(); return $.protocolFees[_wrap($, tk)];
    }
    function getMidPrice(address tk) external returns (uint256) {
        IPool.PoolStorage storage $ = _s();
        return _readOracle($, _wrap($, tk)).lastPriceB64.b64To1e18();
    }


    function _exec(
        IPool.PoolStorage storage $,
        address tkIn,
        address tkOut,
        uint256 amtIn,
        IPool.SwapQuote memory q
    ) private {
        IPool.Asset storage aIn = $.assets[tkIn];
        IPool.Asset storage aOut = $.assets[tkOut];

        // Pre-exec reserve check (protects against hook drains in _postSwap/_reconcile)
        uint256 minReq = q.amountOut + aOut.minLiquidity;
        if (aOut.reserves < minReq) revert Err.InsufficientAmount(aOut.reserves, minReq);

        aIn.reserves += uint128(amtIn - (amtIn * q.spreadBps / 2) / 1_000_000);
        aOut.reserves -= uint128(q.amountOut);
        $.protocolFees[tkOut] += q.protoFee;

        uint64 floor = aOut.reservationPrice;
        if (floor != 0) {
            uint64 price = _readOracle($, tkOut).lastPriceB64;
            if (price < floor) revert Err.PriceBelowReservation(price, floor);
        }
    }

    function _oracle(IPool.SwapQuote memory q) private {
        if (q.routeHops.length < 2 || q.hopPrices.length == 0) return;
        address base = _s().baseToken;

        for (uint256 i; i < q.routeHops.length - 1;) {
            address a = q.routeHops[i];
            address b = q.routeHops[i + 1];
            uint64 p = q.hopPrices[i];

            if (a == base) InternalOracle(address(this)).pushFeedInternal(b, address(0), p, 0);
            else if (b == base) InternalOracle(address(this)).pushFeedInternal(a, address(0), p, 0);
            else InternalOracle(address(this)).pushFeedInternal(a, b, p, p);

            unchecked { ++i; }
        }
    }

    function _runHook(
        IPool.PoolStorage storage $,
        address tk,
        address other,
        uint32 flag,
        bool isPre,
        address tkIn,
        address tkOut,
        uint256 amtIn,
        uint256 amtOutOrFee
    ) private returns (uint256 extraFee, uint16 feeOverride, int256 delta) {
        address h = $.hooks[tk];
        if (h == address(0) || h == other) return (0, 0, 0);
        if (($.hookFlags[tk] & flag) == 0) return (0, 0, 0);

        if (isPre) {
            (uint256 f, uint16 o) = IPoolHooks(h).preSwap(address(this), msg.sender, tkIn, tkOut, amtIn, amtOutOrFee);
            return (f, o, 0);
        }
        return (0, 0, IPoolHooks(h).postSwap(address(this), msg.sender, tkIn, tkOut, amtIn, amtOutOrFee));
    }

    function _preSwap(
        IPool.PoolStorage storage $,
        address tkIn,
        address tkOut,
        uint256 amtIn,
        uint256 amtOut
    ) private returns (uint256 extraFee, uint16 feeOverride) {
        (uint256 f1, uint16 o1, ) = _runHook($, tkIn, address(0), C.HOOK_PRE_SWAP, true, tkIn, tkOut, amtIn, amtOut);
        extraFee += f1;
        if (o1 > 0) feeOverride = o1;
        (uint256 f2, uint16 o2, ) = _runHook($, tkOut, $.hooks[tkIn], C.HOOK_PRE_SWAP, true, tkIn, tkOut, amtIn, amtOut);
        extraFee += f2;
        if (o2 > 0) feeOverride = o2;
    }

    function _postSwap(
        IPool.PoolStorage storage $,
        address tkIn,
        address tkOut,
        uint256 amtIn,
        uint256 amtOut
    ) private returns (int256 delta) {
        (, , int256 d1) = _runHook($, tkIn, address(0), C.HOOK_POST_SWAP, false, tkIn, tkOut, amtIn, amtOut);
        (, , int256 d2) = _runHook($, tkOut, $.hooks[tkIn], C.HOOK_POST_SWAP, false, tkIn, tkOut, amtIn, amtOut);
        return d1 + d2;
    }

    function _applyHookFee(
        IPool.PoolStorage storage $,
        uint256 fee,
        IPool.SwapQuote memory q,
        uint256 out
    ) private view returns (uint256) {
        if (fee == 0) return out;
        (uint256 pf, uint256 lf) = Pricing.splitFee(fee, $.feeParams.protoShare);
        q.protoFee += pf;
        q.lpFee += lf;
        return out > fee ? out - fee : 0;
    }

    function _reconcile(IPool.Asset storage a, uint256 actual, uint256 expected) private {
        if (actual == expected) return;
        uint256 d = actual > expected ? actual - expected : expected - actual;
        if (d > type(uint128).max) revert Err.ExcessiveAmount(d, type(uint128).max);
        if (actual > expected) a.reserves -= uint128(d);
        else a.reserves += uint128(d);
    }
}
