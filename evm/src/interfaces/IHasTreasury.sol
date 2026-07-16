// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title IHasTreasury -minimal accessor for a contract that exposes a treasury address.
/// @notice Z3-F10 rename (was `ITreasuryView`). Used by `Admin` to gate `collectProtocolFees`
///         to the pool's configured treasury — the implementing contract is the Pool, not the
///         Treasury itself, so the new name reads more accurately at call-sites.
interface IHasTreasury {
  function treasury() external view returns (address);
}
