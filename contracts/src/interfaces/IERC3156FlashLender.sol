// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC3156FlashBorrower} from "./IERC3156FlashBorrower.sol";

/**
 * @title IERC3156FlashLender
 * @notice Interface for ERC-3156 flash loan providers
 */
interface IERC3156FlashLender {
    /**
     * @notice Flash loan event
     * @param borrower Address that initiated the flash loan
     * @param amount Amount borrowed
     * @param fee Fee charged
     */
    event FlashLoan(address indexed borrower, uint256 amount, uint256 fee);

    /**
     * @notice Maximum flash loan amount available for a token
     * @param token Token address
     * @return Maximum amount that can be borrowed
     */
    function maxFlashLoan(address token) external view returns (uint256);

    /**
     * @notice Flash loan fee for a given amount
     * @param token Token address
     * @param amount Loan amount
     * @return Fee amount in token units
     */
    function flashFee(address token, uint256 amount) external view returns (uint256);

    /**
     * @notice Extended flash fee with custom borrower (for compatibility)
     * @param token Token address
     * @param borrower Borrower address
     * @param amount Loan amount
     * @return Fee amount in token units
     */
    function flashFee(
        address token,
        address borrower,
        uint256 amount
    ) external view returns (uint256);

    /**
     * @notice Execute a flash loan
     * @param receiver Contract receiving the flash loan
     * @param token Token to flash loan
     * @param amount Amount to flash loan
     * @param data Arbitrary data passed to receiver
     * @return True if flash loan succeeds
     */
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool);

    /**
     * @notice Set maximum flash loan amount
     * @param amount Maximum loan amount
     */
    function setMaxLoan(uint256 amount) external;
}
