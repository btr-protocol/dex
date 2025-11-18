// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IRescuable
/// @notice Interface for emergency asset recovery
interface IRescuable {
    // ========== EVENTS ==========

    event RescueRequested(address indexed requester, address indexed token, uint256 amount);
    event RescueExecuted(address indexed receiver, address indexed token, uint256 amount);
    event RescueCancelled(address indexed requester, address indexed token);
}
