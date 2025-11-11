// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IDarkPool} from "../interfaces/IDarkPool.sol";
import {LibDarkPoolStorage as LibStorage} from "./LibDarkPoolStorage.sol";
import {DarkPoolErrors as Errors} from "../darkpool/DarkPoolErrors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title LibBAMM
/// @notice Helper library for BAMM interactions from DarkPool
library LibBAMM {
    using SafeTransferLib for address;

    // ========== CONSTANTS ==========

    uint256 constant PRECISION = LibStorage.PRECISION;

    // ========== ACTIONS ==========

    /// @notice Execute external actions based on action type
    /// @param extData External action parameters
    /// @param sender Address to pull extIn tokens from
    function executeActions(IDarkPool.ExtData calldata extData, address sender) internal {
        // CRITICAL: Pull extIn tokens from sender FIRST (before any state changes)
        _pullExternalTokens(extData, sender);

        uint8 actionType = extData.actionType;

        if (actionType == LibStorage.ACTION_TRANSFER) {
            _executeTransfer(extData);
        } else if (actionType == LibStorage.ACTION_SWAP) {
            _executeSwap(extData);
        } else if (actionType == LibStorage.ACTION_LP_DEPOSIT) {
            _executeLPDeposit(extData);
        } else if (actionType == LibStorage.ACTION_LP_WITHDRAW) {
            _executeLPWithdraw(extData);
        } else {
            revert Errors.InvalidActionType(actionType);
        }
    }

    /// @notice Pull external tokens (extIn) from sender
    /// @param extData External data
    /// @param sender Address to pull tokens from
    /// @dev This implements "public-to-private" deposits where users bring tokens into the pool
    function _pullExternalTokens(IDarkPool.ExtData calldata extData, address sender) private {
        for (uint256 i = 0; i < extData.assets.length; i++) {
            if (extData.extIn[i] > 0) {
                address token = extData.assets[i];
                uint256 amount = extData.extIn[i];

                // Pull tokens from sender to DarkPool
                token.safeTransferFrom(sender, address(this), amount);
            }
        }
    }

    // ========== TRANSFER ==========

    /// @notice Execute pure transfer (no BAMM interaction)
    /// @param extData External data
    function _executeTransfer(IDarkPool.ExtData calldata extData) private {
        // For pure transfers, just send extOut to receivers
        for (uint256 i = 0; i < extData.assets.length; i++) {
            if (extData.extOut[i] > 0 && i < extData.receivers.length && extData.receivers[i] != address(0)) {
                address token = extData.assets[i];
                uint256 amount = extData.extOut[i];
                address receiver = extData.receivers[i];

                token.safeTransfer(receiver, amount);
            }
        }
    }

    // ========== SWAP ==========

    /// @notice Execute swap on BAMM
    /// @param extData External data
    function _executeSwap(IDarkPool.ExtData calldata extData) private {
        LibStorage.DarkPoolStorage storage $ = LibStorage.getStorage();
        address bamm = $.bammPool;

        // Expect: extData.assets = [tokenIn, tokenOut]
        // extData.extOut[0] = amountIn to swap
        // extData.extIn[1] = minAmountOut (slippage protection)

        if (extData.assets.length < 2) revert Errors.ArrayLengthMismatch();

        address tokenIn = extData.assets[0];
        address tokenOut = extData.assets[1];
        uint256 amountIn = extData.extOut[0];
        uint256 minAmountOut = extData.extIn[1];

        // Safe approve pattern for non-standard tokens (e.g., USDT)
        _safeApprove(tokenIn, bamm, amountIn);

        // Execute swap
        uint256 amountOut = IBAMM(bamm).swap(
            tokenIn,
            tokenOut,
            amountIn,
            minAmountOut,
            address(this) // Receive to DarkPool
        );

        // If receiver specified, send out; otherwise keep in contract for re-shielding
        if (extData.receivers.length > 0 && extData.receivers[0] != address(0)) {
            tokenOut.safeTransfer(extData.receivers[0], amountOut);
        }
    }

    // ========== LP DEPOSIT ==========

    /// @notice Execute LP deposit to BAMM
    /// @param extData External data
    function _executeLPDeposit(IDarkPool.ExtData calldata extData) private {
        LibStorage.DarkPoolStorage storage $ = LibStorage.getStorage();
        address bamm = $.bammPool;

        // Expect: extData.assets = [token]
        // extData.extOut[0] = amount to deposit
        // extData.extIn[0] = minLpTokens (slippage protection)

        if (extData.assets.length < 1) revert Errors.EmptyArray();

        address token = extData.assets[0];
        uint256 amount = extData.extOut[0];
        uint256 minLpTokens = extData.extIn[0];

        // CHECKS: Read liquidityIndex BEFORE deposit (for correct accounting)
        IBAMM.LPState memory lpStateBefore = IBAMM(bamm).lpStates(token);
        uint128 liquidityIndexBefore = lpStateBefore.liquidityIndex;

        // INTERACTIONS: Approve and deposit (external calls)
        _safeApprove(token, bamm, amount);
        uint256 lpTokens = IBAMM(bamm).deposit(token, amount, minLpTokens);

        // CHECKS: Verify liquidityIndex hasn't changed unexpectedly (front-run protection)
        IBAMM.LPState memory lpStateAfter = IBAMM(bamm).lpStates(token);
        if (lpStateAfter.liquidityIndex != liquidityIndexBefore) {
            // Index changed - verify we got expected LP tokens based on new index
            uint256 expectedScaledShares = (lpTokens * PRECISION) / lpStateAfter.liquidityIndex;
            uint256 minScaledShares = (minLpTokens * PRECISION) / liquidityIndexBefore;

            if (expectedScaledShares < minScaledShares) {
                revert Errors.SlippageExceeded();
            }
        }

        // Note: LP tokens are held by DarkPool contract as ERC1155
        // Off-chain must compute scaledShares = (lpTokens * PRECISION) / liquidityIndex
        // and create LP note commitment with scaledShares

        // Emit event for off-chain tracking
        emit LPDeposited(token, amount, lpTokens, liquidityIndexBefore);
    }

    /// @notice Event for LP deposit tracking
    event LPDeposited(
        address indexed token,
        uint256 amountIn,
        uint256 lpTokensOut,
        uint128 liquidityIndex
    );

    // ========== LP WITHDRAW ==========

    /// @notice Execute LP withdraw from BAMM
    /// @param extData External data
    function _executeLPWithdraw(IDarkPool.ExtData calldata extData) private {
        LibStorage.DarkPoolStorage storage $ = LibStorage.getStorage();
        address bamm = $.bammPool;

        // Expect: extData.assets = [token]
        // extData.extIn[0] = scaledShares (from note)
        // extData.extOut[0] = minAmountOut (slippage protection)

        if (extData.assets.length < 1) revert Errors.EmptyArray();

        address token = extData.assets[0];
        uint256 scaledShares = extData.extIn[0];
        uint256 minAmountOut = extData.extOut[0];

        // Read liquidityIndex BEFORE withdraw
        IBAMM.LPState memory lpState = IBAMM(bamm).lpStates(token);
        uint128 liquidityIndex = lpState.liquidityIndex;

        // Compute LP tokens from scaled shares
        uint256 lpTokens = (scaledShares * liquidityIndex) / PRECISION;

        // Withdraw from BAMM (DarkPool must hold LP tokens as ERC1155)
        // Note: BAMM LP tokens are ERC1155, tokenId = uint256(uint160(token))
        uint256 amountOut = IBAMM(bamm).withdraw(token, lpTokens, minAmountOut);

        // If receiver specified, send out; otherwise keep for re-shielding
        if (extData.receivers.length > 0 && extData.receivers[0] != address(0)) {
            token.safeTransfer(extData.receivers[0], amountOut);
        }

        emit LPWithdrawn(token, lpTokens, amountOut, liquidityIndex);
    }

    /// @notice Event for LP withdraw tracking
    event LPWithdrawn(
        address indexed token,
        uint256 lpTokensIn,
        uint256 amountOut,
        uint128 liquidityIndex
    );

    // ========== HELPERS ==========

    /// @notice Safe approve with USDT-style token support
    /// @param token Token to approve
    /// @param spender Spender address
    /// @param amount Amount to approve
    /// @dev Some tokens (e.g., USDT) require setting allowance to 0 before changing it
    function _safeApprove(address token, address spender, uint256 amount) private {
        // Try to approve directly first
        (bool success, ) = token.call(
            abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), spender, amount)
        );

        if (!success) {
            // If approval failed, try resetting to 0 first (USDT pattern)
            token.safeApprove(spender, 0);
            token.safeApprove(spender, amount);
        }
    }

    /// @notice Compute LP tokens from scaled shares
    /// @param token Token address
    /// @param scaledShares Scaled shares amount
    /// @return lpTokens LP token amount
    function computeLPTokens(address token, uint256 scaledShares) internal view returns (uint256 lpTokens) {
        LibStorage.DarkPoolStorage storage $ = LibStorage.getStorage();
        address bamm = $.bammPool;

        IBAMM.LPState memory lpState = IBAMM(bamm).lpStates(token);
        lpTokens = (scaledShares * lpState.liquidityIndex) / PRECISION;
    }

    /// @notice Compute scaled shares from LP tokens
    /// @param token Token address
    /// @param lpTokens LP token amount
    /// @return scaledShares Scaled shares amount
    function computeScaledShares(address token, uint256 lpTokens) internal view returns (uint256 scaledShares) {
        LibStorage.DarkPoolStorage storage $ = LibStorage.getStorage();
        address bamm = $.bammPool;

        IBAMM.LPState memory lpState = IBAMM(bamm).lpStates(token);
        scaledShares = (lpTokens * PRECISION) / lpState.liquidityIndex;
    }
}
