// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IPoolV1} from "../IPoolV1.sol";

/// @title IExchangeV1
/// @notice Trading operations: swap, batchSwap, quotes
interface IExchangeV1 {
    // ========== WRITE FUNCTIONS ==========

    /// @notice Swap tokenIn for tokenOut with anchor path pricing
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external payable returns (uint256 amountOut);

    /// @notice Multi-input/multi-output batch swap (up to 8 each)
    function batchSwap(
        bytes calldata inputs,
        bytes calldata outputs,
        address recipient
    ) external payable returns (uint256[] memory amountsOut);

    // ========== VIEW FUNCTIONS ==========

    /// @notice Get swap quote without executing
    function getSwapQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external returns (IPoolV1.SwapQuote memory quote);

    /// @notice Get asset configuration
    function getAsset(address token) external view returns (IPoolV1.Asset memory);

    /// @notice Get oracle feed configuration
    function getFeedConfig(address token) external view returns (IPoolV1.OracleConfig memory);

    /// @notice Get risk configuration
    function getRiskConfig(address token) external view returns (IPoolV1.RiskConfig memory);

    /// @notice Get liquidity profile
    function getLiquidityProfile(address token) external view returns (IPoolV1.LiquidityProfile memory);

    /// @notice Get LP token balance
    function getLPBalance(address user, address token) external view returns (uint256);

    /// @notice Get accumulated protocol fees
    function getProtocolFees(address token) external view returns (uint256);

    /// @notice Get coverage ratio (reserves/liabilities * 1e18)
    function getCoverageRatio(address token) external view returns (uint256);

    /// @notice Get current mid price from oracle
    function getMidPrice(address token) external returns (uint256);

    /// @notice Pool owner
    function owner() external view returns (address);

    /// @notice Base token address
    function baseToken() external view returns (address);

    /// @notice Wrapped native token address
    function wnative() external view returns (address);

    // ========== EVENTS ==========

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
}
