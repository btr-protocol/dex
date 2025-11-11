// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDarkPoolFactory} from "../interfaces/IDarkPoolFactory.sol";
import {DarkPool} from "./DarkPool.sol";
import {UpgradeableBeacon} from "solady/utils/UpgradeableBeacon.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {DarkPoolErrors as Errors} from "./DarkPoolErrors.sol";

/// @title DarkPoolFactory
/// @notice Factory for deploying DarkPool proxies using beacon pattern
/// @dev Mirrors BAMM's beacon proxy architecture
contract DarkPoolFactory is IDarkPoolFactory {
    // ========== STORAGE ==========

    /// @notice Beacon contract pointing to DarkPool implementation
    address public immutable override beacon;

    /// @notice Owner of the factory (can upgrade beacon)
    address public immutable owner;

    /// @notice Mapping from BAMM pool to DarkPool proxy
    mapping(address => address) public override darkPoolForBAMM;

    // ========== CONSTRUCTOR ==========

    /// @notice Deploy factory with beacon
    /// @param _implementation Initial DarkPool implementation
    /// @param _owner Factory owner
    constructor(address _implementation, address _owner) {
        if (_implementation == address(0)) revert Errors.ZeroAddress();
        if (_owner == address(0)) revert Errors.ZeroAddress();

        owner = _owner;
        beacon = address(new UpgradeableBeacon(_implementation, _owner));
    }

    // ========== MODIFIERS ==========

    modifier onlyOwner() {
        if (msg.sender != owner) revert Errors.Unauthorized();
        _;
    }

    // ========== FACTORY FUNCTIONS ==========

    /// @inheritdoc IDarkPoolFactory
    function createDarkPool(
        address bammPool,
        address verifier,
        address admin
    ) external override returns (address darkPool) {
        // Validate inputs
        if (bammPool == address(0)) revert Errors.ZeroAddress();
        if (verifier == address(0)) revert Errors.ZeroAddress();
        if (admin == address(0)) revert Errors.ZeroAddress();

        // Check DarkPool doesn't already exist for this BAMM
        if (darkPoolForBAMM[bammPool] != address(0)) {
            revert Errors.DarkPoolAlreadyExists(bammPool);
        }

        // Deploy beacon proxy
        darkPool = LibClone.deployERC1967BeaconProxy(beacon);

        // Initialize the proxy
        DarkPool(darkPool).initialize(bammPool, verifier, admin);

        // Register mapping
        darkPoolForBAMM[bammPool] = darkPool;

        // Emit event
        emit DarkPoolCreated(bammPool, darkPool);

        return darkPool;
    }

    /// @inheritdoc IDarkPoolFactory
    function upgradeTo(address newImplementation) external override onlyOwner {
        if (newImplementation == address(0)) revert Errors.ZeroAddress();
        if (newImplementation.code.length == 0) revert Errors.InvalidImplementation();

        UpgradeableBeacon(beacon).upgradeTo(newImplementation);

        emit BeaconUpgraded(newImplementation);
    }

    // ========== VIEW FUNCTIONS ==========

    /// @inheritdoc IDarkPoolFactory
    function implementation() external view override returns (address) {
        return UpgradeableBeacon(beacon).implementation();
    }
}
