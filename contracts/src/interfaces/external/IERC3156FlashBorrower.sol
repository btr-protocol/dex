// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/**
 * @title IERC3156FlashBorrower
 * @notice Interface for ERC-3156 flash loan borrowers
 * @dev Implement this interface to receive flash loans
 */
interface IERC3156FlashBorrower {
    /**
     * @notice ERC-3156 compliant flash loan callback
     * @dev Executes an operation after receiving the borrowed assets
     * @param initiator Account initiating the flash loan
     * @param token Address of the borrowed asset
     * @param amount Amount of tokens being borrowed
     * @param fee Fee charged for the flash loan
     * @param data Parameters for the function call
     * @return The operation signature (keccak256("ERC3156FlashBorrower.postFlashLoan"))
     */
    function postFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32);
}
