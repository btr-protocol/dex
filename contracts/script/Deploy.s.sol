// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BAMM} from "../src/bamm/BAMM.sol";
import {BAMMFactory} from "../src/bamm/BAMMFactory.sol";

/// @title Deploy BAMM
/// @notice Deployment script for BAMM
contract Deploy is Script {

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        console2.log("Deploying BAMM...");
        BAMM implementation = new BAMM();
        console2.log("Implementation:", address(implementation));

        console2.log("Deploying BAMMFactory...");
        BAMMFactory factory = new BAMMFactory(address(implementation));
        console2.log("Factory:", address(factory));
        console2.log("Beacon:", address(factory.beacon()));

        if (vm.envBool("DEPLOY_POOL")) {
            address baseToken = vm.envAddress("BASE_TOKEN");
            address poolAdmin = vm.envAddress("POOL_ADMIN");
            address keeper = vm.envAddress("KEEPER");
            address treasury = vm.envOr("TREASURY", address(0));  // address(0) = defaults to admin

            // Base asset oracle parameters
            address baseMainOracle = vm.envOr("BASE_MAIN_ORACLE", address(0));
            address baseFallbackOracle = vm.envOr("BASE_FALLBACK_ORACLE", address(0));
            uint128 baseMinLiquidity = uint128(vm.envOr("BASE_MIN_LIQUIDITY", uint256(1000)));

            // Fee parameters with defaults
            uint16 baseFee = uint16(vm.envOr("BASE_FEE", uint256(30)));
            uint16 maxFee = uint16(vm.envOr("MAX_FEE", uint256(1000)));
            uint16 withdrawalFee = uint16(vm.envOr("WITHDRAWAL_FEE", uint256(10)));
            uint16 maxTWAPChange = uint16(vm.envOr("MAX_PRICE_CHANGE", uint256(500)));
            uint16 protocolFeeBps = uint16(vm.envOr("PROTOCOL_FEE_BPS", uint256(1000)));  // 10% to treasury

            console2.log("\nDeploying example pool...");
            address pool = factory.deployPool(baseToken, baseMainOracle, baseFallbackOracle, baseMinLiquidity, poolAdmin, keeper, treasury, baseFee, maxFee, withdrawalFee, maxTWAPChange, protocolFeeBps);
            console2.log("Pool:", pool);
        }

        vm.stopBroadcast();

        console2.log("\n========== DEPLOYMENT SUMMARY ==========");
        console2.log("Implementation:", address(implementation));
        console2.log("Factory:", address(factory));
        console2.log("Beacon:", address(factory.beacon()));
        console2.log("Admin:", factory.admin());
        console2.log("=========================================\n");
    }
}
