// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ILiquidity} from "./ILiquidity.sol";

/// @title ICore
/// @notice Core AMM = Exchange + Liquidity
interface ICore is ILiquidity {}
