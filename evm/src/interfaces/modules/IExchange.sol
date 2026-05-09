// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPoolModule} from "./IPool.sol";

/// @title IExchange — backwards-compat stub for the merged Pool module
/// @dev After the Liquidity+Exchange → Pool merge, IExchange is preserved as
///      a composite alias of IPoolModule for off-chain consumers (ABIs / SDK).
///      All types, events and functions are inherited from IPoolModule.
interface IExchange is IPoolModule {}
