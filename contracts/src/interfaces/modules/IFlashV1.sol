// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC3156FlashLender} from "../external/IERC3156FlashLender.sol";

/// @title IFlash
/// @notice Flash loan operations (ERC-3156 compliant)
interface IFlashV1 is IERC3156FlashLender {
    // Inherits: flashLoan, maxFlashLoan, flashFee

    // Events
    event FlashLoanExecuted(address indexed initiator, address indexed receiver, address indexed token, uint256 amount, uint256 fee);
}
