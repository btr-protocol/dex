# Factory and Routing Architecture Design

## Overview

This document describes the factory-based architecture for pool deployment and the routing system for single and multi-token swaps.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         DEPLOYMENT ARCHITECTURE                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────────┐    CREATE3    ┌──────────────────────────────────┐   │
│  │ PoolProxyFactory │ ◄─────────────┤   Deterministic Deployer         │   │
│  │  (Non-upgradeable)│               │   (singleton, deterministic)     │   │
│  └────────┬─────────┘                └──────────────────────────────────┘   │
│           │                                                                │
│           │ delegates to                                                    │
│           ▼                                                                │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    Reference Pool Implementation                     │   │
│  │                         (Upgradeable, Timelocked)                    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│           │                                                                │
│           │ clones via minimal proxy (CREATE2)                            │
│           ▼                                                                │
│  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐     │
│  │ PoolProxy #1     │    │ PoolProxy #2     │    │ PoolProxy #N     │     │
│  │ (Official Pool)  │    │ (Official Pool)  │    │ (User Pool)      │     │
│  └──────────────────┘    └──────────────────┘    └──────────────────┘     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                            ROUTING ARCHITECTURE                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         RouterV1 (Stateless)                        │   │
│  │                                                                      │   │
│  │  ┌──────────────────────────────────────────────────────────────┐  │   │
│  │  │                    View Functions Only                       │  │   │
│  │  │                                                              │  │   │
│  │  │  • getBestRoute(tokenIn, tokenOut, amountIn)                │  │   │
│  │  │  • getBestBatchRoute(tokensIn[], tokensOut[], amountsIn[])   │  │   │
│  │  │  • getSwapQuote(pool, ...) → delegates to pool              │  │   │
│  │  └──────────────────────────────────────────────────────────────┘  │   │
│  │                             │                                      │   │
│  │                             ▼                                      │   │
│  │  ┌──────────────────────────────────────────────────────────────┐  │   │
│  │  │                    Execution Functions                       │  │   │
│  │  │                                                              │  │   │
│  │  │  • swap(route, amountIn, minAmountOut, recipient)            │  │   │
│  │  │  • swapMultiHop(route[], amountIn, minAmountOut, recipient)  │  │   │
│  │  │  • batchSwap(pool, inputs, outputs, recipient)               │  │   │
│  │  └──────────────────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                         │
│                                    │ queries                                 │
│                                    ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                       PoolProxyFactory                               │   │
│  │                                                                      │   │
│  │  Token Registry:                                                     │   │
│  │  • tokenToPools[token][] → pools supporting this token               │   │
│  │  • poolToTokens[pool][] → tokens supported by this pool               │   │
│  │  • officialPools[] → whitelisted protocol pools                       │   │
│  │                                                                      │   │
│  │  View Functions:                                                     │   │
│  │  • getPoolsForToken(token) → address[]                               │   │
│  │  • getCommonPools(tokenA, tokenB) → address[]                        │   │
│  │  • isOfficialPool(pool) → bool                                       │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 1. PoolProxyFactory Design

### 1.1 Core Interface

```solidity
/// @title PoolProxyFactory
/// @notice Non-upgradeable factory for deploying pool proxies with token registry
/// @dev Deployed deterministically via CREATE3, owns registry of all pools
contract PoolProxyFactory is Ownable {
    // ========== CONSTANTS ==========

    /// @notice Minimum delay between reference implementation upgrades
    uint256 constant UPGRADE_TIMELOCK = 7 days;

    /// @notice Special marker for ETH (zero address in token registries)
    address constant ETH = address(0);

    // ========== STATE ==========

    /// @notice Reference implementation for pool proxies
    address public referencePool;

    /// @notice Timelocked pending reference implementation
    address public pendingReferencePool;
    uint256 public upgradeTimelock;

    /// @notice Protocol deployer (their pools are auto-whitelisted)
    address public protocolDeployer;

    /// @notice All deployed pools (including user-deployed)
    address[] public allPools;
    mapping(address => bool) public isPool;

    /// @notice Official protocol pools (whitelisted for routing)
    address[] public officialPools;
    mapping(address => bool) public isOfficialPool;

    // ========== TOKEN REGISTRY ==========

    /// @notice Mapping of token → pools that support it
    /// @dev Enables O(1) lookup of which pools trade a token
    mapping(address => address[]) public tokenToPools;

    /// @notice Mapping of pool → tokens it supports
    /// @dev Enables iteration over a pool's supported tokens
    mapping(address => address[]) public poolToTokens;

    /// @notice Bidirectional presence checks for array management
    mapping(address => mapping(address => bool)) public tokenInPool;
    mapping(address => mapping(address => bool)) public poolInToken;

    /// @notice Pool base tokens (for routing optimization)
    mapping(address => address) public poolBaseTokens;

    // ========== EVENTS ==========

    event PoolCreated(
        address indexed pool,
        address indexed creator,
        address baseToken,
        bool official
    );

    event TokensRegistered(
        address indexed pool,
        address[] tokens
    );

    event ReferencePoolUpgradeRequested(
        address oldImplementation,
        address newImplementation,
        uint256 executeAt
    );

    event ReferencePoolUpgraded(
        address oldImplementation,
        address newImplementation
    );

    event ProtocolDeployerUpdated(address oldDeployer, address newDeployer);

    // ========== INITIALIZATION ==========

    constructor(address _referencePool, address _protocolDeployer) {
        referencePool = _referencePool;
        protocolDeployer = _protocolDeployer;
    }

    // ========== POOL DEPLOYMENT ==========

    /// @notice Deploy a new pool proxy with initial token configuration
    /// @param baseToken Pool's base token (price anchor)
    /// @param tokens Initial tokens to support
    /// @param initdata Initialization calldata for pool
    /// @return pool The deployed proxy address
    function createPool(
        address baseToken,
        address[] calldata tokens,
        bytes calldata initdata
    ) external returns (address pool) {
        // Deploy minimal proxy pointing to reference implementation
        bytes memory bytecode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            referencePool,
            hex"5af43d82803e903d91602b57fd5bf3"
        );

        bytes32 salt = keccak256(
            abi.encodePacked(
                msg.sender,
                baseToken,
                keccak256(abi.encode(tokens)),
                block.chainid
            )
        );

        assembly {
            pool := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        // Initialize the pool
        (bool success, ) = pool.call(initdata);
        require(success, "Pool init failed");

        // Register pool
        _registerPool(pool, msg.sender, baseToken, tokens);
    }

    // ========== REGISTRY MANAGEMENT ==========

    /// @notice Register tokens for a pool (called by pool itself during asset addition)
    /// @dev Only callable by the pool to ensure sync with actual pool state
    function registerTokens(address[] calldata tokens) external {
        require(isPool[msg.sender], "Not a pool");
        _addTokens(msg.sender, tokens);
        emit TokensRegistered(msg.sender, tokens);
    }

    /// @notice Internal registration logic
    function _registerPool(
        address pool,
        address creator,
        address baseToken,
        address[] memory tokens
    ) internal {
        isPool[pool] = true;
        allPools.push(pool);
        poolBaseTokens[pool] = baseToken;

        bool official = (creator == protocolDeployer);
        if (official) {
            isOfficialPool[pool] = true;
            officialPools.push(pool);
        }

        _addTokens(pool, tokens);

        emit PoolCreated(pool, creator, baseToken, official);
    }

    /// @notice Add tokens to registry
    function _addTokens(address pool, address[] memory tokens) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];

            // Skip if already registered
            if (tokenInPool[pool][token]) continue;

            // token → pools mapping
            tokenToPools[token].push(pool);
            poolInToken[token][pool] = true;

            // pool → tokens mapping
            poolToTokens[pool].push(token);
            tokenInPool[pool][token] = true;
        }
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Get all pools that support a specific token
    function getPoolsForToken(address token)
        external
        view
        returns (address[] memory pools)
    {
        return tokenToPools[token];
    }

    /// @notice Get pools that support both tokens (direct swap candidates)
    function getCommonPools(address tokenA, address tokenB)
        external
        view
        returns (address[] memory pools)
    {
        address[] memory poolsA = tokenToPools[tokenA];
        address[] memory poolsB = tokenToPools[tokenB];

        // Early exit for empty arrays
        if (poolsA.length == 0 || poolsB.length == 0) {
            return new address[](0);
        }

        // Use smaller array for iteration
        if (poolsA.length > poolsB.length) {
            (poolsA, poolsB) = (poolsB, poolsA);
        }

        // Count matches first for efficient allocation
        uint256 count = 0;
        for (uint256 i = 0; i < poolsA.length; i++) {
            if (poolInToken[tokenB][poolsA[i]]) {
                count++;
            }
        }

        // Allocate and fill result
        pools = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < poolsA.length; i++) {
            if (poolInToken[tokenB][poolsA[i]]) {
                pools[index++] = poolsA[i];
            }
        }
    }

    /// @notice Get official (whitelisted) pools only
    function getOfficialPools() external view returns (address[] memory) {
        return officialPools;
    }

    /// @notice Get all tokens supported by a pool
    function getPoolTokens(address pool)
        external
        view
        returns (address[] memory tokens)
    {
        return poolToTokens[pool];
    }

    /// @notice Check if a route exists between two tokens
    /// @return hasDirectRoute True if both tokens are in the same pool
    /// @return commonPools Pools that support both tokens
    function checkRoute(address tokenA, address tokenB)
        external
        view
        returns (
            bool hasDirectRoute,
            address[] memory commonPools
        )
    {
        commonPools = getCommonPools(tokenA, tokenB);
        hasDirectRoute = commonPools.length > 0;
    }

    // ========== ADMIN ==========

    /// @notice Request reference implementation upgrade (timelocked)
    function requestReferenceUpgrade(address newImplementation)
        external
        onlyOwner
    {
        pendingReferencePool = newImplementation;
        upgradeTimelock = block.timestamp + UPGRADE_TIMELOCK;

        emit ReferencePoolUpgradeRequested(
            referencePool,
            newImplementation,
            upgradeTimelock
        );
    }

    /// @notice Execute pending reference upgrade
    function executeReferenceUpgrade() external onlyOwner {
        require(
            block.timestamp >= upgradeTimelock,
            "Timelock not expired"
        );
        require(pendingReferencePool != address(0), "No pending upgrade");

        address oldImplementation = referencePool;
        referencePool = pendingReferencePool;

        delete pendingReferencePool;
        delete upgradeTimelock;

        emit ReferencePoolUpgraded(oldImplementation, referencePool);
    }

    /// @notice Update protocol deployer
    function setProtocolDeployer(address newDeployer) external onlyOwner {
        address oldDeployer = protocolDeployer;
        protocolDeployer = newDeployer;
        emit ProtocolDeployerUpdated(oldDeployer, newDeployer);
    }
}
```

## 2. Stateless RouterV1 Design

### 2.1 Core Interface

```solidity
/// @title RouterV1
/// @notice Stateless router for optimal route discovery and execution
/// @dev Uses factory for registry, delegates swaps to pools directly
contract RouterV1 is IRouterV1 {
    // ========== STATE ==========

    /// @notice Pool proxy factory
    PoolProxyFactory public immutable factory;

    /// @notice Maximum route hops (gas limit)
    uint8 public constant MAX_HOPS = 3;

    /// @notice Owner (DAO)
    address public owner;

    // ========== STRUCTS ==========

    /// @notice Route step descriptor
    struct RouteStep {
        address pool;      // Pool to execute swap in
        address tokenIn;   // Input token for this hop
        address tokenOut;  // Output token for this hop
    }

    /// @notice Complete route with quote
    struct Route {
        RouteStep[] steps;      // Individual hops
        uint256 amountOut;      // Expected output
        uint256 gasEstimate;    // Estimated gas cost
    }

    // ========== INITIALIZATION ==========

    constructor(address _factory) {
        factory = PoolProxyFactory(_factory);
        owner = msg.sender;
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Find best route for single token swap
    /// @param tokenIn Input token
    /// @param tokenOut Output token
    /// @param amountIn Input amount
    /// @return bestRoute Optimal route (may be single or multi-hop)
    /// @return amountOut Expected output amount
    function getBestRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (Route memory bestRoute, uint256 amountOut) {
        // 1. Try direct routes (pools with both tokens)
        Route memory directRoute = _findBestDirectRoute(tokenIn, tokenOut, amountIn);
        uint256 bestOutput = directRoute.amountOut;
        bestRoute = directRoute;

        // 2. Try 2-hop routes via intermediate tokens
        if (MAX_HOPS >= 2) {
            (Route memory twoHopRoute, uint256 twoHopOutput) =
                _findBestTwoHopRoute(tokenIn, tokenOut, amountIn);

            if (twoHopOutput > bestOutput) {
                bestRoute = twoHopRoute;
                bestOutput = twoHopOutput;
            }
        }

        // 3. Try 3-hop routes (rare, only if necessary)
        if (MAX_HOPS >= 3 && bestOutput == 0) {
            (Route memory threeHopRoute, uint256 threeHopOutput) =
                _findBestThreeHopRoute(tokenIn, tokenOut, amountIn);

            if (threeHopOutput > bestOutput) {
                bestRoute = threeHopRoute;
                bestOutput = threeHopOutput;
            }
        }

        amountOut = bestOutput;
    }

    /// @notice Find best direct route (single pool with both tokens)
    function _findBestDirectRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (Route memory) {
        address[] memory commonPools = factory.getCommonPools(tokenIn, tokenOut);

        uint256 bestAmountOut = 0;
        address bestPool = address(0);

        for (uint256 i = 0; i < commonPools.length; i++) {
            // Only consider official pools for routing
            if (!factory.isOfficialPool(commonPools[i])) continue;

            // Get quote from pool
            try IExchangeV1(commonPools[i]).getSwapQuote(tokenIn, tokenOut, amountIn)
                returns (IExchangeV1.SwapQuote memory quote)
            {
                if (quote.amountOut > bestAmountOut) {
                    bestAmountOut = quote.amountOut;
                    bestPool = commonPools[i];
                }
            } catch {}
        }

        Route memory route;
        if (bestPool != address(0)) {
            route.steps = new RouteStep[](1);
            route.steps[0] = RouteStep({
                pool: bestPool,
                tokenIn: tokenIn,
                tokenOut: tokenOut
            });
            route.amountOut = bestAmountOut;
            route.gasEstimate = 150000; // Rough estimate for single swap
        }

        return route;
    }

    /// @notice Find best 2-hop route (tokenA → intermediate → tokenB)
    function _findBestTwoHopRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (Route memory, uint256) {
        // Get pools for input token
        address[] memory poolsIn = factory.getPoolsForToken(tokenIn);
        // Get pools for output token
        address[] memory poolsOut = factory.getPoolsForToken(tokenOut);

        uint256 bestAmountOut = 0;
        address bestIntermediate = address(0);
        address bestPoolIn = address(0);
        address bestPoolOut = address(0);

        // For each pool with input token
        for (uint256 i = 0; i < poolsIn.length; i++) {
            if (!factory.isOfficialPool(poolsIn[i])) continue;

            // Get tokens in this pool (potential intermediates)
            address[] memory intermediates = factory.getPoolTokens(poolsIn[i]);

            // For each potential intermediate
            for (uint256 j = 0; j < intermediates.length; j++) {
                address intermediate = intermediates[j];

                // Skip if same as input/output or not in output pool
                if (intermediate == tokenIn || intermediate == tokenOut) continue;
                if (!factory.poolInToken[poolsOut][0][intermediate]) {
                    // Check if any output pool has this intermediate
                    bool found = false;
                    for (uint256 k = 0; k < poolsOut.length; k++) {
                        if (factory.tokenInPool[poolsOut[k]][intermediate]) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) continue;
                }

                // Find best output pool for intermediate→output
                address bestOutPoolForIntermediate = _findBestPoolForPair(
                    intermediate,
                    tokenOut,
                    poolsOut
                );
                if (bestOutPoolForIntermediate == address(0)) continue;

                // Quote first hop
                uint256 hop1AmountOut;
                try IExchangeV1(poolsIn[i]).getSwapQuote(
                    tokenIn, intermediate, amountIn
                ) returns (IExchangeV1.SwapQuote memory quote1) {
                    hop1AmountOut = quote1.amountOut;
                } catch {
                    continue;
                }

                // Quote second hop
                uint256 hop2AmountOut;
                try IExchangeV1(bestOutPoolForIntermediate).getSwapQuote(
                    intermediate, tokenOut, hop1AmountOut
                ) returns (IExchangeV1.SwapQuote memory quote2) {
                    hop2AmountOut = quote2.amountOut;
                } catch {
                    continue;
                }

                if (hop2AmountOut > bestAmountOut) {
                    bestAmountOut = hop2AmountOut;
                    bestIntermediate = intermediate;
                    bestPoolIn = poolsIn[i];
                    bestPoolOut = bestOutPoolForIntermediate;
                }
            }
        }

        Route memory route;
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
            route.gasEstimate = 300000; // Rough estimate for 2-hop
        }

        return (route, bestAmountOut);
    }

    /// @notice Find best 3-hop route (for very rare cases)
    function _findBestThreeHopRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (Route memory, uint256) {
        // Simplified: try base tokens as intermediates
        // Most pools will have a base token (USDC, WETH, etc.)
        // Route: tokenIn → base1 → base2 → tokenOut

        // Get official pools
        address[] memory officialPools = factory.getOfficialPools();

        // Collect unique base tokens
        mapping(address => bool) seenBase;
        address[] memory baseTokens = new address[](officialPools.length);
        uint256 baseCount = 0;

        for (uint256 i = 0; i < officialPools.length; i++) {
            address baseToken = factory.poolBaseTokens(officialPools[i]);
            if (!seenBase[baseToken] && baseToken != address(0)) {
                seenBase[baseToken] = true;
                baseTokens[baseCount++] = baseToken;
            }
        }

        // Try each pair of base tokens as intermediate hops
        uint256 bestAmountOut = 0;
        Route memory bestRoute;

        for (uint256 i = 0; i < baseCount; i++) {
            for (uint256 j = 0; j < baseCount; j++) {
                if (i == j) continue;

                address base1 = baseTokens[i];
                address base2 = baseTokens[j];

                // Find pools for each hop
                address pool1 = _findBestPoolForPair(tokenIn, base1, officialPools);
                if (pool1 == address(0)) continue;

                address pool2 = _findBestPoolForPair(base1, base2, officialPools);
                if (pool2 == address(0)) continue;

                address pool3 = _findBestPoolForPair(base2, tokenOut, officialPools);
                if (pool3 == address(0)) continue;

                // Quote the full route
                uint256 amt1 = amountIn;
                uint256 amt2, amt3;

                try IExchangeV1(pool1).getSwapQuote(tokenIn, base1, amt1)
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
                        bestRoute.steps = new RouteStep[](3);
                        bestRoute.steps[0] = RouteStep({
                            pool: pool1,
                            tokenIn: tokenIn,
                            tokenOut: base1
                        });
                        bestRoute.steps[1] = RouteStep({
                            pool: pool2,
                            tokenIn: base1,
                            tokenOut: base2
                        });
                        bestRoute.steps[2] = RouteStep({
                            pool: pool3,
                            tokenIn: base2,
                            tokenOut: tokenOut
                        });
                        bestRoute.amountOut = bestAmountOut;
                        bestRoute.gasEstimate = 450000;
                    }
                } catch { continue; }
            }
        }

        return (bestRoute, bestAmountOut);
    }

    /// @notice Helper: find best pool for a token pair from a list
    function _findBestPoolForPair(
        address tokenA,
        address tokenB,
        address[] memory pools
    ) internal view returns (address) {
        uint256 bestAmountOut = 0;
        address bestPool = address(0);

        for (uint256 i = 0; i < pools.length; i++) {
            if (!factory.tokenInPool[pools[i]][tokenA]) continue;
            if (!factory.tokenInPool[pools[i]][tokenB]) continue;

            try IExchangeV1(pools[i]).getSwapQuote(tokenA, tokenB, 1e18)
                returns (IExchangeV1.SwapQuote memory quote)
            {
                if (quote.amountOut > bestAmountOut) {
                    bestAmountOut = quote.amountOut;
                    bestPool = pools[i];
                }
            } catch {}
        }

        return bestPool;
    }

    // ========== EXECUTION FUNCTIONS ==========

    /// @notice Execute swap along a route
    function executeSwap(
        Route calldata route,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external payable returns (uint256 amountOut) {
        // Transfer input tokens
        RouteStep memory firstStep = route.steps[0];
        _transferIn(firstStep.tokenIn, amountIn);

        // Execute each hop
        uint256 currentAmount = amountIn;
        address currentToken = firstStep.tokenIn;

        for (uint256 i = 0; i < route.steps.length; i++) {
            RouteStep memory step = route.steps[i];

            // Approve pool if needed (ERC20)
            if (currentToken != address(0)) {
                SafeTransferLib.safeApprove(
                    currentToken,
                    step.pool,
                    currentAmount
                );
            }

            // Execute swap
            uint256 amountOut;
            if (currentToken == address(0)) {
                // Native input
                amountOut = IExchangeV1(step.pool).swap{value: currentAmount}(
                    currentToken,
                    step.tokenOut,
                    currentAmount,
                    0, // minAmountOut (checked at end)
                    address(this) // Router holds intermediate tokens
                );
            } else {
                amountOut = IExchangeV1(step.pool).swap(
                    currentToken,
                    step.tokenOut,
                    currentAmount,
                    0, // minAmountOut (checked at end
                    address(this)
                );
            }

            currentAmount = amountOut;
            currentToken = step.tokenOut;
        }

        amountOut = currentAmount;

        require(amountOut >= minAmountOut, "Slippage exceeded");

        // Transfer output to recipient
        _transferOut(currentToken, amountOut, recipient);

        emit SwapExecuted(msg.sender, recipient, amountIn, amountOut);
    }

    // ========== INTERNAL HELPERS ==========

    function _transferIn(address token, uint256 amount) internal {
        if (token == address(0)) {
            require(msg.value == amount, "Wrong ETH amount");
        } else {
            SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        }
    }

    function _transferOut(address token, uint256 amount, address recipient) internal {
        if (token == address(0)) {
            SafeTransferLib.safeETH(recipient, amount);
        } else {
            SafeTransferLib.safeTransfer(token, recipient, amount);
        }
    }

    // ========== EVENTS ==========

    event SwapExecuted(
        address indexed sender,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOut
    );
}
```

## 3. Batch Swap Routing Design

### 3.1 Challenge Analysis

Batch swaps (multi-input/multi-output) present unique routing challenges:

1. **Input Consolidation**: Multiple input tokens need to be converted to a common base
2. **Output Distribution**: Base needs to be converted to multiple output tokens
3. **Path Optimization**: Finding optimal intermediate tokens for all conversions
4. **Slippage Management**: Minimizing total slippage across all conversions

### 3.2 V1 Solution: Hub-and-Spoke Model

The V1 routing solution uses a **hub-and-spoke** approach:

```
            TokenIn1 ──┐
            TokenIn2 ──┼──► [HUB TOKEN] ──┬──► TokenOut1
            TokenIn3 ──┘                   ├──► TokenOut2
                                            └──► TokenOut3
```

**Key Design Decisions:**

1. **Hub Token Selection**: Choose the token that:
   - Is present in the most official pools
   - Has the highest liquidity
   - Minimizes total hops

2. **Two-Phase Routing**:
   - **Phase 1 (Input Consolidation)**: Each input token → hub token
   - **Phase 2 (Output Distribution)**: Hub token → each output token

3. **Optimization Strategies**:
   - If any input token equals any output token, route directly (no conversion)
   - If both input and output tokens are in the same pool, use internal batch swap
   - Prefer direct swaps over multi-hop when available

### 3.3 Implementation

```solidity
/// @title BatchRouterV1
/// @notice Batch swap routing using hub-and-spoke model
contract BatchRouterV1 is RouterV1 {
    // ========== STRUCTS ==========

    /// @notice Batch swap route
    struct BatchRoute {
        address hubToken;              // Central hub token
        RouteStep[] inputRoutes;       // Routes from inputs to hub
        RouteStep[] outputRoutes;      // Routes from hub to outputs
        uint256[] inputAmounts;        // Expected amounts at hub after phase 1
        uint256[] outputAmounts;       // Expected amounts out after phase 2
    }

    /// @notice Batch swap input
    struct BatchInput {
        address token;
        uint256 amount;
    }

    /// @notice Batch swap output
    struct BatchOutput {
        address token;
        uint256 weight;   // Basis points relative to total value
        uint256 minAmount;
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Find best route for batch swap
    /// @param inputs Input tokens and amounts
    /// @param outputs Output tokens with weights
    /// @return route Optimal batch route
    function getBestBatchRoute(
        BatchInput[] calldata inputs,
        BatchOutput[] calldata outputs
    ) external view returns (BatchRoute memory route) {
        // 1. Select optimal hub token
        route.hubToken = _selectHubToken(inputs, outputs);

        // 2. Build routes for each input → hub
        route.inputRoutes = new RouteStep[](inputs.length);
        route.inputAmounts = new uint256[](inputs.length);

        for (uint256 i = 0; i < inputs.length; i++) {
            if (inputs[i].token == route.hubToken) {
                // Input is already hub token (no conversion needed)
                route.inputAmounts[i] = inputs[i].amount;
            } else {
                // Find best route to hub
                (Route memory r, uint256 amtOut) = _findBestTwoHopRoute(
                    inputs[i].token,
                    route.hubToken,
                    inputs[i].amount
                );
                require(r.amountOut > 0, "No route found for input");

                route.inputRoutes[i] = r.steps[0]; // First hop
                route.inputAmounts[i] = r.amountOut;
            }
        }

        // 3. Calculate total hub value available
        uint256 totalHubValue;
        for (uint256 i = 0; i < route.inputAmounts.length; i++) {
            totalHubValue += route.inputAmounts[i];
        }

        // 4. Build routes for hub → each output
        route.outputRoutes = new RouteStep[](outputs.length);
        route.outputAmounts = new uint256[](outputs.length);

        for (uint256 i = 0; i < outputs.length; i++) {
            if (outputs[i].token == route.hubToken) {
                // Output is hub token (no conversion needed)
                route.outputAmounts[i] = (totalHubValue * outputs[i].weight) / 10000;
            } else {
                // Find best route from hub
                (Route memory r, ) = _findBestTwoHopRoute(
                    route.hubToken,
                    outputs[i].token,
                    (totalHubValue * outputs[i].weight) / 10000
                );
                require(r.amountOut > 0, "No route found for output");

                route.outputRoutes[i] = r.steps[0]; // First hop
                route.outputAmounts[i] = r.amountOut;
            }
        }
    }

    /// @notice Select optimal hub token for batch swap
    function _selectHubToken(
        BatchInput[] calldata inputs,
        BatchOutput[] calldata outputs
    ) internal view returns (address) {
        // Collect all unique tokens involved
        mapping(address => bool) seen;
        address[] memory allTokens = new address[](inputs.length + outputs.length);
        uint256 tokenCount = 0;

        for (uint256 i = 0; i < inputs.length; i++) {
            if (!seen[inputs[i].token]) {
                seen[inputs[i].token] = true;
                allTokens[tokenCount++] = inputs[i].token;
            }
        }
        for (uint256 i = 0; i < outputs.length; i++) {
            if (!seen[outputs[i].token]) {
                seen[outputs[i].token] = true;
                allTokens[tokenCount++] = outputs[i].token;
            }
        }

        // Score each token as potential hub
        uint256 bestScore = 0;
        address bestHub = address(0);

        // Prefer base tokens of official pools
        address[] memory officialPools = factory.getOfficialPools();

        for (uint256 i = 0; i < officialPools.length; i++) {
            address baseToken = factory.poolBaseTokens(officialPools[i]);

            // Skip if baseToken is zero or not in our token list
            if (baseToken == address(0)) continue;

            // Score = number of pools that have this token
            uint256 score = 0;
            for (uint256 j = 0; j < officialPools.length; j++) {
                if (factory.tokenInPool[officialPools[j]][baseToken]) {
                    score++;
                }
            }

            if (score > bestScore) {
                bestScore = score;
                bestHub = baseToken;
            }
        }

        // Fallback: first input token
        if (bestHub == address(0) && inputs.length > 0) {
            bestHub = inputs[0].token;
        }

        return bestHub;
    }

    // ========== EXECUTION ==========

    /// @notice Execute batch swap
    function executeBatchSwap(
        BatchRoute calldata route,
        BatchInput[] calldata inputs,
        BatchOutput[] calldata outputs,
        address recipient
    ) external payable returns (uint256[] memory) {
        // Transfer all inputs to router
        uint256 totalHubValue;

        for (uint256 i = 0; i < inputs.length; i++) {
            _transferIn(inputs[i].token, inputs[i].amount);

            if (inputs[i].token != route.hubToken) {
                // Convert to hub
                RouteStep memory step = route.inputRoutes[i];
                if (inputs[i].token == address(0)) {
                    // Native
                    IExchangeV1(step.pool).swap{value: inputs[i].amount}(
                        inputs[i].token,
                        route.hubToken,
                        inputs[i].amount,
                        0,
                        address(this)
                    );
                } else {
                    SafeTransferLib.safeApprove(
                        inputs[i].token,
                        step.pool,
                        inputs[i].amount
                    );
                    IExchangeV1(step.pool).swap(
                        inputs[i].token,
                        route.hubToken,
                        inputs[i].amount,
                        0,
                        address(this)
                    );
                }
            }
            totalHubValue += route.inputAmounts[i];
        }

        // Distribute to outputs
        uint256[] memory actualAmounts = new uint256[](outputs.length);

        for (uint256 i = 0; i < outputs.length; i++) {
            address outputToken = outputs[i].token;
            uint256 expectedAmount = route.outputAmounts[i];

            if (outputToken == route.hubToken) {
                // Direct transfer
                _transferOut(route.hubToken, expectedAmount, recipient);
                actualAmounts[i] = expectedAmount;
            } else {
                // Convert from hub
                RouteStep memory step = route.outputRoutes[i];

                SafeTransferLib.safeApprove(
                    route.hubToken,
                    step.pool,
                    expectedAmount
                );

                uint256 amountOut = IExchangeV1(step.pool).swap(
                    route.hubToken,
                    outputToken,
                    expectedAmount,
                    outputs[i].minAmount,
                    recipient
                );
                actualAmounts[i] = amountOut;
            }
        }

        emit BatchSwapExecuted(msg.sender, recipient, inputs.length, outputs.length);
        return actualAmounts;
    }

    event BatchSwapExecuted(
        address indexed sender,
        address indexed recipient,
        uint256 inputCount,
        uint256 outputCount
    );
}
```

## 4. Deployment Flow

### 4.1 Deterministic Deployment Sequence

```solidity
// 1. Deploy Factory (CREATE3, deterministic)
// Salt: "BTR_FACTORY_V1" + chainid
address factory = CREATE3.deploy(keccak256("BTR_FACTORY_V1"), factoryBytecode);

// 2. Deploy Reference Pool (CREATE3, deterministic)
// Salt: "BTR_REFERENCE_POOL_V1" + chainid
address referencePool = CREATE3.deploy(
    keccak256("BTR_REFERENCE_POOL_V1"),
    referencePoolBytecode
);

// 3. Initialize Factory with reference pool
PoolProxyFactory(factory).initialize(referencePool, protocolDeployer);

// 4. Deploy Router (also deterministic, points to factory)
address router = CREATE3.deploy(
    keccak256("BTR_ROUTER_V1"),
    abi.encodePacked(routerBytecode, abi.encode(factory))
);
```

### 4.2 Pool Deployment by Users

```solidity
// User calls factory.createPool()
bytes memory initdata = abi.encodeWithSelector(
    IPoolV1.initialize.selector,
    userAddress,    // owner
    usdcAddress,    // baseToken
    wethAddress     // wnative
);

address newPool = factory.createPool(
    usdcAddress,
    [wethAddress, usdtAddress, wbtcAddress],
    initdata
);

// Pool automatically registers tokens when assets are added via pool.configureAsset()
```

## 5. Gas Optimization Notes

1. **Minimal Proxy Pattern**: Each pool uses ~200 bytes of bytecode vs full deployment
2. **Token Registry Caching**: Factory caches token→pool mappings for O(1) lookups
3. **Route Caching (Optional V2)**: Router can cache recently computed routes
4. **Batch Operations**: Use assembly for tight loops in calldata parsing (like Odos)
5. **Stateless Router**: No storage writes in router during routing (pure view functions)

## 6. Security Considerations

1. **Factory is Non-upgradeable**: Only reference pool can be upgraded (timelocked)
2. **Official Pool Whitelist**: Only protocol-deployer pools auto-whitelisted
3. **Token Registration**: Only pools can register their own tokens (prevent front-running)
4. **Slippage Protection**: All routes checked against minimums at execution
5. **Reentrancy**: Use transient storage (EIP-1153) in reference pool

## 7. Future Enhancements (V2)

1. **Route caching** with invalidation on pool state changes
2. **Multi-hop batch routing** for complex arbitrage opportunities
3. **Intent-based routing** where users specify desired outcome, not path
4. **Merkle tree based whitelist** for permissionless but verified pools
5. **Dynamic fee adjustment** based on congestion
