// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPool
/// @notice Interface for Aave V3 Pool
/// @dev Minimal interface for supply and withdraw operations
interface IPool {
    /// @notice Supplies an amount of underlying asset to the pool
    /// @param asset The address of the underlying asset to supply
    /// @param amount The amount to be supplied
    /// @param onBehalfOf The address that will receive the aTokens
    /// @param referralCode Code used to register the integrator originating the operation, for potential rewards
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Withdraws an amount of underlying asset from the pool
    /// @param asset The address of the underlying asset to withdraw
    /// @param amount The underlying amount to be withdrawn
    /// @param to The address that will receive the underlying
    /// @return The final amount withdrawn
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
