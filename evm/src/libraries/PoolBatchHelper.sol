// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {PoolIO} from "./PoolIO.sol";

/// @title PoolBatchHelper -external helpers for PoolBatch (bytecode reduction)
/// @notice Phase 42L Pass-46A. Public lib fns → DELEGATECALL'd by PoolBatch
///         (which is itself DELEGATECALL'd from Pool). Storage context preserved
///         through the chain. Pure refactor; behavior identical.
library PoolBatchHelper {
    function pull(IPool.PoolStorage storage $, address token, uint256 amount) public returns (uint256) {
        return PoolIO.pull($, token, amount);
    }

    function push(IPool.PoolStorage storage $, address token, address to, uint256 amount) public {
        PoolIO.push($, token, to, amount);
    }

    function checkRisk(IPool.PoolStorage storage $, address token, uint16 requiredFlag) public view {
        PoolIO.checkRisk($, token, requiredFlag);
    }

    function exec(
        IPool.PoolStorage storage $,
        address tkIn,
        address tkOut,
        uint256 amtIn,
        IPool.SwapQuote memory q
    ) public {
        PoolIO.exec($, tkIn, tkOut, amtIn, q);
    }

    function pushOracle(IPool.PoolStorage storage $, IPool.SwapQuote memory q) public {
        PoolIO.pushOracle($, q);
    }
}
