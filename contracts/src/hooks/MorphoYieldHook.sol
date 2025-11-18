// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseBAMMHook} from "./BaseBAMMHook.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IBAMM} from "../interfaces/IBAMM.sol";

/// @title MorphoYieldHook
/// @notice Hook that automatically deposits reserves into Morpho MetaMorpho vaults and withdraws proportionally
/// @dev Works with MetaMorpho curated vaults (e.g., Gauntlet USDC Core, Steakhouse USDC)
/// @dev Uses ERC-4626 standard: deposit() mints shares, redeem() burns shares for assets
/// @dev KEY INSIGHT: Vault shares represent proportional claim on growing asset pool
///      Share value increases over time as yield accrues, unlike aTokens which rebase
contract MorphoYieldHook is BaseBAMMHook {
    IERC4626 public immutable vault;      // MetaMorpho vault (ERC-4626)
    address public immutable asset;       // Underlying asset (e.g., USDC)

    error InsufficientLiquidity();

    constructor(address _bamm, address _asset, address _vault) BaseBAMMHook(_bamm) {
        asset = _asset;
        vault = IERC4626(_vault);

        // Verify vault uses correct asset
        require(vault.asset() == _asset, "Vault asset mismatch");
    }

    // ========== LIQUIDITY HOOKS ==========

    /// @notice Deposit new liquidity into MetaMorpho vault for yield
    /// @dev Called AFTER BAMM updates reserves - deposit the amount that was added
    /// @dev deposit() mints vault shares to bamm address
    function postDeposit(
        address,
        address,
        uint256 amount,
        uint256,
        bytes calldata
    ) public override onlyBAMM returns (bytes4) {
        // Approve and deposit to vault (receives shares in return)
        IERC20(asset).approve(address(vault), amount);
        vault.deposit(amount, bamm);  // assets, receiver
        return this.postDeposit.selector;
    }

    /// @notice Withdraw from MetaMorpho BEFORE BAMM tries to transfer to user
    /// @dev Called BEFORE BAMM calculates amountOut and transfers
    /// @dev Uses redeem() to burn shares and receive underlying assets
    function preWithdraw(
        address _token,
        address /* user */,
        uint256 lpTokens,
        bytes calldata
    ) public override onlyBAMM returns (bytes4) {
        // Calculate max possible withdrawal (assumes C=1)
        IBAMM ibamm = IBAMM(bamm);
        IBAMM.LPState memory lpState = ibamm.lpStates(_token);
        (,, uint128 reserves,,,) = ibamm.getAssetState(_token);

        uint256 M_PRECISION = 1e18;
        uint256 scaledAmount = (lpTokens * M_PRECISION) / lpState.liquidityIndex;
        uint256 maxWithdrawal = (scaledAmount * lpState.liquidityIndex * uint256(reserves)) /
                                (lpState.totalScaledSupply * M_PRECISION);

        // Ensure BAMM has enough balance
        uint256 bammBalance = IERC20(asset).balanceOf(bamm);
        if (bammBalance < maxWithdrawal) {
            uint256 needed = maxWithdrawal - bammBalance;

            // Convert needed assets to shares and redeem
            uint256 sharesToRedeem = vault.previewWithdraw(needed);
            vault.redeem(sharesToRedeem, bamm, bamm);  // shares, receiver, owner
        }

        return this.preWithdraw.selector;
    }

    // ========== SWAP HOOKS ==========

    /// @notice Withdraw from vault if BAMM needs liquidity for swap
    /// @dev Called BEFORE swap executes to ensure BAMM has enough balance
    function preBuy(
        address,
        address,
        uint256 expectedAmount,
        address,
        uint256,
        bytes calldata
    ) public override onlyBAMM returns (bytes4) {
        uint256 bammBalance = IERC20(asset).balanceOf(bamm);
        if (bammBalance < expectedAmount) {
            uint256 needed = expectedAmount - bammBalance;

            // Convert needed assets to shares and redeem
            uint256 sharesToRedeem = vault.previewWithdraw(needed);
            vault.redeem(sharesToRedeem, bamm, bamm);
        }
        return this.preBuy.selector;
    }

    /// @notice Deposit newly received tokens into vault for yield
    /// @dev Called AFTER swap completes - deposit what was received
    function postSell(
        address,
        address,
        uint256 amountIn,
        address,
        uint256,
        bytes calldata
    ) public override onlyBAMM returns (bytes4) {
        IERC20(asset).approve(address(vault), amountIn);
        vault.deposit(amountIn, bamm);
        return this.postSell.selector;
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Get current vault share balance
    /// @dev Shares represent proportional claim on vault assets
    function getVaultShares() external view returns (uint256) {
        return vault.balanceOf(bamm);
    }

    /// @notice Get total asset value (shares converted to assets)
    /// @dev This shows total value including accrued yield
    function getTotalAssetValue() external view returns (uint256) {
        uint256 shares = vault.balanceOf(bamm);
        return vault.convertToAssets(shares);
    }

    /// @notice Get accrued yield from MetaMorpho
    /// @dev yield = current asset value - BAMM recorded reserves
    function getAccruedYield() external view returns (uint256) {
        (,, uint128 reserves,,,) = IBAMM(bamm).getAssetState(asset);
        uint256 shares = vault.balanceOf(bamm);
        uint256 currentValue = vault.convertToAssets(shares);
        return currentValue > uint256(reserves) ? currentValue - uint256(reserves) : 0;
    }

    /// @notice Get current vault APY and utilization (if available)
    /// @dev Note: Not all vaults expose this data on-chain
    function getVaultMetrics() external view returns (uint256 totalAssets, uint256 totalSupply) {
        totalAssets = vault.totalAssets();
        totalSupply = vault.totalSupply();
        // APY calculation: (totalAssets / totalSupply - 1) * blocksPerYear / blocksSinceInception
    }
}
