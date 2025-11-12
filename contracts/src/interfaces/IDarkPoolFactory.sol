// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IDarkPoolFactory
/// @notice Factory for deploying DarkPool proxies via beacon pattern
interface IDarkPoolFactory {
    // ========== EVENTS ==========

    event DarkPoolCreated(address indexed bammPool, address indexed darkPool);
    // Note: BeaconUpgraded event is inherited from BeaconFactory

    // ========== FACTORY FUNCTIONS ==========

    /// @notice Create a new DarkPool proxy for a BAMM pool
    /// @param bammPool The BAMM pool to create DarkPool for
    /// @param verifier Groth16 verifier contract
    /// @param darkPoolOwner Owner address for the DarkPool
    /// @return darkPool Address of the deployed DarkPool proxy
    function createDarkPool(
        address bammPool,
        address verifier,
        address darkPoolOwner
    ) external returns (address darkPool);

    /// @notice Upgrade all DarkPool implementations via beacon
    /// @param newImplementation New DarkPool implementation address
    function upgradeTo(address newImplementation) external;

    // ========== VIEW FUNCTIONS ==========

    /// @notice Get the beacon contract
    /// @return beacon Beacon contract (returns UpgradeableBeacon from Solady)
    /// @dev To get address: address(factory.beacon())
    function beacon() external view returns (address beacon);

    /// @notice Get the DarkPool proxy for a BAMM pool
    /// @param bammPool BAMM pool address
    /// @return darkPool DarkPool proxy address (address(0) if none)
    function darkPoolForBAMM(address bammPool) external view returns (address darkPool);

    /// @notice Get the current implementation address
    /// @return implementation Current DarkPool implementation
    function implementation() external view returns (address implementation);
}
