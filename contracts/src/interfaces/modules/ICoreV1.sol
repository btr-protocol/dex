// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IPoolV1} from "../IPoolV1.sol";
import {IExchangeV1} from "./IExchangeV1.sol";
import {ILiquidityV1} from "./ILiquidityV1.sol";

/// @title ICoreV1
/// @notice Core AMM operations - combines ExchangeV1 and LiquidityV1
/// @dev This interface consolidates trading and liquidity operations
interface ICoreV1 is IExchangeV1, ILiquidityV1 {
    // All functions inherited from IExchangeV1 and ILiquidityV1
}
