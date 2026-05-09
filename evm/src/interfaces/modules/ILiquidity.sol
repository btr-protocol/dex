// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPool} from "../IPool.sol";
import {IExchange} from "./IExchange.sol";

/// @title ILiquidity — deposit/withdraw/donate/swapLiability
interface ILiquidity is IExchange {
    function deposit(address token, uint256 amount)
        external payable returns (IPool.DepositResult memory result);

    function withdraw(address token, uint256 lpAmount, uint256 minAmountOut)
        external returns (IPool.WithdrawResult memory result);

    /// @notice Withdraw LP for different asset (swaps via Exchange)
    function withdrawTo(address tokenFrom, address tokenTo, uint256 lpAmount, uint256 minAmountOut)
        external returns (IPool.WithdrawResult memory result);

    /// @notice Swap LP between assets (changes liability exposure)
    function swapLiability(address tokenIn, address tokenOut, uint256 lpAmountIn, uint256 minLpAmountOut)
        external returns (uint256 lpAmountOut);

    /// @notice Donate reserves w/o LP mint (raises liquidity index)
    function donate(address token, uint256 amount) external payable;

    event Deposited(address indexed sender, address indexed token, uint256 amount, uint256 lpAmount);
    event Withdrawn(address indexed sender, address indexed token, uint256 amount, uint256 lpAmount);
    event LiabilitySwapped(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 lpAmountIn,
        uint256 lpAmountOut,
        uint256 haircut
    );
    event Donated(address indexed sender, address indexed token, uint256 amount);
}
