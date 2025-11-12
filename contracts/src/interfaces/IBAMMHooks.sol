// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC165} from "./IERC165.sol";

/// @title IBAMMHooks
/// @notice Minimal hook interface for BAMM lifecycle callbacks
/// @dev ALL 10 functions MUST be implemented (use empty implementations if not needed)
/// @dev Extends ERC-165 for proper interface detection via supportsInterface()
/// @dev Inspired by Aave's flashloan callback - simple and efficient
/// @dev ALL HOOKS FROM POOL PERSPECTIVE:
///      - preBuy/postBuy: Pool RECEIVES token (buys from user)
///      - preSell/postSell: Pool GIVES token (sells to user)
///      - preDeposit/postDeposit: Pool RECEIVES liquidity
///      - preWithdraw/postWithdraw: Pool GIVES liquidity back
///      - preFlashLoan/postFlashLoan: Pool LENDS then RECEIVES back (flash loan)
interface IBAMMHooks is IERC165 {
    // ========== LIQUIDITY HOOKS ==========

    /// @notice Called before pool receives deposit (pool perspective: RECEIVING)
    function preDeposit(address token, address depositor, uint256 amount, bytes calldata data) external returns (bytes4);

    /// @notice Called after pool received deposit (pool perspective: RECEIVED)
    function postDeposit(address token, address depositor, uint256 amount, uint256 lpTokens, bytes calldata data) external returns (bytes4);

    /// @notice Called before pool gives withdrawal (pool perspective: GIVING)
    /// @param data Can contain abi.encode(amountOut) for hooks that need to prepare liquidity
    function preWithdraw(address token, address withdrawer, uint256 lpTokens, bytes calldata data) external returns (bytes4);

    /// @notice Called after pool gave withdrawal (pool perspective: GAVE)
    function postWithdraw(address token, address withdrawer, uint256 lpTokens, uint256 amount, bytes calldata data) external returns (bytes4);

    // ========== SWAP HOOKS (POOL PERSPECTIVE!) ==========

    /// @notice Pool is BUYING (receiving) this token from user
    /// @param token Token pool is receiving
    function preBuy(address token, address buyer, uint256 expectedAmount, address tokenIn, uint256 amountIn, bytes calldata data) external returns (bytes4);

    /// @notice Pool just BOUGHT (received) this token from user
    /// @param token Token pool received
    function postBuy(address token, address buyer, uint256 amountOut, address tokenIn, uint256 amountIn, bytes calldata data) external returns (bytes4);

    /// @notice Pool is SELLING (giving) this token to user
    /// @param token Token pool is giving
    function preSell(address token, address seller, uint256 amountIn, address tokenOut, uint256 expectedOut, bytes calldata data) external returns (bytes4);

    /// @notice Pool just SOLD (gave) this token to user
    /// @param token Token pool gave
    function postSell(address token, address seller, uint256 amountIn, address tokenOut, uint256 amountOut, bytes calldata data) external returns (bytes4);

    // ========== FLASH LOAN HOOKS ==========

    /// @notice Called before pool lends tokens via flash loan (pool perspective: LENDING)
    /// @param token Token being flash loaned
    /// @param receiver Address receiving the flash loan
    /// @param amount Amount being flash loaned
    /// @param fee Fee that will be charged
    /// @param data Arbitrary data passed through flash loan
    /// @return Function selector to validate hook execution
    function preFlashLoan(address token, address receiver, uint256 amount, uint256 fee, bytes calldata data) external returns (bytes4);

    /// @notice Called after pool received repayment from flash loan (pool perspective: RECEIVED BACK)
    /// @param token Token that was flash loaned
    /// @param receiver Address that received the flash loan
    /// @param amount Amount that was flash loaned
    /// @param fee Fee that was charged
    /// @param data Arbitrary data passed through flash loan
    /// @return Function selector to validate hook execution
    function postFlashLoan(address token, address receiver, uint256 amount, uint256 fee, bytes calldata data) external returns (bytes4);
}
