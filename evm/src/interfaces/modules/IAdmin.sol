// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IAdminConfig} from "./IAdminConfig.sol";
import {IAdminTimelock} from "./IAdminTimelock.sol";

/// @title IAdmin
/// @notice Composite interface — union of IAdminConfig + IAdminTimelock.
/// @dev Kept for backward-compat (IPool inherits IAdmin; external callers use IAdmin(pool)).
interface IAdmin is IAdminConfig, IAdminTimelock {}
