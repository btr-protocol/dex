// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Maths as M} from "./Maths.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {PoolDecay} from "./PoolDecay.sol";
import {PoolOracle} from "./PoolOracle.sol";

/// @title PoolEdge -staking/flash/oracle-edge ops extracted from Pool.sol
/// @notice Wave-2 bytecode reduction. Pure refactor; behavior preserved.
///         `external` lib fns DELEGATECALL'd from Pool trampolines (auth +
///         reentrancy enforced at the trampoline).
library PoolEdge {
    using {M.b64To1e18} for uint64;
    using SafeTransferLib for address;

    function _wrap(IPool.PoolStorage storage $, address token) private view returns (address) {
        return token == SC.NATIVE ? $.wnative : token;
    }

    function _push(IPool.PoolStorage storage $, address token, address to, uint256 amount) private {
        if (token == SC.NATIVE) {
            IWETH9($.wnative).withdraw(amount);
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            SafeTransferLib.safeTransfer(token, to, amount);
        }
    }

    function collectProtocolFees(IPool.PoolStorage storage $, address token, address recipient)
        external returns (uint256 amount)
    {
        address t = _wrap($, token);
        amount = $.protocolFees[t];
        if (amount > 0) {
            $.protocolFees[t] = 0;
            _push($, token, recipient, amount);
        }
    }

function flashSend(IPool.PoolStorage storage $, address token, uint256 amount, address to) external {
        address t = _wrap($, token);
        IPool.Asset storage asset = $.assets[t];
        if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
        PoolDecay.applyDecay($, t, asset);
        if (amount == 0) revert Err.ZeroValue();
        if (asset.reserves < amount || asset.reserves - amount < asset.minLiquidity) {
            revert Err.InsufficientAmount(asset.reserves, amount);
        }
        _push($, token, to, amount);
    }

    function flashAccount(IPool.PoolStorage storage $, address token, uint256 fee, uint256 protoFee) external {
        if (protoFee > fee) revert Err.InvalidInput();
        address t = _wrap($, token);
        IPool.Asset storage asset = $.assets[t];
        if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
        unchecked { asset.reserves += uint128(fee - protoFee); }
        $.protocolFees[t] += protoFee;
    }

    function updateFeed(
        IPool.PoolStorage storage $,
        address token,
        uint64 initialPrice,
        uint8 accDecimals,
        uint32 fastVolEMA,
        uint32 slowVolEMA
    ) external {
        address t = _wrap($, token);
        PoolOracle.initFeed($, t, initialPrice, accDecimals, fastVolEMA, slowVolEMA);
        emit IOracle.OracleUpdated(t, initialPrice, fastVolEMA, slowVolEMA);
    }

    function pokeMidPrice(IPool.PoolStorage storage $, address self, address tk) external returns (uint256) {
        return PoolOracle.readOracle($, self, _wrap($, tk)).lastPriceB64.b64To1e18();
    }
}
