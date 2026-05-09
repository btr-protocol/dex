// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPool} from "../IPool.sol";

/// @title IPoolModule — merged Liquidity + Exchange module interface
/// @notice Combined module-level surface replacing IExchange + ILiquidity.
///         Named IPoolModule (not IPool) to avoid clashing with the aggregate
///         IPool interface at interfaces/IPool.sol. Off-chain consumers can
///         keep using IExchange / ILiquidity (composite stubs `is IPoolModule`).
interface IPoolModule {
    // ─── Exchange types & events ───
    struct SwapQuote {
        uint256 amountOut;
        uint256 amountIn;
        uint16 spreadBps;
        uint256 protoFee;
        uint256 lpFee;
        int8 skewIn;
        int8 skewOut;
        address[] routeHops;
        uint256[] hopAmounts;
        uint64[] hopPrices;
    }

    event Swapped(
        address indexed sender,
        address indexed recipient,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint16 spreadBps,
        uint256 protoFee,
        uint256 lpFee
    );

    event BatchSwapped(
        address indexed sender,
        address indexed recipient,
        uint256 inputCount,
        uint256 outputCount,
        uint256 totalBaseValue
    );

    // ─── Liquidity events ───
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

    // ─── Exchange functions ───
    function owner() external view returns (address);
    function baseToken() external view returns (address);
    function wnative() external view returns (address);
    function getAsset(address token) external view returns (IPool.Asset memory);
    function getRiskConfig(address token) external view returns (IPool.RiskConfig memory);
    function getLPBalance(address user, address token) external view returns (uint256);
    function getCoverageRatio(address token) external view returns (uint256);

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external payable returns (uint256 amountOut);

    /// @notice Batch swap (≤8 in, ≤8 out)
    function batchSwap(bytes calldata inputs, bytes calldata outputs, address recipient)
        external payable returns (uint256[] memory amountsOut);

    function getSwapQuote(address tokenIn, address tokenOut, uint256 amountIn)
        external view returns (SwapQuote memory quote);

    function getFeedConfig(address token) external view returns (IPool.OracleConfig memory);
    function getLiquidityProfile(address token) external view returns (IPool.LiquidityProfile memory);
    function getProtocolFees(address token) external view returns (uint256);
    function getMidPrice(address token) external view returns (uint256);

    // ─── Liquidity functions ───
    function deposit(address token, uint256 amount)
        external payable returns (IPool.DepositResult memory result);

    function withdraw(address token, uint256 lpAmount, uint256 minAmountOut)
        external returns (IPool.WithdrawResult memory result);

    /// @notice Withdraw LP for different asset (swaps via internal quote)
    function withdrawTo(address tokenFrom, address tokenTo, uint256 lpAmount, uint256 minAmountOut)
        external returns (IPool.WithdrawResult memory result);

    /// @notice Swap LP between assets (changes liability exposure)
    function swapLiability(address tokenIn, address tokenOut, uint256 lpAmountIn, uint256 minLpAmountOut)
        external returns (uint256 lpAmountOut);

    /// @notice Donate reserves w/o LP mint (raises liquidity index)
    function donate(address token, uint256 amount) external payable;
}
