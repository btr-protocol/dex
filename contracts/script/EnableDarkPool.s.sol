// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BAMMFactory} from "../src/bamm/BAMMFactory.sol";

/// @title EnableDarkPool
/// @notice Enable DarkPool for an existing BAMM pool
contract EnableDarkPool is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address factory = vm.envAddress("BAMM_FACTORY");
        address bammPool = vm.envAddress("BAMM_POOL");
        address darkPoolAdmin = vm.envAddress("DARKPOOL_ADMIN");

        console2.log("=== Enabling DarkPool for BAMM Pool ===");
        console2.log("Factory:", factory);
        console2.log("BAMM Pool:", bammPool);
        console2.log("DarkPool Admin:", darkPoolAdmin);
        console2.log("");

        vm.startBroadcast(privateKey);

        BAMMFactory(factory).enableDarkPool(bammPool, darkPoolAdmin);

        vm.stopBroadcast();

        address darkPool = BAMMFactory(factory).getDarkPool(bammPool);

        console2.log("=== DarkPool Enabled ===");
        console2.log("DarkPool:", darkPool);
        console2.log("Serves BAMM:", bammPool);
    }
}
