// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IAccessControl — minimal local view of peripheral AccessControl
/// @notice Path α (Phase 42B.1.6) bridge: dex consumes only `owner()` from the singleton AC.
/// @dev    Local to avoid coupling dex to btr-peripheral import surface prematurely
///         (only 1 selector used vs full peripheral surface; less than 3 sites benefit at
///         this stage). Migration to peripheral AccessControl deferred to Path beta when
///         dex consumes the wider AC surface (treasury/swapper/factory/keepers).
interface IAccessControl {
    function owner() external view returns (address);
}
