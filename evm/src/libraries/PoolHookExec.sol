// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {IPoolHooks} from "../interfaces/IPoolHooks.sol";
import {Pricing} from "./Pricing.sol";
import {Constants as C} from "./Constants.sol";

/// @title PoolHookExec -hook dispatch logic extracted from Pool.sol
/// @notice Wave-2 bytecode reduction. Behavior-preserving refactor.
///         All fns are `external` so they DELEGATECALL from Pool (Pool stays
///         msg.sender for the hook target via solidity's library DELEGATECALL).
/// @dev    Library `external` fns deploy as a separate runtime contract; Pool's
///         bytecode only carries trampoline JUMP+DELEGATECALL stubs (~25 bytes/fn
///         vs ~250 bytes inlined). Lib state access via the `$` storage ref is
///         transparent because DELEGATECALL preserves Pool's storage context.
library PoolHookExec {
    // Cohort-3 Finding 2 -external `runHook` removed (0 callers; preSwap/postSwap/
    // applyHookFee are the public surface). Intra-library dispatch via
    // `_runHookInternal`.

    /// @dev Run both pre-swap hooks (in-token then out-token, dedup'd).
    function preSwap(
        IPool.PoolStorage storage $,
        address tkIn,
        address tkOut,
        uint256 amtIn,
        uint256 amtOut
    ) external returns (uint256 extraFee, uint16 feeOverride) {
        (uint256 f1, uint16 o1, ) = _runHookInternal($, tkIn, address(0), C.HOOK_PRE_SWAP, true, tkIn, tkOut, amtIn, amtOut);
        extraFee += f1;
        if (o1 > 0) feeOverride = o1;
        (uint256 f2, uint16 o2, ) = _runHookInternal($, tkOut, $.hooks[tkIn], C.HOOK_PRE_SWAP, true, tkIn, tkOut, amtIn, amtOut);
        extraFee += f2;
        if (o2 > 0) feeOverride = o2;
    }

    /// @dev Run both post-swap hooks (in-token then out-token, dedup'd). Returns summed delta.
    function postSwap(
        IPool.PoolStorage storage $,
        address tkIn,
        address tkOut,
        uint256 amtIn,
        uint256 amtOut
    ) external returns (int256) {
        (, , int256 d1) = _runHookInternal($, tkIn, address(0), C.HOOK_POST_SWAP, false, tkIn, tkOut, amtIn, amtOut);
        (, , int256 d2) = _runHookInternal($, tkOut, $.hooks[tkIn], C.HOOK_POST_SWAP, false, tkIn, tkOut, amtIn, amtOut);
        return d1 + d2;
    }

    /// @dev Apply an extra fee from a hook by splitting proto/lp shares.
    ///      Updates `q` in place; returns new `out` (or 0 if fee > out).
    function applyHookFee(
        IPool.PoolStorage storage $,
        uint256 fee,
        IPool.SwapQuote memory q,
        uint256 out
    ) external view returns (uint256) {
        if (fee == 0) return out;
        (uint256 pf, uint256 lf) = Pricing.splitFee(fee, $.feeParams.protoShare);
        q.protoFee += pf;
        q.lpFee += lf;
        return out > fee ? out - fee : 0;
    }

    /// @dev Internal variant for intra-library reuse (no external DELEGATECALL hop).
    function _runHookInternal(
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
}
