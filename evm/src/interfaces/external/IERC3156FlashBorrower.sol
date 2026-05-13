// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title IERC3156FlashBorrower
/// @notice ERC-3156 flash loan callback receiver
interface IERC3156FlashBorrower {
    /// @return keccak256("ERC3156FlashBorrower.postFlashLoan")
    function postFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32);
}
