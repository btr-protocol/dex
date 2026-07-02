// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Maths as M} from "./Maths.sol";
import {PoolDecay} from "./PoolDecay.sol";
import {PoolOracle} from "./PoolOracle.sol";
import {PoolIO} from "./PoolIO.sol";

/// @title PoolEdge -flash/oracle-edge ops extracted from Pool.sol
/// @notice Wave-2 bytecode reduction. Pure refactor; behavior preserved.
///         `external` lib fns DELEGATECALL'd from Pool trampolines (auth +
///         reentrancy enforced at the trampoline).
library PoolEdge {
    using {M.b64To1e18} for uint64;

    function collectProtocolFees(IPool.PoolStorage storage $, address token, address recipient)
        external returns (uint256 amount)
    {
        address t = PoolIO.wrap($, token);
        amount = $.protocolFees[t];
        if (amount > 0) {
            $.protocolFees[t] = 0;
            PoolIO.push($, token, recipient, amount);
        }
    }

function flashSend(IPool.PoolStorage storage $, address token, uint256 amount, address to) external {
        address t = PoolIO.wrap($, token);
        IPool.Asset storage asset = $.assets[t];
        if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
        PoolDecay.applyDecay($, t, asset);
        if (amount == 0) revert Err.ZeroValue();
        if (asset.reserves < amount || asset.reserves - amount < asset.minLiquidity) {
            revert Err.InsufficientAmount(asset.reserves, amount);
        }
        // Block reserve-mutating entrypoints for the flash callback's duration (cleared in
        // flashAccount): a borrower must repay by plain transfer, not by deposit/swap which would
        // double-credit the principal pushed out here without a reserve debit.
        PoolIO.enterFlash();
        PoolIO.push($, token, to, amount);
    }

    function flashAccount(IPool.PoolStorage storage $, address token, uint256 fee, uint256 protoFee) external {
        if (protoFee > fee) revert Err.InvalidInput();
        address t = PoolIO.wrap($, token);
        IPool.Asset storage asset = $.assets[t];
        if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
        unchecked { asset.reserves += uint128(fee - protoFee); }
        $.protocolFees[t] += protoFee;
        PoolIO.exitFlash();
    }

    function updateFeed(
        IPool.PoolStorage storage $,
        address token,
        uint64 initialPrice,
        uint8 accDecimals,
        uint32 fastVolEMA,
        uint32 slowVolEMA
    ) external {
        address t = PoolIO.wrap($, token);
        PoolOracle.initFeed($, t, initialPrice, accDecimals, fastVolEMA, slowVolEMA);
        emit IOracle.OracleUpdated(t, initialPrice, fastVolEMA, slowVolEMA);
    }

    function pokeMidPrice(IPool.PoolStorage storage $, address self, address tk) external returns (uint256) {
        return PoolOracle.readOracle($, self, PoolIO.wrap($, tk)).lastPriceB64.b64To1e18();
    }
}
