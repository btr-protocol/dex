// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Constants as C} from "./Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {PoolOracle} from "./PoolOracle.sol";

/// @title PoolIO
/// @notice Shared pool-local token I/O, risk gating, and swap accounting helpers.
library PoolIO {
    function wrap(IPool.PoolStorage storage $, address token) internal view returns (address) {
        return token == SC.NATIVE ? $.wnative : token;
    }

    function _balanceOf(address token) private view returns (uint256) {
        return SafeTransferLib.balanceOf(token, address(this));
    }

    function pull(IPool.PoolStorage storage $, address token, uint256 amount) internal returns (uint256) {
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
        if ((risk.flags & C.FROZEN_BIT) != 0) revert Err.FeatureDisabled(Err.Resource.ASSET);
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

        uint64 floor = aOut.reservationPrice;
        if (floor != 0) {
            uint64 price = PoolOracle.readOracle($, address(this), tkOut).lastPriceB64;
            if (price < floor) revert Err.PriceBelowReservation(price, floor);
        }
    }

    function pushOracle(IPool.PoolStorage storage $, IPool.SwapQuote memory q) internal {
        if (q.routeHops.length < 2 || q.hopPrices.length == 0) return;
        address base = $.baseToken;

        for (uint256 i; i < q.routeHops.length - 1;) {
            address a = q.routeHops[i];
            address b = q.routeHops[i + 1];
            uint64 p = q.hopPrices[i];

            if (p == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }

            if (a == base) PoolOracle.pushFeedInternal($, b, address(0), p, 0);
            else if (b == base) PoolOracle.pushFeedInternal($, a, address(0), p, 0);
            else PoolOracle.pushFeedInternal($, a, b, p, p);

            unchecked {
                ++i;
            }
        }
    }
}
