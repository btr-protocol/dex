// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IPoolV1} from "../IPoolV1.sol";
import {IExchangeV1} from "./IExchangeV1.sol";

/// @title ILiquidityV1
/// @notice Liquidity operations: deposit, withdraw, donate, swapLiability
/// @dev Inherits common view functions from IExchangeV1
interface ILiquidityV1 is IExchangeV1 {
    // ========== WRITE FUNCTIONS ==========

    /// @notice Deposit tokens to receive LP tokens (same token count on withdrawal)
    function deposit(
        address token,
        uint256 amount
    ) external payable returns (IPoolV1.DepositResult memory result);

    /// @notice Withdraw LP tokens for same asset
    function withdraw(
        address token,
        uint256 lpAmount,
        uint256 minAmountOut
    ) external returns (IPoolV1.WithdrawResult memory result);

    /// @notice Withdraw LP tokens for different asset (with swap via ExchangeV1)
    function withdrawTo(
        address tokenFrom,
        address tokenTo,
        uint256 lpAmount,
        uint256 minAmountOut
    ) external returns (IPoolV1.WithdrawResult memory result);

    /// @notice Swap LP tokens between assets (changes liability exposure)
    function swapLiability(
        address tokenIn,
        address tokenOut,
        uint256 lpAmountIn,
        uint256 minLpAmountOut
    ) external returns (uint256 lpAmountOut);

    /// @notice Donate reserves without receiving LP tokens (increases liquidity index)
    function donate(address token, uint256 amount) external payable;

    // ========== EVENTS ==========

    event Deposited(
        address indexed sender,
        address indexed token,
        uint256 amount,
        uint256 lpAmount
    );

    event Withdrawn(
        address indexed sender,
        address indexed token,
        uint256 amount,
        uint256 lpAmount
    );

    event LiabilitySwapped(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 lpAmountIn,
        uint256 lpAmountOut,
        uint256 haircut
    );

    event Donated(
        address indexed sender,
        address indexed token,
        uint256 amount
    );
}
