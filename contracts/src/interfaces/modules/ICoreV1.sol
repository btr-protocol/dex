// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ILiquidityV1} from "./ILiquidityV1.sol";

/// @title ICoreV1
/// @notice Core AMM operations - combines ExchangeV1 and LiquidityV1
/// @dev This interface consolidates trading and liquidity operations
///      Inherits from ILiquidityV1 which transitively includes IExchangeV1
interface ICoreV1 is ILiquidityV1 {
    // All functions inherited from IExchangeV1 (via ILiquidityV1) and ILiquidityV1
}
