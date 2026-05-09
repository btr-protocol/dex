// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPool} from "../IPool.sol";

/// @title IExchange — swap, batchSwap, quotes
interface IExchange {
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
