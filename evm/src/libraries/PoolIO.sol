// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Constants as C} from "./Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Oracle} from "./Oracle.sol";
import {Maths as M} from "./Maths.sol";

/// @title PoolIO
/// @notice Shared pool-local token I/O, risk gating, and swap accounting helpers.
library PoolIO {
    /// @dev Transient "flash in flight" flag (per Pool-clone address, tx-scoped). Set while a flash
    ///      loan's callback runs; blocks every reserve-mutating entrypoint so a borrower cannot
    ///      "repay" via deposit/donate/swap (a reserve-crediting path) and double-count the principal
    ///      that `flashSend` pushed out without debiting reserves. ERC-3156 borrowers repay by plain
    ///      transfer/approve, which is unaffected.
    /// @dev keccak256("btr.pool.flashInFlight.v1") — distinct from Solady's ReentrancyGuard slot.
    uint256 private constant FLASH_INFLIGHT_SLOT =
        0x9b4f3bbfca54a0e6e7a1f989e7a8421747090cf08b7f435d15e27a960bfc0532;

    function enterFlash() internal {
        assembly { tstore(FLASH_INFLIGHT_SLOT, 1) }
    }
    function exitFlash() internal {
        assembly { tstore(FLASH_INFLIGHT_SLOT, 0) }
    }
    function requireNoFlash() internal view {
        uint256 v;
        assembly { v := tload(FLASH_INFLIGHT_SLOT) }
        if (v != 0) revert Err.InvalidState();
    }

    function wrap(IPool.PoolStorage storage $, address token) internal view returns (address) {
        return token == SC.NATIVE ? $.wnative : token;
    }

    function _balanceOf(address token) private view returns (uint256) {
        return SafeTransferLib.balanceOf(token, address(this));
    }

    function pull(IPool.PoolStorage storage $, address token, uint256 amount) internal returns (uint256) {
        // Reserve-crediting inflow chokepoint (deposit/donate/swap/batchSwap). Blocked during a flash
        // callback so a borrower cannot repay by crediting reserves (double-count). Legit ERC-3156
        // repayment is a plain transfer, which never routes through pull.
        requireNoFlash();
        if (token == SC.NATIVE) {
            if (msg.value < amount) revert Err.InsufficientAmount(msg.value, amount);
            IWETH9($.wnative).deposit{value: amount}();
            unchecked {
                uint256 excess = msg.value - amount;
                if (excess > 0) SafeTransferLib.safeTransferETH(msg.sender, excess);
            }
            return amount;
        }

        uint256 balBefore = _balanceOf(token);
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        return _balanceOf(token) - balBefore;
    }

    function push(IPool.PoolStorage storage $, address token, address to, uint256 amount) internal {
        if (token == SC.NATIVE) {
            IWETH9($.wnative).withdraw(amount);
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            SafeTransferLib.safeTransfer(token, to, amount);
        }
    }

    function checkRisk(IPool.PoolStorage storage $, address token, uint16 requiredFlag) internal view {
        IPool.RiskConfig storage risk = $.riskConfigs[token];
        // FROZEN (per-asset risk) OR PROTOCOL_PAUSED (guardian emergency halt) both block the asset.
        // Compile-time const mask ⇒ same single AND+ISZERO as before ⇒ +0 runtime gas, no new SLOAD.
        if ((risk.flags & C.HALT_MASK) != 0) revert Err.FeatureDisabled(Err.Resource.ASSET);
        if (requiredFlag != 0 && (risk.flags & requiredFlag) == 0) {
            if (requiredFlag == C.SWAP_ENABLED_BIT) revert Err.FeatureDisabled(Err.Resource.SWAP);
            if (requiredFlag == C.LIABILITY_SWAP_ENABLED_BIT) revert Err.FeatureDisabled(Err.Resource.LIABILITY_SWAP);
            if (requiredFlag == C.FLASH_ENABLED_BIT) revert Err.FeatureDisabled(Err.Resource.FLASH);
        }
    }

    function exec(
        IPool.PoolStorage storage $,
        address tkIn,
        address tkOut,
        uint256 amtIn,
        IPool.SwapQuote memory q
    ) internal {
        IPool.Asset storage aIn = $.assets[tkIn];
        IPool.Asset storage aOut = $.assets[tkOut];

        uint256 minReq = q.amountOut + q.protoFee + aOut.minLiquidity;
        if (aOut.reserves < minReq) revert Err.InsufficientAmount(aOut.reserves, minReq);

        uint256 inFee = (amtIn * q.spreadBps / 2) / 1_000_000;
        aIn.reserves += uint128(amtIn - inFee);
        $.protocolFees[tkIn] += inFee;
        aOut.reserves -= uint128(q.amountOut + q.protoFee);
        $.protocolFees[tkOut] += q.protoFee;

        _priceBandGuard($, tkOut, aOut);
    }

    /// @dev Depeg guard on the OUTPUT asset's fresh mark: an absolute floor/ceiling (reservationPrice /
    ///      reservationPriceMax) AND an optional feed-relative band (mark within refBandBps of a
    ///      reference feed — e.g. WBTC vs the BTC feed, XAUT vs a gold feed). 0 fields = disabled;
    ///      when none is set we skip the oracle read entirely (the swap-path freshness/confidence gate
    ///      already ran during quoting via Pricing._readOracle).
    function _priceBandGuard(IPool.PoolStorage storage $, address token, IPool.Asset storage a) private view {
        uint64 lo = a.reservationPrice;
        uint64 hi = a.reservationPriceMax;
        IPool.OracleConfig storage oc = $.oracleConfigs[token];
        bool refBand = oc.refFeedId != 0 && oc.refBandBps != 0;
        if (lo == 0 && hi == 0 && !refBand) return;

        uint64 price = IOracle(oc.primary).getFeed(oc.feedId).lastPriceB64;
        if (lo != 0 && price < lo) revert Err.PriceBelowReservation(price, lo);
        if (hi != 0 && price > hi) revert Err.PriceBelowReservation(price, hi);
        if (refBand) {
            uint256 refP = Oracle.mark(IOracle(oc.primary).getFeed(oc.refFeedId));
            uint256 p = M.b64To1e18(price);
            uint256 dev = p > refP ? p - refP : refP - p;
            if (dev * SC.BPS > refP * uint256(oc.refBandBps)) revert Err.PriceBelowReservation(price, uint64(refP));
        }
    }
}
