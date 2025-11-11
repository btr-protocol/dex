// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BAMM} from "../src/bamm/BAMM.sol";
import {BAMMFactory} from "../src/bamm/BAMMFactory.sol";

/// @title DeployBAMMFactory
/// @notice Deployment script for BAMM Factory and Implementation
/// @dev Usage: forge script script/DeployBAMMFactory.s.sol:DeployBAMMFactory --rpc-url <RPC> --broadcast
contract DeployBAMMFactory is Script {

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy the implementation contract
        console2.log("Deploying BAMM...");
        BAMM implementation = new BAMM();
        console2.log("BAMM deployed at:", address(implementation));

        // 2. Deploy the factory (which deploys the beacon internally)
        console2.log("Deploying BAMMFactory...");
        BAMMFactory factory = new BAMMFactory(address(implementation));
        console2.log("BAMMFactory deployed at:", address(factory));
        console2.log("UpgradeableBeacon deployed at:", address(factory.beacon()));

        vm.stopBroadcast();

        // Log deployment summary
        console2.log("\n=== Deployment Summary ===");
        console2.log("Implementation:", address(implementation));
        console2.log("Factory:", address(factory));
        console2.log("Beacon:", address(factory.beacon()));
        console2.log("========================\n");
    }
}
