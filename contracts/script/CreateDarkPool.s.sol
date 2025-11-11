// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {DarkPoolFactory} from "../src/darkpool/DarkPoolFactory.sol";

/// @title CreateDarkPool
/// @notice Script to create a DarkPool proxy for a specific BAMM pool
contract CreateDarkPool is Script {
    function run() external {
        // Read from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address factory = vm.envAddress("DARKPOOL_FACTORY");
        address bammPool = vm.envAddress("BAMM_POOL");
        address verifier = vm.envAddress("GROTH16_VERIFIER");
        address admin = vm.envAddress("DARKPOOL_ADMIN");

        console2.log("Creating DarkPool for BAMM pool...");
        console2.log("Factory:", factory);
        console2.log("BAMM Pool:", bammPool);
        console2.log("Verifier:", verifier);
        console2.log("Admin:", admin);

        vm.startBroadcast(deployerPrivateKey);

        // Create DarkPool proxy
        address darkPool = DarkPoolFactory(factory).createDarkPool(
            bammPool,
            verifier,
            admin
        );

        vm.stopBroadcast();

        console2.log("\n=== DarkPool Created ===");
        console2.log("DarkPool Proxy:", darkPool);
        console2.log("Serves BAMM Pool:", bammPool);
    }
}
