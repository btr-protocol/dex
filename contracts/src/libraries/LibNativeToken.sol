// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {WETH} from "solady/tokens/WETH.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title LibNativeToken
/// @notice Utility library for handling native gas token (ETH/MATIC/etc) with ERC20 wrapping
/// @dev Implements EIP-7528: uses 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE as native token sentinel
/// @dev All native operations are transparently wrapped to WETH for internal ERC20 accounting
/// @dev This allows supporting native gas tokens across all DEX operations (swap, deposit, etc)
///      at minimal overhead while keeping internal accounting simple (ERC20-only)
library LibNativeToken {
    using SafeTransferLib for address;

    // ========== CONSTANTS ==========

    /// @notice EIP-7528 sentinel address for native gas token (ETH/MATIC/AVAX/etc)
    /// @dev Users pass this address to indicate they want to use native tokens
    address internal constant NATIVE_TOKEN_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // ========== ERRORS ==========

    error ETHTransferFailed();
    error WETHNotSet();
    error InsufficientETHSent();

    // ========== PUBLIC INTERFACE ==========

    /// @notice Check if token address represents native gas token
    /// @param token Token address to check
    /// @return True if token is native sentinel (0xEee...eEeE)
    function isNative(address token) internal pure returns (bool) {
        return token == NATIVE_TOKEN_SENTINEL;
    }

    /// @notice Get the actual token address to use for accounting
    /// @dev If native sentinel, returns WETH address; otherwise returns original token
    /// @param token Original token address (may be native sentinel)
    /// @param weth WETH contract address
    /// @return Actual ERC20 address to use for internal accounting
    function getActualToken(address token, address weth) internal pure returns (address) {
        return isNative(token) ? weth : token;
    }

    /// @notice Pull tokens from sender, wrapping if native
    /// @dev Handles both ERC20 and native token deposits
    /// @param token Original token address (may be native sentinel)
    /// @param from Address to pull ERC20 tokens from (ignored for native)
    /// @param to Address to send wrapped tokens to
    /// @param amount Amount to transfer
    /// @param weth WETH contract address
    /// @return actualToken The actual ERC20 address used (WETH if native, original if not)
    function pullToken(
        address token,
        address from,
        address to,
        uint256 amount,
        address weth
    ) internal returns (address actualToken) {
        if (amount == 0) return getActualToken(token, weth);

        if (isNative(token)) {
            // Native token: verify msg.value and wrap to WETH
            if (msg.value < amount) revert InsufficientETHSent();

            // Wrap ETH to WETH
            WETH(payable(weth)).deposit{value: amount}();

            // Transfer WETH to destination if not this contract
            if (to != address(this)) {
                weth.safeTransfer(to, amount);
            }

            // Return excess ETH if msg.value > amount
            if (msg.value > amount) {
                _safeTransferETH(from, msg.value - amount);
            }

            return weth;
        } else {
            // ERC20 token: standard transfer
            token.safeTransferFrom(from, to, amount);
            return token;
        }
    }

    /// @notice Push tokens to recipient, unwrapping if native
    /// @dev Handles both ERC20 and native token withdrawals
    /// @param token Original token address (may be native sentinel)
    /// @param from Address holding the tokens (must be this contract for native)
    /// @param to Recipient address
    /// @param amount Amount to transfer
    /// @param weth WETH contract address
    function pushToken(
        address token,
        address from,
        address to,
        uint256 amount,
        address weth
    ) internal {
        if (amount == 0) return;

        if (isNative(token)) {
            // Native token: unwrap WETH and send ETH

            // If tokens not already in this contract, pull them first
            if (from != address(this)) {
                weth.safeTransferFrom(from, address(this), amount);
            }

            // Unwrap WETH to ETH
            WETH(payable(weth)).withdraw(amount);

            // Send ETH to recipient
            _safeTransferETH(to, amount);
        } else {
            // ERC20 token: standard transfer
            if (from == address(this)) {
                token.safeTransfer(to, amount);
            } else {
                token.safeTransferFrom(from, to, amount);
            }
        }
    }

    /// @notice Pull and wrap native token in single operation (for deposits)
    /// @dev Optimized path for deposit flows where tokens stay in contract
    /// @param token Original token address (may be native sentinel)
    /// @param from Address to pull ERC20 from (ignored for native)
    /// @param amount Amount to transfer
    /// @param weth WETH contract address
    /// @return actualToken The actual ERC20 address (WETH if native)
    function pullAndWrap(
        address token,
        address from,
        uint256 amount,
        address weth
    ) internal returns (address actualToken) {
        return pullToken(token, from, address(this), amount, weth);
    }

    /// @notice Unwrap and push native token in single operation (for withdrawals)
    /// @dev Optimized path for withdrawal flows
    /// @param token Original token address (may be native sentinel)
    /// @param to Recipient address
    /// @param amount Amount to transfer
    /// @param weth WETH contract address
    function unwrapAndPush(
        address token,
        address to,
        uint256 amount,
        address weth
    ) internal {
        pushToken(token, address(this), to, amount, weth);
    }

    // ========== INTERNAL HELPERS ==========

    /// @notice Safe ETH transfer with proper error handling
    /// @param to Recipient address
    /// @param amount Amount of ETH to send
    function _safeTransferETH(address to, uint256 amount) private {
        /// @solidity memory-safe-assembly
        assembly {
            // Transfer the ETH and check if it succeeded or not.
            if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, 0xb12d13eb) // `ETHTransferFailed()`.
                revert(0x1c, 0x04)
            }
        }
    }
}
