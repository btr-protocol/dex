// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IRouterV1
/// @notice Batch swap quoting interface
interface IRouterV1 {
    /// @notice Batch quote result
    struct BatchQuote {
        uint256 totalValueIn;     // Total input value in base terms (1e18)
        uint256[] amountsOut;     // Expected output per token (after impact)
        uint256[] minAmountsOut;  // With slippage applied
        uint256 avgSpreadBps;     // Value-weighted average spread
    }

    /// @notice Quote batch swap: all inputs → virtual base → weighted outputs
    /// @dev Non-view due to transient cache, but does not persist state
    /// @param inputs Packed, 32 bytes each: [address(20) | uint64 amountB64(8) | reserved(4)]
    /// @param outputs Packed, 32 bytes each: [address(20) | uint16 weightBps(2) | uint16 slippageBps(2) | reserved(8)]
    /// @return quote Batch quote with expected outputs and fees
    function quoteBatchSwap(
        bytes calldata inputs,
        bytes calldata outputs
    ) external returns (BatchQuote memory quote);
}
