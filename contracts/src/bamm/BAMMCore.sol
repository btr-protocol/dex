// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IInternalOracle} from "../interfaces/IInternalOracle.sol";
import {LibStorage as S} from "../libraries/LibStorage.sol";
import {LibPricing as P} from "../libraries/LibPricing.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";
import {LibLiability} from "../libraries/LibLiability.sol";
import {LibUtils} from "../libraries/LibUtils.sol";
import {LibDiamondStorage} from "../libraries/LibDiamondStorage.sol";
import {BAMMDiamond} from "./BAMMDiamond.sol";
import {BAMMErrors as E} from "./BAMMErrors.sol";

/// @title BAMMCore
/// @notice Lean diamond proxy implementation - hot path only (swap, deposit, withdraw)
/// @dev Delegates admin/pricing/oracle operations to facets via diamond routing
contract BAMMCore is BAMMDiamond, ReentrancyGuard {
    using SafeTransferLib for address;
    using SafeCastLib for uint256;

    // ========== STATE ==========

    address public pricingFacet;
    address public adminFacet;
    address public oracleFacet;
    address private _owner;
    bool private _paused;

    // ========== MODIFIERS ==========

    modifier onlyOwner() {
        if (msg.sender != _owner) revert E.Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (_paused) revert E.Paused();
        _;
    }

    // ========== CONSTRUCTOR ==========

    constructor() {
        // Implementation constructor - owner set per-pool in initialize()
    }

    // ========== INITIALIZATION ==========

    /// @notice Initialize pool with base token and facet addresses
    /// @param baseToken Pool's base token
    /// @param _pricingFacet Pricing facet address
    /// @param _adminFacet Admin facet address
    /// @param _oracleFacet Oracle facet address
    /// @param poolOwner Pool owner address (can call admin functions)
    /// @param adminSelectors Admin facet function selectors
    /// @param oracleSelectors Oracle facet function selectors
    function initialize(
        address baseToken,
        address _pricingFacet,
        address _adminFacet,
        address _oracleFacet,
        address poolOwner,
        bytes4[] calldata adminSelectors,
        bytes4[] calldata oracleSelectors
    ) external {
        // Only initialize once; anyone can call but owner is set here
        IBAMM.BAMMStorage storage $ = S.bamm();
        require($.baseToken == address(0), "Already initialized");
        require(poolOwner != address(0), "Invalid owner");

        $.baseToken = baseToken;

        // Set pool owner - both in Core and Diamond storage
        _owner = poolOwner;
        LibDiamondStorage.ds().owner = poolOwner;  // ✅ Critical: admin/oracle facets check this

        // Set facet addresses
        pricingFacet = _pricingFacet;
        adminFacet = _adminFacet;
        oracleFacet = _oracleFacet;

        // Register facet selectors in diamond storage
        FacetCut[] memory cuts = new FacetCut[](2);
        cuts[0] = FacetCut({
            facet: _adminFacet,
            action: FacetCutAction.Add,
            selectors: adminSelectors
        });
        cuts[1] = FacetCut({
            facet: _oracleFacet,
            action: FacetCutAction.Add,
            selectors: oracleSelectors
        });

        _diamondCut(cuts);
    }

    // ========== ACCESS CONTROL ==========

    /// @notice Get current pool owner
    function owner() external view returns (address) {
        return _owner;
    }

    /// @notice Set new pool owner
    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        _owner = newOwner;
        LibDiamondStorage.ds().owner = newOwner;  // ✅ Keep diamond storage in sync
    }

    /// @notice Pause the pool
    function pausePool() external onlyOwner {
        _paused = true;
    }

    /// @notice Unpause the pool
    function unpausePool() external onlyOwner {
        _paused = false;
    }

    /// @notice Check if pool is paused
    function isPaused() external view returns (bool) {
        return _paused;
    }

    /// @notice Update facet addresses (admin only)
    function setFacets(address _pricingFacet, address _adminFacet, address _oracleFacet) external onlyOwner {
        pricingFacet = _pricingFacet;
        adminFacet = _adminFacet;
        oracleFacet = _oracleFacet;
    }

    /// @notice Cut facets (admin only)
    function cutFacet(address facet, FacetCutAction action, bytes4[] calldata selectors) external onlyOwner {
        FacetCut[] memory cuts = new FacetCut[](1);
        cuts[0] = FacetCut({ facet: facet, action: action, selectors: selectors });
        _diamondCut(cuts);
    }

    // ========== HOT PATH: SWAP ==========

    /// @notice Swap tokenIn for tokenOut
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) external payable nonReentrant whenNotPaused returns (uint256 amountOut) {
        return _swap(tokenIn, tokenOut, amountIn, minAmountOut, receiver);
    }

    /// @notice Internal swap logic (used by both swap and batchSwap)
    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) internal returns (uint256 amountOut) {
        // Input validation
        if (tokenIn == tokenOut) revert E.InvalidParameter();
        if (amountIn == 0) revert E.ZeroAmount();
        LibUtils.requireNonZero(receiver);

        // Storage access
        IBAMM.BAMMStorage storage $ = S.bamm();

        // Blacklist check
        if ($.blacklisted[msg.sender] || $.blacklisted[receiver]) revert E.Blacklisted();

        // Get base token
        address base = $.baseToken;

        // Dispatch to specialized handlers
        if (tokenIn != base && tokenOut != base) {
            amountOut = _swapTriangulated($, tokenIn, tokenOut, base, amountIn, receiver);
        } else {
            amountOut = _swapDirect($, tokenIn, tokenOut, base, amountIn, receiver);
        }

        // Slippage enforcement
        if (amountOut < minAmountOut) revert E.SlippageExceeded();

        return amountOut;
    }

    /// @notice Batch swap multiple hops (multi-hop routing)
    function batchSwap(
        IBAMM.SwapStep[] calldata steps,
        address receiver
    ) external payable nonReentrant whenNotPaused returns (uint256[] memory amounts) {
        require(steps.length > 0, "Empty steps");
        LibUtils.requireNonZero(receiver);

        amounts = new uint256[](steps.length);
        uint256 currentAmount = 0;

        for (uint256 i = 0; i < steps.length; ++i) {
            IBAMM.SwapStep calldata step = steps[i];
            uint256 amountIn = step.amountIn > 0 ? step.amountIn : currentAmount;

            if (amountIn == 0) revert E.ZeroAmount();

            // Route to final receiver if last step, otherwise to this contract for intermediate swaps
            address stepReceiver = i == steps.length - 1 ? receiver : address(this);

            // Call internal swap to avoid reentrancy issues
            currentAmount = _swap(step.tokenIn, step.tokenOut, amountIn, step.minAmountOut, stepReceiver);
            amounts[i] = currentAmount;
        }

        return amounts;
    }

    // ========== SWAP INTERNALS ==========

    function _swapDirect(
        IBAMM.BAMMStorage storage $,
        address tokenIn,
        address tokenOut,
        address base,
        uint256 amountIn,
        address receiver
    ) private returns (uint256 amountOut) {
        // Asset fetching
        IBAMM.Asset storage assetIn = $.assets[tokenIn];
        IBAMM.Asset storage assetOut = $.assets[tokenOut];

        // Reserve checks
        if (assetIn.reserves == 0 || assetOut.reserves == 0) revert E.InsufficientReserves();

        // Decay updates
        LibLiability.updateDecay(tokenIn);
        LibLiability.updateDecay(tokenOut);

        // Route quote via pricing facet
        bytes memory priceData = _delegateTo(
            pricingFacet,
            abi.encodeWithSignature(
                "quoteRouteDirect(address,address,address,uint256)",
                tokenIn, tokenOut, base, amountIn
            )
        );
        (P.RouteQuote memory rq) = abi.decode(priceData, (P.RouteQuote));
        amountOut = rq.amountOut;

        // Execute swap
        _executeDirectSwap($, tokenIn, tokenOut, amountIn, rq, receiver);

        return amountOut;
    }

    function _swapTriangulated(
        IBAMM.BAMMStorage storage $,
        address tokenIn,
        address tokenOut,
        address base,
        uint256 amountIn,
        address receiver
    ) private returns (uint256 amountOut) {
        // Asset fetching
        IBAMM.Asset storage assetIn = $.assets[tokenIn];
        IBAMM.Asset storage assetOut = $.assets[tokenOut];

        if (assetIn.reserves == 0 || assetOut.reserves == 0) revert E.InsufficientReserves();

        // Decay for all three assets
        LibLiability.updateDecay(tokenIn);
        LibLiability.updateDecay(tokenOut);
        LibLiability.updateDecay(base);

        // Route quote via pricing facet
        bytes memory priceData = _delegateTo(
            pricingFacet,
            abi.encodeWithSignature(
                "quoteRouteTriangulated(address,address,address,uint256)",
                tokenIn, tokenOut, base, amountIn
            )
        );
        (P.RouteQuote memory rq) = abi.decode(priceData, (P.RouteQuote));
        amountOut = rq.amountOut;

        // Execute swap
        _executeTriangulatedSwap($, tokenIn, tokenOut, base, amountIn, rq, receiver);

        return amountOut;
    }

    // ========== EXECUTION HELPERS ==========

    function _executeDirectSwap(
        IBAMM.BAMMStorage storage $,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        P.RouteQuote memory rq,
        address receiver
    ) private {
        IBAMM.Asset storage assetIn = $.assets[tokenIn];
        IBAMM.Asset storage assetOut = $.assets[tokenOut];

        // Check reserves
        if (rq.amountOut > assetOut.reserves) revert E.InsufficientReserves();
        if (assetOut.reserves - rq.amountOut < $.riskConfigs[tokenOut].minLiquidity) {
            revert E.BelowMinimumLiquidity();
        }

        // Store old reserves
        uint128 oldIn = assetIn.reserves;
        uint128 oldOut = assetOut.reserves;

        // Pull tokenIn
        uint256 actualAmountIn = _pullToken(tokenIn, msg.sender, amountIn);

        // Update reserves
        assetIn.reserves = (uint256(oldIn) + actualAmountIn - rq.protocolFeeIn).toUint128();
        assetOut.reserves = (uint256(oldOut) - rq.amountOut).toUint128();

        // Protocol fees
        if (rq.protocolFeeIn > 0) $.protocolFees[tokenIn] += rq.protocolFeeIn;

        // Push tokens to receiver
        tokenOut.safeTransfer(receiver, rq.amountOut);

        // Emit event
        emit IBAMM.Swapped(msg.sender, receiver, tokenIn, tokenOut, amountIn, rq.amountOut, rq.feeBps);
    }

    function _executeTriangulatedSwap(
        IBAMM.BAMMStorage storage $,
        address tokenIn,
        address tokenOut,
        address base,
        uint256 amountIn,
        P.RouteQuote memory rq,
        address receiver
    ) private {
        IBAMM.Asset storage assetIn = $.assets[tokenIn];
        IBAMM.Asset storage assetOut = $.assets[tokenOut];
        IBAMM.Asset storage assetBase = $.assets[base];

        // Check all reserves
        if (rq.amountOut > assetOut.reserves) revert E.InsufficientReserves();
        if (assetOut.reserves - rq.amountOut < $.riskConfigs[tokenOut].minLiquidity) {
            revert E.BelowMinimumLiquidity();
        }

        // Store old reserves
        uint128 oldIn = assetIn.reserves;
        uint128 oldOut = assetOut.reserves;

        // Pull tokenIn
        uint256 actualAmountIn = _pullToken(tokenIn, msg.sender, amountIn);

        // ✅ CRITICAL FIX #3: Accrue fees to both legs for fair LP yield distribution
        // Update reserves for both legs
        assetIn.reserves = (uint256(oldIn) + actualAmountIn - rq.protocolFeeIn).toUint128();
        assetBase.reserves += uint128(rq.amountBase);
        // Note: protocolFeeOut stays in pool (doesn't get transferred to user)
        assetOut.reserves = (uint256(oldOut) - rq.amountOut - rq.protocolFeeOut).toUint128();

        // Accrue protocol fees to BOTH legs
        if (rq.protocolFeeIn > 0) $.protocolFees[tokenIn] += rq.protocolFeeIn;
        if (rq.protocolFeeOut > 0) $.protocolFees[tokenOut] += rq.protocolFeeOut;

        // Push tokens to receiver (net amount, fees stay in pool for LPs)
        tokenOut.safeTransfer(receiver, rq.amountOut);

        // Emit events
        emit IBAMM.SwappedTwoLeg(
            msg.sender, receiver, tokenIn, base, tokenOut,
            amountIn, rq.amountOut, rq.feeBps, rq.feeBps
        );
    }

    // ========== HOT PATH: DEPOSIT ==========

    /// @notice Deposit single asset for LP tokens
    function deposit(
        address token,
        uint256 amount,
        uint256 minLpTokens
    ) external payable nonReentrant whenNotPaused returns (uint256 lpTokens) {
        if (token == address(0)) revert E.InvalidParameter();
        if (amount == 0) revert E.ZeroAmount();

        IBAMM.BAMMStorage storage $ = S.bamm();
        IBAMM.Asset storage asset = $.assets[token];
        IBAMM.RiskConfig storage risk = $.riskConfigs[token];
        IBAMM.LPState storage lp = $.lpStates[token];

        // ✅ CRITICAL FIX #4: Update decay BEFORE LP math (prevents time-decay arbitrage)
        LibLiability.updateDecay(token);

        // Validate deposit is enabled
        if (S._isFrozen(risk)) revert E.AssetFrozen();

        // Calculate LP tokens (simplified)
        if (lp.totalScaledSupply == 0) {
            lpTokens = amount;
            lp.liquidityIndex = 1e18;
            lp.totalScaledSupply = uint128(amount);
        } else {
            uint256 scaled = (amount * 1e18) / lp.liquidityIndex;
            lpTokens = scaled;
            lp.totalScaledSupply += uint128(scaled);
        }

        require(lpTokens >= minLpTokens, "Insufficient LP tokens");

        // Pull token from sender
        _pullToken(token, msg.sender, amount);

        // Update reserves and mint LP tokens
        asset.reserves += uint128(amount);
        $.scaledBalances[token][msg.sender] += lpTokens;

        emit IBAMM.Deposited(msg.sender, token, amount, lpTokens);
        return lpTokens;
    }

    // ========== HOT PATH: WITHDRAW ==========

    /// @notice Withdraw asset by burning LP tokens
    function withdraw(
        address token,
        uint256 lpTokens,
        uint256 minAmountOut
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (token == address(0)) revert E.InvalidParameter();
        if (lpTokens == 0) revert E.ZeroAmount();

        IBAMM.BAMMStorage storage $ = S.bamm();
        IBAMM.Asset storage asset = $.assets[token];
        IBAMM.LPState storage lp = $.lpStates[token];

        // ✅ CRITICAL FIX #4: Update decay BEFORE LP math (prevents time-decay arbitrage)
        LibLiability.updateDecay(token);

        require($.scaledBalances[token][msg.sender] >= lpTokens, "Insufficient balance");

        // Calculate withdrawal amount
        amountOut = (lpTokens * lp.liquidityIndex) / 1e18;
        require(amountOut <= asset.reserves, "Insufficient reserves");
        require(amountOut >= minAmountOut, "Slippage exceeded");

        // Apply withdrawal fee
        uint256 feeAmount = (amountOut * asset.fees.withdrawalFeeBps) / 1_000_000;
        uint256 netAmount = amountOut - feeAmount;

        // Update state
        asset.reserves -= uint128(amountOut);
        $.scaledBalances[token][msg.sender] -= lpTokens;
        lp.totalScaledSupply -= uint128(lpTokens);
        $.protocolFees[token] += feeAmount;

        // Transfer tokens to sender
        token.safeTransfer(msg.sender, netAmount);

        emit IBAMM.Withdrawn(msg.sender, token, lpTokens, netAmount, asset.fees.withdrawalFeeBps);
        return netAmount;
    }

    // ========== LP TOKEN ORACLE INTERFACE ==========

    /// @notice Get rebased LP balance
    function lpBalanceOf(address asset, address account) external view returns (uint256) {
        IBAMM.BAMMStorage storage $ = S.bamm();
        IBAMM.LPState storage lp = $.lpStates[asset];
        uint256 scaled = $.scaledBalances[asset][account];
        return (scaled * lp.liquidityIndex) / 1e18;
    }

    /// @notice Get rebased LP total supply
    function lpTotalSupply(address asset) external view returns (uint256) {
        IBAMM.BAMMStorage storage $ = S.bamm();
        IBAMM.LPState storage lp = $.lpStates[asset];
        return (lp.totalScaledSupply * lp.liquidityIndex) / 1e18;
    }

    /// @notice Transfer LP tokens (with access control - only LP token or Core allowed)
    /// @dev CRITICAL #8 VERIFIED: Access control prevents unauthorized minting
    function lpTransfer(address asset, address from, address to, uint256 amount) external {
        IBAMM.BAMMStorage storage $ = S.bamm();
        require(msg.sender == $.lpTokens[asset] || msg.sender == address(this), "Unauthorized LP transfer");

        IBAMM.LPState storage lp = $.lpStates[asset];
        uint256 scaled = (amount * 1e18) / lp.liquidityIndex;
        require($.scaledBalances[asset][from] >= scaled, "Insufficient balance");
        $.scaledBalances[asset][from] -= scaled;
        $.scaledBalances[asset][to] += scaled;
    }

    /// @notice Mint LP tokens (only LP token contract or Core allowed)
    function lpMint(address asset, address to, uint256 amount) external {
        IBAMM.BAMMStorage storage $ = S.bamm();
        require(msg.sender == $.lpTokens[asset] || msg.sender == address(this), "Unauthorized LP mint");

        IBAMM.LPState storage lp = $.lpStates[asset];
        uint256 scaled = (amount * 1e18) / lp.liquidityIndex;
        $.scaledBalances[asset][to] += scaled;
        lp.totalScaledSupply += uint128(scaled);
    }

    /// @notice Burn LP tokens (only LP token contract or Core allowed)
    function lpBurn(address asset, address from, uint256 amount) external {
        IBAMM.BAMMStorage storage $ = S.bamm();
        require(msg.sender == $.lpTokens[asset] || msg.sender == address(this), "Unauthorized LP burn");

        IBAMM.LPState storage lp = $.lpStates[asset];
        uint256 scaled = (amount * 1e18) / lp.liquidityIndex;
        require($.scaledBalances[asset][from] >= scaled, "Insufficient balance");
        $.scaledBalances[asset][from] -= scaled;
        lp.totalScaledSupply -= uint128(scaled);
    }

    /// @notice Register LP token for an asset (admin only)
    function setLPToken(address asset, address lpToken) external onlyOwner {
        IBAMM.BAMMStorage storage $ = S.bamm();
        $.lpTokens[asset] = lpToken;
    }

    // ========== VIEW FUNCTIONS ==========

    function getAsset(address token) external view returns (IBAMM.Asset memory) {
        return S.bamm().assets[token];
    }

    function getLPState(address token) external view returns (IBAMM.LPState memory) {
        return S.bamm().lpStates[token];
    }

    // ========== INTERNAL HELPERS ==========

    /// @notice Pull token from sender with FOT handling
    function _pullToken(address token, address from, uint256 amount) private returns (uint256 actual) {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 resultBalance = token.balanceOf(address(this));
        actual = resultBalance - before;
        return actual;
    }

}
