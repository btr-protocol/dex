// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../IPool.sol";

/// @title ILiquidity -backwards-compat alias for root `IPool`
/// @dev Cohort-3 Finding 3 -all liquidity surface lives in root `IPool`. This
///      stub is preserved for off-chain ABI consumers; new code imports `IPool`.
interface ILiquidity is IPool {}
