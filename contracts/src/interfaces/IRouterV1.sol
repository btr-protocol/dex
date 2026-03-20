// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IExchangeV1} from "./modules/IExchangeV1.sol";

/// @title IRouterV1
/// @notice Stateless router interface for optimal route discovery and execution
/// @dev Router uses factory for registry, delegates swaps to pools directly
interface IRouterV1 {
    // ========== STRUCTS ==========

    /// @notice Route step descriptor
    struct RouteStep {
        address pool;      // Pool to execute swap in
        address tokenIn;   // Input token for this hop
        address tokenOut;  // Output token for this hop
    }

    /// @notice Complete route with quote
    struct Route {
        RouteStep[] steps;      // Individual hops (max 3)
        uint256 amountOut;      // Expected output amount
        uint256 gasEstimate;    // Estimated gas cost
    }

    /// @notice Batch swap input
    struct BatchInput {
        address pool;      // Pool to swap in
        address tokenIn;   // Token to sell
        uint256 amount;    // Amount to swap
    }

    /// @notice Batch swap output
    struct BatchOutput {
        address pool;      // Pool to swap in
        address tokenOut;  // Token to buy
        uint16 weight;     // Weight in basis points (sum must be 10000)
        uint256 minAmount; // Minimum output
    }

    // ========== CONSTANTS ==========

    /// @notice Maximum route hops (3 for optimal gas/security)
    function MAX_HOPS() external view returns (uint8);

    /// @notice Pool proxy factory
    function factory() external view returns (address);

    // ========== INITIALIZATION ==========

    /// @notice Initialize router (one-time, called via proxy)
    /// @param newOwner Owner of the router (DAO)
    /// @param _factory Pool proxy factory address
    function initialize(address newOwner, address _factory) external;

    // ========== SINGLE SWAP ROUTING (VIEW) ==========

    /// @notice Find best route for single token swap
    /// @param tokenIn Input token
    /// @param tokenOut Output token
    /// @param amountIn Input amount
    /// @return route Optimal route (may be single or multi-hop)
    /// @return amountOut Expected output amount
    function getBestRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (Route memory route, uint256 amountOut);

    /// @notice Get best direct quote (single pool only)
    /// @param tokenIn Input token
    /// @param tokenOut Output token
    /// @param amountIn Input amount
    /// @return pool Pool with best direct quote
    /// @return quote Best swap quote
    function getBestDirectQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (address pool, IExchangeV1.SwapQuote memory quote);

    /// @notice Find best 2-hop route
    /// @param tokenIn Input token
    /// @param tokenOut Output token
    /// @param amountIn Input amount
    /// @return route 2-hop route (empty if none found)
    /// @return amountOut Expected output amount
    function getBestTwoHopRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (Route memory route, uint256 amountOut);

    // ========== BATCH SWAP ROUTING (VIEW) ==========

    /// @notice Find best pool for batch swap (single pool with all tokens)
    /// @param inputs Input tokens and amounts
    /// @param outputs Output tokens with weights
    /// @return pool Pool supporting all tokens (address(0) if none)
    /// @return totalBaseValue Total expected base value
    function getBestBatchPool(
        BatchInput[] calldata inputs,
        BatchOutput[] calldata outputs
    ) external view returns (address pool, uint256 totalBaseValue);

    // ========== SWAP EXECUTION ==========

    /// @notice Execute swap along a route
    /// @param route Route to execute
    /// @param amountIn Input amount
    /// @param minAmountOut Minimum output (slippage protection)
    /// @param recipient Final recipient
    /// @return amountOut Actual output amount
    function executeSwap(
        Route calldata route,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external payable returns (uint256 amountOut);

    /// @notice Execute batch swap in a single pool
    /// @param pool Pool to execute batch swap in
    /// @param inputs Packed input array (variable-length encoded)
    /// @param outputs Packed output array (variable-length encoded)
    /// @param recipient Recipient of output tokens
    /// @return amountsOut Array of output amounts
    function executeBatchSwap(
        address pool,
        bytes calldata inputs,
        bytes calldata outputs,
        address recipient
    ) external payable returns (uint256[] memory amountsOut);

    // ========== LEGACY COMPATIBILITY ==========

    /// @notice Get swap quote from a specific pool (delegates to pool)
    function getSwapQuote(address pool, address tokenIn, address tokenOut, uint256 amountIn)
        external returns (IExchangeV1.SwapQuote memory quote);

    // ========== UPGRADE MANAGEMENT ==========

    /// @notice Request contract upgrade (timelocked)
    function requestUpgrade(address implementation) external;

    /// @notice Execute pending upgrade
    function executeUpgrade() external;

    // ========== EVENTS ==========

    /// @notice Emitted when a swap is executed
    event SwapExecuted(
        address indexed sender,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOut,
        uint8 hopCount
    );

    /// @notice Emitted when a batch swap is executed
    event BatchSwapExecuted(
        address indexed sender,
        address indexed recipient,
        address indexed pool,
        uint256 inputCount,
        uint256 outputCount
    );

    /// @notice Emitted when upgrade is requested
    event UpgradeRequested(address indexed implementation, uint256 executeAt);

    /// @notice Emitted when upgrade is executed
    /// @dev Inherited from UUPSUpgradeable - not redeclared here
}
