// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {UpgradeableBeacon} from "solady/utils/UpgradeableBeacon.sol";

/// @title BeaconFactory
/// @notice Abstract base for beacon proxy factories with upgradeable implementation
/// @dev Provides common beacon management logic for all protocol factories
///      - Factory owns its beacon (beacon owner = factory address)
///      - Factory ownership can be transferred via Solady's Ownable
///      - Each deployment creates a beacon proxy pointing to shared implementation
abstract contract BeaconFactory is Ownable {

    // ========== STATE ==========

    /// @notice Beacon contract pointing to the implementation
    /// @dev Prefixed with underscore to allow child contracts to define beacon() getters
    UpgradeableBeacon internal immutable _beacon;

    // ========== EVENTS ==========

    /// @notice Emitted when beacon implementation is upgraded
    /// @param newImplementation Address of the new implementation
    event BeaconUpgraded(address indexed newImplementation);

    // ========== ERRORS ==========

    error ZeroAddress();
    error InvalidImplementation();

    // ========== CONSTRUCTOR ==========

    /// @notice Initialize factory with beacon and owner
    /// @param initialImplementation Initial implementation for the beacon
    /// @param initialOwner Owner of the factory (can upgrade beacon and transfer ownership)
    constructor(address initialImplementation, address initialOwner) {
        if (initialImplementation == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();
        if (initialImplementation.code.length == 0) revert InvalidImplementation();

        // Factory owns the beacon (beacon's owner is this factory contract)
        _beacon = new UpgradeableBeacon(address(this), initialImplementation);

        // Initialize factory ownership
        _initializeOwner(initialOwner);
    }

    // ========== UPGRADE FUNCTIONS ==========

    /// @notice Upgrade beacon implementation (affects all deployed proxies)
    /// @param newImplementation New implementation address
    function upgradeBeacon(address newImplementation) public onlyOwner {
        if (newImplementation == address(0)) revert ZeroAddress();
        if (newImplementation.code.length == 0) revert InvalidImplementation();

        _beacon.upgradeTo(newImplementation);
        emit BeaconUpgraded(newImplementation);
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Get current implementation address
    /// @return implementation Current implementation address from beacon
    function implementation() external view virtual returns (address) {
        return _beacon.implementation();
    }

    /// @notice Get beacon address
    /// @return Beacon contract address
    function beacon() external view virtual returns (address) {
        return address(_beacon);
    }

    // Note: Ownership transfer uses Solady's Ownable two-step mechanism:
    // 1. Current owner calls: requestOwnershipHandover() for new owner OR transferOwnership(newOwner)
    // 2. New owner calls: completeOwnershipHandover()
    // This enables safe EOA → multisig migration
}
