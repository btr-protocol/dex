// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BAMMCore} from "../src/bamm/BAMMCore.sol";
import {BAMMFactory} from "../src/bamm/BAMMFactory.sol";

/// @title UpgradeBAMM
/// @notice Script to upgrade all BAMMCore pools to a new implementation
/// @dev Usage: forge script script/UpgradeBAMM.s.sol:UpgradeBAMM --rpc-url <RPC> --broadcast
///      Set environment variable: FACTORY_ADDRESS
///      IMPORTANT: Only the factory owner can execute this upgrade
contract UpgradeBAMM is Script {

    function run() external {
        // Read environment variables
        uint256 ownerPrivateKey = vm.envUint("PRIVATE_KEY");
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");

        require(factoryAddress != address(0), "FACTORY_ADDRESS not set");

        BAMMFactory factory = BAMMFactory(factoryAddress);
        address oldImplementation = factory.implementation();

        vm.startBroadcast(ownerPrivateKey);

        // Deploy new implementation
        console2.log("Deploying new BAMM...");
        BAMMCore newImplementation = new BAMMCore();
        console2.log("New implementation deployed at:", address(newImplementation));

        // Upgrade the beacon (affects all pools instantly)
        console2.log("Upgrading beacon...");
        factory.upgradeBeacon(address(newImplementation));
        console2.log("Beacon upgraded successfully!");

        vm.stopBroadcast();

        // Verify upgrade
        address currentImplementation = factory.implementation();
        require(currentImplementation == address(newImplementation), "Upgrade verification failed");

        // Log upgrade summary
        console2.log("\n=== Upgrade Summary ===");
        console2.log("Factory:", factoryAddress);
        console2.log("Beacon:", address(factory.beacon()));
        console2.log("Old Implementation:", oldImplementation);
        console2.log("New Implementation:", currentImplementation);
        console2.log("Total Pools Upgraded:", factory.poolCount());
        console2.log("=====================\n");
    }
}
