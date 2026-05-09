// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IRouter} from "./interfaces/IRouter.sol";
import {IPoolProxyFactory} from "./interfaces/IPoolProxyFactory.sol";
import {IExchange} from "./interfaces/modules/IExchange.sol";
import {Err} from "@btr-peripheral/Errors.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LibTimelock as TL} from "./libraries/LibTimelock.sol";
import {LibConstants as C} from "./libraries/LibConstants.sol";

/// @title Router
/// @notice Stateless router for optimal route discovery and execution.
contract Router is IRouter, Ownable, ReentrancyGuard, UUPSUpgradeable {
    using SafeTransferLib for address;

    error SlippageExceeded();
    error WrongEthAmount();

    uint8 public constant MAX_HOPS = 3;
    uint16 internal constant MIN_HOP_IMPROVEMENT_BPS = 105; // 5% gain over direct to use multi-hop
    address internal constant ETH = address(0);

    address public override factory;

    uint96 public pendingUpgradeOp;
    bytes32 public pendingUpgradeId;
    address public pendingImplementation;

    constructor() {}

    /// @dev F-A2-R10-1 (LOW) NOT FIXED (intentional): unguarded `initialize`. Deployment script
    ///      atomically deploys + initializes (single tx) → front-run window = 0. One-shot guard
    ///      via `factory != address(0)` blocks repeat. Mirrors Bridge.initialize disposition.
    function initialize(address newOwner, address _factory) external {
        if (factory != address(0)) revert Err.InvalidState();
        if (_factory == address(0)) revert Err.ZeroValue();
        factory = _factory;
        _initializeOwner(newOwner);
    }

    // ─── route discovery ───

    /// @notice Returns best 1/2/3-hop route for `tokenIn → tokenOut` at size `amountIn`.
    /// @dev Phase 42D R2-A3-1 DISCARD (by-design): per-hop `minOut` is set to the in-block
    ///      quoted amount → ZERO slippage tolerance. Block-N+1 execution will revert if any
    ///      pool has moved. This is conservatively safe vs sandwich attacks. Integrators that
    ///      need slippage tolerance MUST construct their own `Route` with discounted per-hop
    ///      `minOut` values (e.g. `quote * 9_995 / 10_000` for 5 bps tolerance) before calling
    ///      `executeSwap`. The `getBestRoute` view is a discovery helper, not a settlement primitive.
    function getBestRoute(address tokenIn, address tokenOut, uint256 amountIn)
        external view override returns (Route memory route, uint256 amountOut)
    {
        (address bestPool, IExchange.SwapQuote memory bestQuote) =
            _getBestDirectQuote(tokenIn, tokenOut, amountIn);

        route.amountOut = bestQuote.amountOut;
        route.gasEstimate = 150000;
        if (bestPool != address(0)) {
            route.steps = new RouteStep[](1);
            route.steps[0] = RouteStep({pool: bestPool, tokenIn: tokenIn, tokenOut: tokenOut, minOut: bestQuote.amountOut});
        }

        (Route memory twoHop, uint256 twoHopOut) = _getBestTwoHopRoute(tokenIn, tokenOut, amountIn);
        if (twoHopOut > route.amountOut && twoHopOut * 100 > route.amountOut * MIN_HOP_IMPROVEMENT_BPS) {
            route = twoHop;
            route.gasEstimate = 300000;
        }

        if (route.amountOut == 0) {
            (Route memory threeHop, uint256 threeHopOut) = _getBestThreeHopRoute(tokenIn, tokenOut, amountIn);
            if (threeHopOut > 0) {
                route = threeHop;
                route.gasEstimate = 450000;
            }
        }
        amountOut = route.amountOut;
    }

    function getBestDirectQuote(address tokenIn, address tokenOut, uint256 amountIn)
        external view override returns (address pool, IExchange.SwapQuote memory quote)
    {
        return _getBestDirectQuote(tokenIn, tokenOut, amountIn);
    }

    function getBestTwoHopRoute(address tokenIn, address tokenOut, uint256 amountIn)
        external view override returns (Route memory route, uint256 amountOut)
    {
        return _getBestTwoHopRoute(tokenIn, tokenOut, amountIn);
    }

    function _quoteOrZero(address pool, address tIn, address tOut, uint256 amt)
        internal view returns (uint256)
    {
        try IExchange(pool).getSwapQuote(tIn, tOut, amt) returns (IExchange.SwapQuote memory q) {
            return q.amountOut;
        } catch { return 0; }
    }

    function _getBestDirectQuote(address tokenIn, address tokenOut, uint256 amountIn)
        internal view returns (address pool, IExchange.SwapQuote memory quote)
    {
        IPoolProxyFactory f = IPoolProxyFactory(factory);
        address[] memory commonPools = f.getCommonPools(tokenIn, tokenOut);
        uint256 best;
        for (uint256 i = 0; i < commonPools.length; i++) {
            if (!f.isOfficialPool(commonPools[i])) continue;
            try IExchange(commonPools[i]).getSwapQuote(tokenIn, tokenOut, amountIn) returns (IExchange.SwapQuote memory q) {
                if (q.amountOut > best) {
                    best = q.amountOut;
                    pool = commonPools[i];
                    quote = q;
                }
            } catch {}
        }
    }

    function _getBestTwoHopRoute(address tokenIn, address tokenOut, uint256 amountIn)
        internal view returns (Route memory route, uint256)
    {
        IPoolProxyFactory f = IPoolProxyFactory(factory);
        uint256 officialCount = f.getOfficialPoolsCount();

        uint256 bestOut;
        address bestMid;
        address bestPoolIn;
        address bestPoolOut;

        for (uint256 i = 0; i < officialCount; i++) {
            address poolIn = f.officialPools(i);
            if (!f.tokenInPool(tokenIn, poolIn)) continue;
            address[] memory poolTokens = f.getPoolTokens(poolIn);

            for (uint256 j = 0; j < poolTokens.length; j++) {
                address mid = poolTokens[j];
                if (mid == tokenIn || mid == tokenOut) continue;

                uint256 hop1 = _quoteOrZero(poolIn, tokenIn, mid, amountIn);
                if (hop1 == 0) continue;
                // R2-A3-2: probe downstream pool w/ realistic hop1 output (price-impact aware)
                address poolOut = _findBestPoolForPair(mid, tokenOut, officialCount, hop1);
                if (poolOut == address(0)) continue;
                uint256 hop2 = _quoteOrZero(poolOut, mid, tokenOut, hop1);
                if (hop2 > bestOut) {
                    bestOut = hop2;
                    bestMid = mid;
                    bestPoolIn = poolIn;
                    bestPoolOut = poolOut;
                }
            }
        }

        if (bestOut > 0) {
            uint256 hop1Out = _quoteOrZero(bestPoolIn, tokenIn, bestMid, amountIn);
            route.steps = new RouteStep[](2);
            route.steps[0] = RouteStep({pool: bestPoolIn, tokenIn: tokenIn, tokenOut: bestMid, minOut: hop1Out});
            route.steps[1] = RouteStep({pool: bestPoolOut, tokenIn: bestMid, tokenOut: tokenOut, minOut: bestOut});
            route.amountOut = bestOut;
            route.gasEstimate = 300000;
        }
        return (route, bestOut);
    }

    function _getBestThreeHopRoute(address tokenIn, address tokenOut, uint256 amountIn)
        internal view returns (Route memory route, uint256)
    {
        IPoolProxyFactory f = IPoolProxyFactory(factory);
        uint256 officialCount = f.getOfficialPoolsCount();

        address[] memory baseTokens = new address[](officialCount);
        uint256 baseCount;
        for (uint256 i = 0; i < officialCount; i++) {
            address bt = f.poolBaseTokens(f.officialPools(i));
            if (bt == address(0)) continue;
            bool dup;
            for (uint256 k = 0; k < baseCount; k++) if (baseTokens[k] == bt) { dup = true; break; }
            if (!dup) baseTokens[baseCount++] = bt;
        }

        uint256 bestOut;
        for (uint256 i = 0; i < baseCount; i++) {
            for (uint256 j = 0; j < baseCount; j++) {
                if (i == j) continue;
                address b1 = baseTokens[i];
                address b2 = baseTokens[j];
                // R2-A3-2: probe each pool w/ realistic hop input (price-impact aware)
                address p1 = _findBestPoolForPair(tokenIn, b1, officialCount, amountIn);
                if (p1 == address(0)) continue;
                uint256 a2 = _quoteOrZero(p1, tokenIn, b1, amountIn);
                if (a2 == 0) continue;
                address p2 = _findBestPoolForPair(b1, b2, officialCount, a2);
                if (p2 == address(0)) continue;
                uint256 a3 = _quoteOrZero(p2, b1, b2, a2);
                if (a3 == 0) continue;
                address p3 = _findBestPoolForPair(b2, tokenOut, officialCount, a3);
                if (p3 == address(0)) continue;
                uint256 outAmt = _quoteOrZero(p3, b2, tokenOut, a3);
                if (outAmt > bestOut) {
                    bestOut = outAmt;
                    route.steps = new RouteStep[](3);
                    route.steps[0] = RouteStep({pool: p1, tokenIn: tokenIn, tokenOut: b1, minOut: a2});
                    route.steps[1] = RouteStep({pool: p2, tokenIn: b1, tokenOut: b2, minOut: a3});
                    route.steps[2] = RouteStep({pool: p3, tokenIn: b2, tokenOut: tokenOut, minOut: outAmt});
                    route.amountOut = bestOut;
                    route.gasEstimate = 450000;
                }
            }
        }
        return (route, bestOut);
    }

    /// @dev R2-A3-2: probeAmount sourced from upstream realistic flow → ranks pools by
    ///      price-impact-adjusted output rather than fixed 1e18 (which biased toward
    ///      shallow pools when actual trade size was larger).
    function _findBestPoolForPair(address tokenA, address tokenB, uint256 officialCount, uint256 probeAmount)
        internal view returns (address bestPool)
    {
        IPoolProxyFactory f = IPoolProxyFactory(factory);
        if (probeAmount == 0) probeAmount = 1e18;
        uint256 best;
        for (uint256 i = 0; i < officialCount; i++) {
            address pool = f.officialPools(i);
            if (!f.tokenInPool(tokenA, pool) || !f.tokenInPool(tokenB, pool)) continue;
            uint256 q = _quoteOrZero(pool, tokenA, tokenB, probeAmount);
            if (q > best) { best = q; bestPool = pool; }
        }
    }

    // ─── batch view ───

    function getBestBatchPool(BatchInput[] calldata inputs, BatchOutput[] calldata outputs)
        external view override returns (address pool, uint256 totalBaseValue)
    {
        IPoolProxyFactory f = IPoolProxyFactory(factory);
        uint256 officialCount = f.getOfficialPoolsCount();
        for (uint256 i = 0; i < officialCount; i++) {
            address candidate = f.officialPools(i);
            bool ok = true;
            for (uint256 j = 0; j < inputs.length; j++) {
                if (!f.tokenInPool(inputs[j].tokenIn, candidate)) { ok = false; break; }
            }
            if (!ok) continue;
            for (uint256 j = 0; j < outputs.length; j++) {
                if (!f.tokenInPool(outputs[j].tokenOut, candidate)) { ok = false; break; }
            }
            if (ok) return (candidate, 0);
        }
        return (address(0), 0);
    }

    // ─── exec ───

    function executeSwap(
        Route calldata route,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external payable override nonReentrant returns (uint256 amountOut) {
        uint256 nSteps = route.steps.length;
        if (nSteps == 0 || nSteps > MAX_HOPS) revert Err.InvalidInput();

        RouteStep memory firstStep = route.steps[0];
        _transferIn(firstStep.tokenIn, amountIn);

        uint256 currentAmount = amountIn;
        address currentToken = firstStep.tokenIn;
        IPoolProxyFactory f = IPoolProxyFactory(factory);

        for (uint256 i = 0; i < nSteps; i++) {
            RouteStep memory step = route.steps[i];
            // Phase 42D R2-A2-1: tighten exec to isOfficialPool — symmetric with quote-discovery
            // (_getBestDirectQuote uses isOfficialPool). Pool registration is owner-gated, but
            // exec must match discovery to avoid integrator surprise via hand-crafted Routes.
            if (!f.isOfficialPool(step.pool)) revert Ownable.Unauthorized();
            if (currentToken != ETH) currentToken.safeApprove(step.pool, currentAmount);

            currentAmount = currentToken == ETH
                ? IExchange(step.pool).swap{value: currentAmount}(currentToken, step.tokenOut, currentAmount, step.minOut, address(this))
                : IExchange(step.pool).swap(currentToken, step.tokenOut, currentAmount, step.minOut, address(this));

            // Reset residual approval (defence-in-depth vs malicious / partial-consume pools).
            if (currentToken != ETH) currentToken.safeApprove(step.pool, 0);
            currentToken = step.tokenOut;
        }

        amountOut = currentAmount;
        if (amountOut < minAmountOut) revert SlippageExceeded();

        _transferOut(currentToken, amountOut, recipient);
        emit SwapExecuted(msg.sender, recipient, amountIn, amountOut, uint8(nSteps));
    }

    function executeBatchSwap(
        address pool,
        bytes calldata inputs,
        bytes calldata outputs,
        address recipient
    ) external payable override nonReentrant returns (uint256[] memory amountsOut) {
        if (pool == address(0)) revert Err.ZeroValue();
        if (!IPoolProxyFactory(factory).isOfficialPool(pool)) revert Ownable.Unauthorized();
        amountsOut = IExchange(pool).batchSwap{value: msg.value}(inputs, outputs, recipient);
        emit BatchSwapExecuted(msg.sender, recipient, pool, inputs.length / 32, outputs.length / 32);
    }

    function getSwapQuote(address pool, address tokenIn, address tokenOut, uint256 amountIn)
        external override returns (IExchange.SwapQuote memory)
    {
        return IExchange(pool).getSwapQuote(tokenIn, tokenOut, amountIn);
    }

    function _transferIn(address token, uint256 amount) internal {
        if (token == ETH) {
            if (msg.value != amount) revert WrongEthAmount();
        } else {
            token.safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function _transferOut(address token, uint256 amount, address recipient) internal {
        if (token == ETH) recipient.safeTransferETH(amount);
        else token.safeTransfer(recipient, amount);
    }

    // ─── upgrades ───

    function requestUpgrade(address implementation) external override onlyOwner {
        if (implementation == address(0)) revert Err.ZeroValue();
        if (pendingUpgradeOp != 0) revert Err.PendingTimelock(uint48(block.timestamp));
        pendingUpgradeId = keccak256(abi.encode(implementation, block.timestamp));
        pendingImplementation = implementation;
        pendingUpgradeOp = TL.pack(C.UPGRADE_TIMELOCK, C.GRACE_PERIOD);
        emit UpgradeRequested(implementation, uint48(pendingUpgradeOp >> 48));
    }

    function executeUpgrade() external override onlyOwner {
        TL.validate(pendingUpgradeOp);
        address newImpl = pendingImplementation;
        delete pendingUpgradeId;
        delete pendingImplementation;
        delete pendingUpgradeOp;
        this.upgradeToAndCall(newImpl, "");
        emit Upgraded(newImpl);
    }

    function cancelUpgrade() external onlyOwner {
        if (pendingUpgradeOp == 0) revert Err.InvalidState();
        delete pendingUpgradeId;
        delete pendingImplementation;
        delete pendingUpgradeOp;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
