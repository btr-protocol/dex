// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC3156FlashBorrower} from "./external/IERC3156FlashBorrower.sol";

/// @title IFlash
/// @notice Singleton ERC-3156 flash-loan provider — Phase 42H.B.3c.
/// @dev Pool-keyed: every public fn carries `pool` as first arg. The Flash singleton
///      collects fee + accounts repayment; the Pool holds the underlying tokens and
///      exposes restricted setters (`flashSend`, `flashAccount`) gated on Flash.
interface IFlash {
    event FlashLoanExecuted(
        address indexed pool,
        address indexed initiator,
        address indexed receiver,
        address token,
        uint256 amount,
        uint256 fee
    );

    function flashLoan(
        address pool,
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool);

    function maxFlashLoan(address pool, address token) external view returns (uint256);
    function flashFee(address pool, address token, uint256 amount) external view returns (uint256);
}
