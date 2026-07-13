// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title IPoolHooks — lean per-asset hooks (void; side-effects only).
/// @notice Venus surface: unified pre-outflow recall + optional postInflow deploy.
///         Flags: `HOOK_PRE_OUTFLOW`, `HOOK_POST_INFLOW` in Constants.
///         Pool dispatches only when `HookSlot.target != 0` and the matching flag is set.
///         Deploy never runs in preOutflow (postInflow and/or keeper-only).
interface IPoolHooks {
    /// @notice Recall invested → liquid when R_liq < amountNeeded (swap-out / withdraw / flash).
    /// @dev Fail-closed at Pool if still short after this CALL. 0 CALL when R_liq covers need.
    function preOutflow(address pool, address sender, address token, uint256 amountNeeded) external;

    /// @notice Optional deploy after deposit (pool pre-approves liquid book; books via Δbalance).
    function postInflow(address pool, address sender, address token, uint256 amountIn, uint256 lpMinted)
        external;
}
