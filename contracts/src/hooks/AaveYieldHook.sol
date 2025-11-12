// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseBAMMHook} from "./BaseBAMMHook.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title AaveYieldHook
/// @notice Hook that automatically deposits all reserves into Aave for yield generation
/// @dev Deposits 100% of reserves to maximize yield. For production use with buffer (e.g., keep 10% in pool),
///      add a configurable buffer percentage parameter and modify deposit calculations accordingly.

contract AaveYieldHook is BaseBAMMHook {
    IPool public immutable aavePool;
    address public immutable token;

    error InsufficientLiquidity();

    constructor(address _bamm, address _token, address _aavePool) BaseBAMMHook(_bamm) {
        token = _token;
        aavePool = IPool(_aavePool);
    }

    // ========== LIQUIDITY HOOKS ==========

    /// @dev Deposit all new liquidity into Aave for yield
    /// @notice For configurable buffer, add a buffer parameter and use: depositAmount = (amount * (100 - bufferPct)) / 100
    function postDeposit(
        address,
        address,
        uint256 amount,
        uint256,
        bytes calldata
    ) public override onlyBAMM returns (bytes4) {
        IERC20(token).approve(address(aavePool), amount);
        aavePool.supply(token, amount, bamm, 0);
        return this.postDeposit.selector;
    }

    /// @dev Withdraw from Aave to cover user withdrawal
    function postWithdraw(
        address,
        address,
        uint256,
        uint256 amount,
        bytes calldata
    ) public override onlyBAMM returns (bytes4) {
        aavePool.withdraw(token, amount, bamm);
        return this.postWithdraw.selector;
    }

    // ========== SWAP HOOKS ==========

    /// @dev Withdraw from Aave if BAMM needs liquidity for swap
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

    /// @dev Deposit all newly received tokens into Aave for yield
    /// @notice For configurable buffer, add a buffer parameter and use: depositAmount = (amountIn * (100 - bufferPct)) / 100
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

    // All other hooks inherit no-op implementations from BaseBAMMHook
}
