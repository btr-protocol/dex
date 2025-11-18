// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {BAMMErrors} from "../bamm/BAMMErrors.sol";
import {IRescuable} from "../interfaces/IRescuable.sol";

/// @title Rescuable
/// @notice Emergency asset recovery mechanism with timelock
/// @dev Inherit this contract and restrict rescue functions to authorized roles
abstract contract Rescuable is IRescuable, ReentrancyGuard {
    using SafeTransferLib for address;

    // Timelock constants
    uint256 internal constant RESCUE_TIMELOCK = 4 days;
    uint256 internal constant RESCUE_WINDOW = 3 days;

    // Cached ERC20.balanceOf selector for gas efficiency
    bytes4 private constant BALANCE_OF_SELECTOR = 0x70a08231;

    /// @notice Rescue request with optimized storage packing
    /// @dev Packed into 3 slots: amount (32 bytes), token + timestamp (20 + 8 bytes), receiver (20 bytes)
    struct RescueRequest {
        uint256 amount;      // slot 0: snapshotted amount at request time
        address token;       // slot 1: token to rescue (address(0) for ETH)
        uint64 timestamp;    // slot 1: request creation time (packed with token)
        address receiver;    // slot 2: destination for rescued assets
    }

    mapping(address => RescueRequest) private _rescueRequests;

    /// @notice Request asset recovery with 4-day timelock and 3-day acceptance window
    /// @dev Snapshots the current balance; tokens sent after request are NOT included
    ///      Must be called by authorized address (enforced by child contract)
    ///      Prevents overwriting existing pending requests for safety
    /// @param token Token to rescue (address(0) for ETH)
    /// @param amount Amount to rescue (0 means snapshot entire balance)
    /// @param receiver Destination address (address(0) defaults to msg.sender)
    function _requestRescue(
        address token,
        uint256 amount,
        address receiver
    ) internal {
        // Prevent overwriting existing pending request
        if (_rescueRequests[msg.sender].timestamp != 0) {
            revert BAMMErrors.AlreadyInitialized();
        }

        // Default receiver to msg.sender if not specified
        address to = receiver == address(0) ? msg.sender : receiver;
        if (to == address(0)) revert BAMMErrors.ZeroAddress();

        // Snapshot available balance
        uint256 available = token == address(0) ?
            address(this).balance :
            _balanceOf(token, address(this));

        // If amount is 0, snapshot entire balance; otherwise validate specified amount
        uint256 rescueAmount = amount == 0 ? available : amount;
        if (rescueAmount == 0 || rescueAmount > available) revert BAMMErrors.ZeroAmount();

        _rescueRequests[msg.sender] = RescueRequest({
            amount: rescueAmount,
            token: token,
            timestamp: uint64(block.timestamp),
            receiver: to
        });

        emit RescueRequested(msg.sender, token, rescueAmount);
    }

    /// @notice Execute rescue after timelock expires
    /// @dev Follows CEI pattern: validates, updates state, then transfers
    ///      Clamps payout to current balance to handle protocol fee accumulation changes
    ///      Anyone can execute (receiver is pre-committed at request time)
    function _executeRescue() internal nonReentrant {
        RescueRequest storage r = _rescueRequests[msg.sender];

        // Verify request exists and is within valid execution window
        if (r.timestamp == 0) revert BAMMErrors.NotInitialized();

        uint256 unlockTime = uint256(r.timestamp) + RESCUE_TIMELOCK;
        if (block.timestamp < unlockTime) revert BAMMErrors.Locked();
        if (block.timestamp > unlockTime + RESCUE_WINDOW) revert BAMMErrors.Expired();

        // Cache values before deletion (CEI pattern)
        address token = r.token;
        address receiver = r.receiver;
        uint256 requestedAmount = r.amount;

        // Validate current balance and clamp payout
        uint256 available = token == address(0) ?
            address(this).balance :
            _balanceOf(token, address(this));

        // Clamp to available balance in case it changed since request
        uint256 payout = available < requestedAmount ? available : requestedAmount;
        if (payout == 0) revert BAMMErrors.ZeroAmount();

        // Effects: delete request BEFORE external transfer (CEI)
        delete _rescueRequests[msg.sender];

        // Interaction: external transfer last
        if (token == address(0)) {
            receiver.safeTransferETH(payout);
        } else {
            token.safeTransfer(receiver, payout);
        }

        emit RescueExecuted(receiver, token, payout);
    }

    /// @notice Cancel a pending rescue request
    /// @dev Must be called by the requester or authorized owner
    function _cancelRescue() internal {
        RescueRequest storage request = _rescueRequests[msg.sender];

        if (request.timestamp == 0) revert BAMMErrors.NotInitialized();

        address token = request.token;
        delete _rescueRequests[msg.sender];
        emit RescueCancelled(msg.sender, token);
    }

    /// @notice Get rescue request for an address
    /// @param requester Address whose request to query
    /// @return Rescue request details
    function getRescueRequest(address requester) external view returns (RescueRequest memory) {
        return _rescueRequests[requester];
    }

    /// @notice Get token balance using cached selector for gas efficiency
    /// @dev Uses 0x70a08231 (balanceOf selector) to avoid runtime string hashing
    ///      Returns 0 if call fails (handles non-standard tokens gracefully)
    /// @param token Token address to query
    /// @param account Address to check balance of
    /// @return balance Token balance (0 if call failed)
    function _balanceOf(address token, address account) private view returns (uint256 balance) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSelector(BALANCE_OF_SELECTOR, account)
        );
        balance = success && data.length >= 32 ? abi.decode(data, (uint256)) : 0;
    }
}
