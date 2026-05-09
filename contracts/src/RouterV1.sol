// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IRouterV1} from "./interfaces/IRouterV1.sol";
import {IPoolProxyFactoryV1} from "./interfaces/IPoolProxyFactoryV1.sol";
import {IExchangeV1} from "./interfaces/modules/IExchangeV1.sol";
import {Err} from "./Errors.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LibTimelock as TL} from "./libraries/LibTimelock.sol";
import {LibConstants as C} from "./libraries/LibConstants.sol";

/// @title RouterV1
/// @notice Stateless router for optimal route discovery and execution
/// @dev Uses factory for registry, delegates swaps to pools directly. Minimal storage, UUPS upgradeable.
contract RouterV1 is IRouterV1, Ownable, ReentrancyGuard, UUPSUpgradeable {
    using SafeTransferLib for address;

    // ========== CONSTANTS ==========

    /// @notice Maximum route hops (gas vs optimal path tradeoff)
    uint8 public constant MAX_HOPS = 3;

    /// @notice Special marker for ETH (zero address)
    address internal constant ETH = address(0);

    // ========== STORAGE (MINIMAL) ==========

    /// @notice Pool proxy factory (immutable after init)
    address public override factory;

    /// @notice Pending upgrade state
    uint96 public pendingUpgradeOp;
    bytes32 public pendingUpgradeId;
    address public pendingImplementation;

    // ========== INITIALIZATION ==========

    /// @notice Initialize router (one-time, called via proxy)
    /// @param newOwner Owner of the router (DAO)
    /// @param _factory Pool proxy factory address
    function initialize(address newOwner, address _factory) external {
        // Ensure initialize is only called once
        if (factory != address(0)) revert Err.InvalidState();
        if (_factory == address(0)) revert Err.ZeroValue();

        factory = _factory;
        _initializeOwner(newOwner);
    }

    // ========== CONSTRUCTOR (for UUPS) ==========

    constructor() {
        // Empty constructor for UUPS implementation
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Find best route for single token swap (1, 2, or 3 hops)
    function getBestRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view override returns (Route memory route, uint256 amountOut) {
        // 1. Try direct routes (pools with both tokens)
        (address bestDirectPool, IExchangeV1.SwapQuote memory bestDirectQuote) =
            _getBestDirectQuote(tokenIn, tokenOut, amountIn);

        route.amountOut = bestDirectQuote.amountOut;
        route.gasEstimate = 150000; // Estimate for single swap

        if (bestDirectPool != address(0)) {
            route.steps = new RouteStep[](1);
            route.steps[0] = RouteStep({
                pool: bestDirectPool,
                tokenIn: tokenIn,
                tokenOut: tokenOut
            });
        }

        // 2. Try 2-hop routes
        (Route memory twoHopRoute, uint256 twoHopOutput) =
            _getBestTwoHopRoute(tokenIn, tokenOut, amountIn);

        // Use 2-hop only if significantly better (5% threshold to account for gas)
        if (twoHopOutput > route.amountOut && twoHopOutput * 100 > route.amountOut * 105) {
            route = twoHopRoute;
            route.gasEstimate = 300000;
        }

        // 3. Try 3-hop routes only if no better option found
        if (route.amountOut == 0) {
            (Route memory threeHopRoute, uint256 threeHopOutput) =
                _getBestThreeHopRoute(tokenIn, tokenOut, amountIn);

            if (threeHopOutput > 0) {
                route = threeHopRoute;
                route.gasEstimate = 450000;
            }
        }

        amountOut = route.amountOut;
    }

    /// @notice Get best direct quote (single pool only)
    function getBestDirectQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view override returns (address pool, IExchangeV1.SwapQuote memory quote) {
        return _getBestDirectQuote(tokenIn, tokenOut, amountIn);
    }

    /// @notice Find best 2-hop route
    function getBestTwoHopRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view override returns (Route memory route, uint256 amountOut) {
        return _getBestTwoHopRoute(tokenIn, tokenOut, amountIn);
    }

    /// @notice Internal: Get best direct quote from pools with both tokens
    function _getBestDirectQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (address pool, IExchangeV1.SwapQuote memory quote) {
        IPoolProxyFactoryV1 f = IPoolProxyFactoryV1(factory);

        // Get official pools that have both tokens
        address[] memory commonPools = f.getCommonPools(tokenIn, tokenOut);

        uint256 bestAmountOut = 0;

        for (uint256 i = 0; i < commonPools.length; i++) {
            // Only consider official pools
            if (!f.isOfficialPool(commonPools[i])) continue;

            try IExchangeV1(commonPools[i]).getSwapQuote(tokenIn, tokenOut, amountIn)
                returns (IExchangeV1.SwapQuote memory poolQuote)
            {
                if (poolQuote.amountOut > bestAmountOut) {
                    bestAmountOut = poolQuote.amountOut;
                    pool = commonPools[i];
                    quote = poolQuote;
                }
            } catch {}
        }
    }

    /// @notice Internal: Find best 2-hop route (tokenA → intermediate → tokenB)
    function _getBestTwoHopRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (Route memory route, uint256) {
        IPoolProxyFactoryV1 f = IPoolProxyFactoryV1(factory);

        // Get official pools for each token
        uint256 officialCount = f.getOfficialPoolsCount();

        uint256 bestAmountOut = 0;
        address bestIntermediate = address(0);
        address bestPoolIn = address(0);
        address bestPoolOut = address(0);

        // For each pool with input token
        for (uint256 i = 0; i < officialCount; i++) {
            address poolIn = f.officialPools(i);
            if (!f.tokenInPool(tokenIn, poolIn)) continue;

            // Get tokens in this pool (potential intermediates)
            address[] memory poolTokens = f.getPoolTokens(poolIn);

            // For each potential intermediate
            for (uint256 j = 0; j < poolTokens.length; j++) {
                address intermediate = poolTokens[j];

                // Skip if same as input/output or not in any output pool
                if (intermediate == tokenIn || intermediate == tokenOut) continue;

                // Find best output pool for intermediate→tokenOut
                address poolOut = _findBestPoolForPair(intermediate, tokenOut, officialCount);
                if (poolOut == address(0)) continue;

                // Quote first hop
                uint256 hop1AmountOut;
                try IExchangeV1(poolIn).getSwapQuote(tokenIn, intermediate, amountIn)
                    returns (IExchangeV1.SwapQuote memory quote1)
                {
                    hop1AmountOut = quote1.amountOut;
                } catch { continue; }

                // Quote second hop
                uint256 hop2AmountOut;
                try IExchangeV1(poolOut).getSwapQuote(intermediate, tokenOut, hop1AmountOut)
                    returns (IExchangeV1.SwapQuote memory quote2)
                {
                    hop2AmountOut = quote2.amountOut;
                } catch { continue; }

                if (hop2AmountOut > bestAmountOut) {
                    bestAmountOut = hop2AmountOut;
                    bestIntermediate = intermediate;
                    bestPoolIn = poolIn;
                    bestPoolOut = poolOut;
                }
            }
        }

        route;
        if (bestAmountOut > 0) {
            route.steps = new RouteStep[](2);
            route.steps[0] = RouteStep({
                pool: bestPoolIn,
                tokenIn: tokenIn,
                tokenOut: bestIntermediate
            });
            route.steps[1] = RouteStep({
                pool: bestPoolOut,
                tokenIn: bestIntermediate,
                tokenOut: tokenOut
            });
            route.amountOut = bestAmountOut;
            route.gasEstimate = 300000;
        }

        return (route, bestAmountOut);
    }

    /// @notice Internal: Find best 3-hop route (fallback only)
    function _getBestThreeHopRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (Route memory route, uint256) {
        IPoolProxyFactoryV1 f = IPoolProxyFactoryV1(factory);
        uint256 officialCount = f.getOfficialPoolsCount();

        // Collect unique base tokens as potential intermediates
        address[] memory baseTokens = new address[](officialCount);
        uint256 baseCount = 0;

        for (uint256 i = 0; i < officialCount; i++) {
            address baseToken = f.poolBaseTokens(f.officialPools(i));
            if (baseToken != address(0) && !_contains(baseTokens, baseCount, baseToken)) {
                baseTokens[baseCount++] = baseToken;
            }
        }

        uint256 bestAmountOut = 0;

        // Try each pair of base tokens as intermediates
        for (uint256 i = 0; i < baseCount; i++) {
            for (uint256 j = 0; j < baseCount; j++) {
                if (i == j) continue;

                address base1 = baseTokens[i];
                address base2 = baseTokens[j];

                address pool1 = _findBestPoolForPair(tokenIn, base1, officialCount);
                if (pool1 == address(0)) continue;

                address pool2 = _findBestPoolForPair(base1, base2, officialCount);
                if (pool2 == address(0)) continue;

                address pool3 = _findBestPoolForPair(base2, tokenOut, officialCount);
                if (pool3 == address(0)) continue;

                // Quote the full route
                uint256 amt2;
                uint256 amt3;

                try IExchangeV1(pool1).getSwapQuote(tokenIn, base1, amountIn)
                    returns (IExchangeV1.SwapQuote memory q1)
                {
                    amt2 = q1.amountOut;
                } catch { continue; }

                try IExchangeV1(pool2).getSwapQuote(base1, base2, amt2)
                    returns (IExchangeV1.SwapQuote memory q2)
                {
                    amt3 = q2.amountOut;
                } catch { continue; }

                try IExchangeV1(pool3).getSwapQuote(base2, tokenOut, amt3)
                    returns (IExchangeV1.SwapQuote memory q3)
                {
                    if (q3.amountOut > bestAmountOut) {
                        bestAmountOut = q3.amountOut;
                        route.steps = new RouteStep[](3);
                        route.steps[0] = RouteStep({
                            pool: pool1,
                            tokenIn: tokenIn,
                            tokenOut: base1
                        });
                        route.steps[1] = RouteStep({
                            pool: pool2,
                            tokenIn: base1,
                            tokenOut: base2
                        });
                        route.steps[2] = RouteStep({
                            pool: pool3,
                            tokenIn: base2,
                            tokenOut: tokenOut
                        });
                        route.amountOut = bestAmountOut;
                        route.gasEstimate = 450000;
                    }
                } catch { continue; }
            }
        }

        return (route, bestAmountOut);
    }

    /// @notice Internal helper: find best pool for a token pair from official pools
    function _findBestPoolForPair(
        address tokenA,
        address tokenB,
        uint256 officialCount
    ) internal view returns (address) {
        IPoolProxyFactoryV1 f = IPoolProxyFactoryV1(factory);

        uint256 bestAmountOut = 0;
        address bestPool = address(0);

        for (uint256 i = 0; i < officialCount; i++) {
            address pool = f.officialPools(i);
            if (!f.tokenInPool(tokenA, pool)) continue;
            if (!f.tokenInPool(tokenB, pool)) continue;

            try IExchangeV1(pool).getSwapQuote(tokenA, tokenB, 1e18)
                returns (IExchangeV1.SwapQuote memory quote)
            {
                if (quote.amountOut > bestAmountOut) {
                    bestAmountOut = quote.amountOut;
                    bestPool = pool;
                }
            } catch {}
        }

        return bestPool;
    }

    /// @notice Internal helper: check if array contains address (up to count)
    function _contains(address[] memory arr, uint256 count, address value) internal pure returns (bool) {
        for (uint256 i = 0; i < count; i++) {
            if (arr[i] == value) return true;
        }
        return false;
    }

    // ========== BATCH SWAP VIEW ==========

    /// @notice Find best pool for batch swap (single pool with all tokens)
    function getBestBatchPool(
        BatchInput[] calldata inputs,
        BatchOutput[] calldata outputs
    ) external view override returns (address pool, uint256 totalBaseValue) {
        IPoolProxyFactoryV1 f = IPoolProxyFactoryV1(factory);
        uint256 officialCount = f.getOfficialPoolsCount();

        // Find pools that have all input and output tokens
        for (uint256 i = 0; i < officialCount; i++) {
            address candidatePool = f.officialPools(i);
            bool hasAllTokens = true;

            // Check all inputs
            for (uint256 j = 0; j < inputs.length; j++) {
                if (!f.tokenInPool(inputs[j].tokenIn, candidatePool)) {
                    hasAllTokens = false;
                    break;
                }
            }
            if (!hasAllTokens) continue;

            // Check all outputs
            for (uint256 j = 0; j < outputs.length; j++) {
                if (!f.tokenInPool(outputs[j].tokenOut, candidatePool)) {
                    hasAllTokens = false;
                    break;
                }
            }
            if (!hasAllTokens) continue;

            // This pool supports all tokens - return it
            return (candidatePool, 0); // totalBaseValue would require quoting
        }

        return (address(0), 0);
    }

    // ========== SWAP EXECUTION ==========

    /// @notice Execute swap along a route
    function executeSwap(
        Route calldata route,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external payable override nonReentrant returns (uint256 amountOut) {
        if (route.steps.length == 0) revert Err.InvalidInput();
        if (route.steps.length > MAX_HOPS) revert Err.InvalidInput();

        // Transfer input tokens
        RouteStep memory firstStep = route.steps[0];
        _transferIn(firstStep.tokenIn, amountIn);

        // Execute each hop
        uint256 currentAmount = amountIn;
        address currentToken = firstStep.tokenIn;

        for (uint256 i = 0; i < route.steps.length; i++) {
            RouteStep memory step = route.steps[i];

            // Approve pool if needed (ERC20)
            if (currentToken != ETH) {
                currentToken.safeApprove(step.pool, currentAmount);
            }

            // Execute swap
            uint256 hopOutput;
            if (currentToken == ETH || step.pool == address(0)) {
                // Native input
                hopOutput = IExchangeV1(step.pool).swap{value: currentAmount}(
                    currentToken,
                    step.tokenOut,
                    currentAmount,
                    0, // minAmountOut (checked at end)
                    address(this) // Router holds intermediate tokens
                );
            } else {
                hopOutput = IExchangeV1(step.pool).swap(
                    currentToken,
                    step.tokenOut,
                    currentAmount,
                    0, // minAmountOut (checked at end)
                    address(this)
                );
            }

            currentAmount = hopOutput;
            currentToken = step.tokenOut;
        }

        amountOut = currentAmount;

        require(amountOut >= minAmountOut, "Slippage exceeded");

        // Transfer output to recipient
        _transferOut(currentToken, amountOut, recipient);

        emit SwapExecuted(msg.sender, recipient, amountIn, amountOut, uint8(route.steps.length));
    }

    /// @notice Execute batch swap in a single pool
    function executeBatchSwap(
        address pool,
        bytes calldata inputs,
        bytes calldata outputs,
        address recipient
    ) external payable override nonReentrant returns (uint256[] memory amountsOut) {
        if (pool == address(0)) revert Err.ZeroValue();
        if (!IPoolProxyFactoryV1(factory).isPool(pool)) revert Ownable.Unauthorized();

        // Delegate to pool's batch swap
        amountsOut = IExchangeV1(pool).batchSwap{value: msg.value}(
            inputs,
            outputs,
            recipient
        );

        emit BatchSwapExecuted(msg.sender, recipient, pool, inputs.length / 32, outputs.length / 32);
    }

    // ========== LEGACY COMPATIBILITY ==========

    /// @notice Get swap quote from a specific pool (delegates to pool)
    function getSwapQuote(address pool, address tokenIn, address tokenOut, uint256 amountIn)
        external override returns (IExchangeV1.SwapQuote memory quote)
    {
        return IExchangeV1(pool).getSwapQuote(tokenIn, tokenOut, amountIn);
    }

    // ========== INTERNAL HELPERS ==========

    function _transferIn(address token, uint256 amount) internal {
        if (token == ETH) {
            require(msg.value == amount, "Wrong ETH amount");
        } else {
            token.safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function _transferOut(address token, uint256 amount, address recipient) internal {
        if (token == ETH) {
            recipient.safeTransferETH(amount);
        } else {
            token.safeTransfer(recipient, amount);
        }
    }

    // ========== UPGRADE MANAGEMENT ==========

    /// @notice Request contract upgrade (timelocked)
    function requestUpgrade(address implementation) external override onlyOwner {
        if (implementation == address(0)) revert Err.ZeroValue();
        if (pendingUpgradeOp != 0) revert Err.PendingTimelock(uint48(block.timestamp));

        pendingUpgradeId = keccak256(abi.encode(implementation, block.timestamp));
        pendingImplementation = implementation;
        pendingUpgradeOp = TL.pack(C.UPGRADE_TIMELOCK, C.GRACE_PERIOD);

        emit UpgradeRequested(implementation, uint48(pendingUpgradeOp >> 48));
    }

    /// @notice Execute pending upgrade
    function executeUpgrade() external override {
        TL.validate(pendingUpgradeOp);

        address newImpl = pendingImplementation;
        bytes32 upgradeId = pendingUpgradeId;

        delete pendingUpgradeId;
        delete pendingImplementation;
        delete pendingUpgradeOp;

        this.upgradeToAndCall(newImpl, "");
        emit Upgraded(newImpl);
    }

    /// @notice Cancel pending upgrade
    function cancelUpgrade() external onlyOwner {
        if (pendingUpgradeOp == 0) revert Err.InvalidState();

        delete pendingUpgradeId;
        delete pendingImplementation;
        delete pendingUpgradeOp;
    }

    /// @notice UUPS upgrade authorization
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
