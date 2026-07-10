// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IRecenterHook} from "../../interfaces/IRecenterHook.sol";
import {RangeCLPool} from "./RangeCLPool.sol";

/// @title RecenterHook — shared after-swap recenter for volatile RangeCLPools.
/// @notice Bunni v2 inspiration (conceptual only): when spot drifts from the active
///         liquidity mid, burn the old range and mint a fresh ±10% band around spot.
///         No LDF, no hub accounting, no off-chain keeper — on-chain, lean, testnet-only.
/// @dev Do NOT vendor Bunni; their LDF/withdraw path was exploited (2025). We only reuse
///      the "shift range when drift exceeds threshold" idea.
contract RecenterHook is IRecenterHook {
    uint256 public constant RANGE_BPS = 1_000; // ±10%
    uint256 public constant DRIFT_BPS = 500; // 5%

    /// @inheritdoc IRecenterHook
    function afterSwap(address pool) external {
        // Only the pool itself may trigger (RangeCLPool calls with msg.sender == pool).
        if (msg.sender != pool) revert NotPool();
        RangeCLPool(pool).recenterIfNeeded(RANGE_BPS, DRIFT_BPS);
    }

    error NotPool();
}
