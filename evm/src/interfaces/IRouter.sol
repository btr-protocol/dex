// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IExchange} from "./modules/IExchange.sol";

/// @title IRouter -stateless router, route discovery + execution
interface IRouter {
    struct RouteStep { address pool; address tokenIn; address tokenOut; uint256 minOut; }
    struct Route { RouteStep[] steps; uint256 amountOut; uint256 gasEstimate; }
    struct BatchInput { address pool; address tokenIn; uint256 amount; }

    /// @dev weight in BPS, sum must = 10000
    struct BatchOutput { address pool; address tokenOut; uint16 weight; uint256 minAmount; }

    function MAX_HOPS() external view returns (uint8);
    function factory() external view returns (address);

    function initialize(address _factory) external;

    function getBestRoute(address tokenIn, address tokenOut, uint256 amountIn)
        external view returns (Route memory route, uint256 amountOut);

    function getBestDirectQuote(address tokenIn, address tokenOut, uint256 amountIn)
        external view returns (address pool, IExchange.SwapQuote memory quote);

    function getBestTwoHopRoute(address tokenIn, address tokenOut, uint256 amountIn)
        external view returns (Route memory route, uint256 amountOut);

    function getBestBatchPool(BatchInput[] calldata inputs, BatchOutput[] calldata outputs)
        external view returns (address pool, uint256 totalBaseValue);

    function executeSwap(Route calldata route, uint256 amountIn, uint256 minAmountOut, address recipient)
        external payable returns (uint256 amountOut);

    function executeBatchSwap(address pool, bytes calldata inputs, bytes calldata outputs, address recipient)
        external payable returns (uint256[] memory amountsOut);

    function getSwapQuote(address pool, address tokenIn, address tokenOut, uint256 amountIn)
        external view returns (IExchange.SwapQuote memory quote);

    function requestUpgrade(address implementation) external;
    function executeUpgrade() external;

    event SwapExecuted(address indexed sender, address indexed recipient, uint256 amountIn, uint256 amountOut, uint8 hopCount);
    event BatchSwapExecuted(address indexed sender, address indexed recipient, address indexed pool, uint256 inputCount, uint256 outputCount);
    event UpgradeRequested(address indexed implementation, uint256 executeAt);
}
