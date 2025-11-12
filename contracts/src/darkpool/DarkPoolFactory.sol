// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDarkPoolFactory} from "../interfaces/IDarkPoolFactory.sol";
import {DarkPool} from "./DarkPool.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {BeaconFactory} from "../utils/BeaconFactory.sol";
import {DarkPoolErrors as Errors} from "./DarkPoolErrors.sol";

/// @title DarkPoolFactory
/// @notice Factory for deploying DarkPool proxies using beacon pattern
/// @dev Each deployment creates a new beacon proxy pointing to shared implementation
///      Factory ownership can be transferred (e.g., EOA → multisig) via Solady's Ownable
contract DarkPoolFactory is IDarkPoolFactory, BeaconFactory {

    // ========== STORAGE ==========

    /// @notice Mapping from BAMM pool to DarkPool proxy
    mapping(address => address) public override darkPoolForBAMM;

    // ========== CONSTRUCTOR ==========

    /// @notice Deploy factory with DarkPool implementation
    /// @param implementation Initial DarkPool implementation
    /// @param initialOwner Factory owner (can upgrade beacon and deploy DarkPools)
    constructor(address implementation, address initialOwner)
        BeaconFactory(implementation, initialOwner)
    {}

    // ========== FACTORY FUNCTIONS ==========

    /// @inheritdoc IDarkPoolFactory
    function createDarkPool(
        address bammPool,
        address verifier,
        address darkPoolOwner
    ) external override returns (address darkPool) {
        // Validate inputs
        if (bammPool == address(0)) revert Errors.ZeroAddress();
        if (verifier == address(0)) revert Errors.ZeroAddress();
        if (darkPoolOwner == address(0)) revert Errors.ZeroAddress();

        // Check DarkPool doesn't already exist for this BAMM
        if (darkPoolForBAMM[bammPool] != address(0)) {
            revert Errors.DarkPoolAlreadyExists(bammPool);
        }

        // Deploy beacon proxy
        darkPool = LibClone.deployERC1967BeaconProxy(address(_beacon));

        // Initialize the proxy
        DarkPool(darkPool).initialize(bammPool, verifier, darkPoolOwner);

        // Register mapping
        darkPoolForBAMM[bammPool] = darkPool;

        // Emit event
        emit DarkPoolCreated(bammPool, darkPool);

        return darkPool;
    }

    /// @inheritdoc IDarkPoolFactory
    /// @dev Delegates to BeaconFactory.upgradeBeacon()
    function upgradeTo(address newImplementation) external override onlyOwner {
        upgradeBeacon(newImplementation);
    }

    // ========== VIEW FUNCTIONS ==========

    /// @inheritdoc IDarkPoolFactory
    function beacon() external view override(BeaconFactory, IDarkPoolFactory) returns (address) {
        return address(_beacon);
    }

    /// @inheritdoc IDarkPoolFactory
    function implementation() external view override(BeaconFactory, IDarkPoolFactory) returns (address) {
        return _beacon.implementation();
    }
}
