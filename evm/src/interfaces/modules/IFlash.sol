// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC3156FlashLender} from "../external/IERC3156FlashLender.sol";

/// @title IFlash
/// @notice ERC-3156 flash loans
interface IFlash is IERC3156FlashLender {
    event FlashLoanExecuted(address indexed initiator, address indexed receiver, address indexed token, uint256 amount, uint256 fee);
}
