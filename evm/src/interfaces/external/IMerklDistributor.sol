// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Merkl (Angle) Distributor — used by Morpho / Euler (rEUL) / generic ERC4626 incentive campaigns.
/// @dev claim sends tokens to `users[i]` (or their setClaimRecipient). Default recipient = the user, so
///      claiming with `users[i] = hook` lands rewards on the hook → then swept to Treasury. Operator can
///      claim for users; the hook is its own operator so no toggleOperator needed.
interface IMerklDistributor {
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;
}
