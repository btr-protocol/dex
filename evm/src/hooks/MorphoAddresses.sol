// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title MorphoAddresses — Morpho Blue singleton + notes for Felix Vanilla (ERC-4626 vaults).
/// @dev Felix Vanilla = Morpho Vault / ERC4626YieldHook only (not Liquity/Felix CDP).
///      Blue market allowlists use MorphoBlueYieldHook + MarketParams pins at deploy time.
library MorphoAddresses {
    /// @notice Canonical Morpho Blue singleton (Ethereum, Base, Arbitrum, …).
    address internal constant BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    /// @notice Merkl distributor (Angle) — claim then YieldHook.sweepIncentives → treasury.
    address internal constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;
}
