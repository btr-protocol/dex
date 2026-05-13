// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../IPool.sol";

/// @title IPoolModule -backwards-compat alias for root `IPool`
/// @notice Cohort-3 Finding 3 -all module surface (events, SwapQuote, function
///         sigs) moved into root `interfaces/IPool.sol` as the single canonical
///         declaration. This alias is preserved for off-chain ABI consumers and
///         legacy library imports; new code should import `IPool` directly.
interface IPoolModule is IPool {}
