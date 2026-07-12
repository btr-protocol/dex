// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Merkl (Angle) Distributor — used by Morpho / Aave / Euler incentive campaigns.
/// @dev claim sends tokens to `users[i]` (or their setClaimRecipient). Operator can claim for users.
interface IMerklDistributor {
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;

    function toggleOperator(address user, address operator) external;
    function operators(address user, address operator) external view returns (bool);
}
