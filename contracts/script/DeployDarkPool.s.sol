// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {DarkPool} from "../src/darkpool/DarkPool.sol";
import {DarkPoolFactory} from "../src/darkpool/DarkPoolFactory.sol";
import {ShieldedState} from "../src/darkpool/ShieldedState.sol";

/// @title DeployDarkPool
/// @notice Deployment script for DarkPool infrastructure
contract DeployDarkPool is Script {
    function run() external {
        // Read deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("Deploying DarkPool infrastructure...");
        console2.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy ShieldedState (global merkle tree and nullifier set)
        ShieldedState shieldedState = new ShieldedState(deployer);
        console2.log("ShieldedState deployed at:", address(shieldedState));

        // 2. Deploy DarkPool implementation
        DarkPool implementation = new DarkPool();
        console2.log("DarkPool implementation deployed at:", address(implementation));

        // 3. Deploy DarkPoolFactory (creates beacon internally)
        DarkPoolFactory factory = new DarkPoolFactory(
            address(implementation),
            deployer, // Owner
            address(shieldedState) // Global shielded state
        );
        console2.log("DarkPoolFactory deployed at:", address(factory));
        console2.log("Beacon deployed at:", factory.beacon());

        vm.stopBroadcast();

        // Log summary
        console2.log("\n=== Deployment Summary ===");
        console2.log("ShieldedState:", address(shieldedState));
        console2.log("DarkPool Implementation:", address(implementation));
        console2.log("DarkPoolFactory:", address(factory));
        console2.log("Beacon:", factory.beacon());
        console2.log("Owner:", deployer);
    }
}
