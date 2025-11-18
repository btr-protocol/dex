// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseBAMMHook} from "./BaseBAMMHook.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IBAMM} from "../interfaces/IBAMM.sol";

/// @title AaveYieldHook
/// @notice Hook that automatically deposits reserves into Aave and withdraws proportionally
/// @dev Properly handles coverage ratio haircuts and Aave aToken balance growth
/// @dev KEY INSIGHT: Since aTokens ARE the reserves, user's LP share maps directly to aToken amount
///      This naturally applies the coverage haircut since LP shares convert to reserves, not liabilities
contract AaveYieldHook is BaseBAMMHook {
    IPool public immutable aavePool;
    address public immutable token;
    address public immutable aToken;  // Aave interest-bearing token

    error InsufficientLiquidity();

    constructor(address _bamm, address _token, address _aavePool, address _aToken) BaseBAMMHook(_bamm) {
        token = _token;
        aavePool = IPool(_aavePool);
        aToken = _aToken;
    }

    // ========== LIQUIDITY HOOKS ==========

    /// @notice Deposit new liquidity into Aave for yield
    /// @dev Called AFTER BAMM updates reserves - deposit the amount that was added
    function postDeposit(
        address,
        address,
        uint256 amount,
        uint256,
        bytes calldata
    ) public override onlyBAMM returns (bytes4) {
        // Approve and supply to Aave (receives aTokens in return)
        IERC20(token).approve(address(aavePool), amount);
        aavePool.supply(token, amount, bamm, 0);
        return this.postDeposit.selector;
    }

    /// @notice Withdraw from Aave BEFORE BAMM tries to transfer to user
    /// @dev Called BEFORE BAMM calculates amountOut and transfers
    /// @dev Simplified approach: Just ensure BAMM has enough balance for the withdrawal
    /// @dev The coverage haircut is automatically handled by BAMM's withdraw logic
    /// @param lpTokens Amount of LP tokens being burned
    function preWithdraw(
        address _token,
        address /* user */,
        uint256 lpTokens,
        bytes calldata
    ) public override onlyBAMM returns (bytes4) {
        // SIMPLIFIED APPROACH:
        // The LP share calculation and coverage haircut is complex and duplicates BAMM logic.
        // Instead, we rely on BAMM's accounting and just ensure sufficient balance exists.
        //
        // KEY INSIGHT: BAMM's reserves track the aToken balance (which grows with yield).
        // When user withdraws, their LP share naturally includes the yield growth
        // because the reserves (= aToken balance) have grown.
        //
        // We withdraw conservatively: up to the LP value at current reserves
        // BAMM will calculate the exact amount and handle the coverage haircut.

        // Simple heuristic: Withdraw enough to cover potential withdrawal
        // In worst case (C=1, no fees), LP share = (lpTokens / totalLP) * reserves
        // We estimate and withdraw conservatively

        IBAMM ibamm = IBAMM(bamm);
        IBAMM.LPState memory lpState = ibamm.lpStates(_token);

        // Get asset state (reserves, liabilities, etc)
        (,, uint128 reserves,,,) = ibamm.getAssetState(_token);

        // Calculate max possible withdrawal (assumes C=1)
        uint256 M_PRECISION = 1e18;
        uint256 scaledAmount = (lpTokens * M_PRECISION) / lpState.liquidityIndex;
        uint256 maxWithdrawal = (scaledAmount * lpState.liquidityIndex * uint256(reserves)) /
                                (lpState.totalScaledSupply * M_PRECISION);

        // Ensure BAMM has enough balance
        uint256 bammBalance = IERC20(token).balanceOf(bamm);
        if (bammBalance < maxWithdrawal) {
            uint256 needed = maxWithdrawal - bammBalance;
            aavePool.withdraw(token, needed, bamm);
        }

        return this.preWithdraw.selector;
    }

    // ========== SWAP HOOKS ==========

    /// @notice Withdraw from Aave if BAMM needs liquidity for swap
    /// @dev Called BEFORE swap executes to ensure BAMM has enough balance
    function preBuy(
        address,
        address,
        uint256 expectedAmount,
        address,
        uint256,
        bytes calldata
    ) public override onlyBAMM returns (bytes4) {
        uint256 bammBalance = IERC20(token).balanceOf(bamm);
        if (bammBalance < expectedAmount) {
            uint256 needed = expectedAmount - bammBalance;
            aavePool.withdraw(token, needed, bamm);
        }
        return this.preBuy.selector;
    }

    /// @notice Deposit newly received tokens into Aave for yield
    /// @dev Called AFTER swap completes - deposit what was received
    function postSell(
        address,
        address,
        uint256 amountIn,
        address,
        uint256,
        bytes calldata
    ) public override onlyBAMM returns (bytes4) {
        IERC20(token).approve(address(aavePool), amountIn);
        aavePool.supply(token, amountIn, bamm, 0);
        return this.postSell.selector;
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Get current aToken balance (reserves + accrued yield)
    /// @dev This shows total value including Aave yield
    function getAaveBalance() external view returns (uint256) {
        return IERC20(aToken).balanceOf(bamm);
    }

    /// @notice Get accrued yield from Aave
    /// @dev yield = aToken balance - BAMM recorded reserves
    function getAccruedYield() external view returns (uint256) {
        (,, uint128 reserves,,,) = IBAMM(bamm).getAssetState(token);
        uint256 aTokenBalance = IERC20(aToken).balanceOf(bamm);
        return aTokenBalance > uint256(reserves) ? aTokenBalance - uint256(reserves) : 0;
    }

    // All other hooks inherit no-op implementations from BaseBAMMHook
}
