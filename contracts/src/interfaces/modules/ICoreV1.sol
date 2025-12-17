// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPoolV1} from "../IPoolV1.sol";

/// @title ICore
/// @notice Core AMM operations: deposit, withdraw, swap, liability swap, donate
interface ICoreV1 {
    // Core operations
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient) external payable returns (uint256 amountOut);
    function batchSwap(bytes calldata inputs, bytes calldata outputs, address recipient) external payable returns (uint256[] memory amountsOut);
    function deposit(address token, uint256 amount) external payable returns (IPoolV1.DepositResult memory result);
    function withdraw(address token, uint256 lpAmount, uint256 minAmountOut) external returns (IPoolV1.WithdrawResult memory result);
    function withdrawTo(address tokenFrom, address tokenTo, uint256 lpAmount, uint256 minAmountOut) external returns (IPoolV1.WithdrawResult memory result);
    function swapLiability(address tokenIn, address tokenOut, uint256 lpAmountIn, uint256 minLpAmountOut) external returns (uint256 lpAmountOut);
    function donate(address token, uint256 amount) external payable;

    // View functions
    function owner() external view returns (address);
    function baseToken() external view returns (address);
    function wnative() external view returns (address);
    function getAsset(address token) external view returns (IPoolV1.Asset memory);
    function getFeedConfig(address token) external view returns (IPoolV1.OracleConfig memory);
    function getRiskConfig(address token) external view returns (IPoolV1.RiskConfig memory);
    function getLiquidityProfile(address token) external view returns (IPoolV1.LiquidityProfile memory);
    function getLPBalance(address user, address token) external view returns (uint256);
    function getProtocolFees(address token) external view returns (uint256);
    function getCoverageRatio(address token) external view returns (uint256);
    function getMidPrice(address token) external returns (uint256);
    function getSwapQuote(address tokenIn, address tokenOut, uint256 amountIn) external returns (IPoolV1.SwapQuote memory quote);

    // Events
    event Swapped(address indexed sender, address indexed recipient, address indexed tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint16 spreadBps, uint256 protoFee, uint256 lpFee);
    event BatchSwapped(address indexed sender, address indexed recipient, uint256 inputCount, uint256 outputCount, uint256 totalBaseValue);
    event Deposited(address indexed sender, address indexed token, uint256 amount, uint256 lpAmount);
    event Withdrawn(address indexed sender, address indexed token, uint256 amount, uint256 lpAmount);
    event LiabilitySwapped(address indexed sender, address indexed tokenIn, address indexed tokenOut, uint256 lpAmountIn, uint256 lpAmountOut, uint256 haircut);
    event Donated(address indexed sender, address indexed token, uint256 amount);
}
