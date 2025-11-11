// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BAMMFactory} from "../src/bamm/BAMMFactory.sol";

/// @title DeployBAMMPoolWithDarkPool
/// @notice Deploy a BAMM pool with optional DarkPool enabled
contract DeployBAMMPoolWithDarkPool is Script {
    function run() external {
        // Read from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address factory = vm.envAddress("BAMM_FACTORY");

        // Pool parameters
        address baseToken = vm.envAddress("BASE_TOKEN");
        address baseMainOracle = vm.envAddress("BASE_MAIN_ORACLE");
        address baseFallbackOracle = vm.envOr("BASE_FALLBACK_ORACLE", address(0));
        uint128 baseMinLiquidity = uint128(vm.envUint("BASE_MIN_LIQUIDITY"));
        address poolAdmin = vm.envAddress("POOL_ADMIN");
        address keeper = vm.envAddress("KEEPER");
        address treasury = vm.envAddress("TREASURY");
        uint16 baseFee = uint16(vm.envUint("BASE_FEE"));
        uint16 maxFee = uint16(vm.envUint("MAX_FEE"));
        uint16 withdrawalFee = uint16(vm.envUint("WITHDRAWAL_FEE"));
        uint16 maxTWAPChange = uint16(vm.envUint("MAX_TWAP_CHANGE"));
        uint16 protocolFeeBps = uint16(vm.envUint("PROTOCOL_FEE_BPS"));
        bool enableDarkPool = vm.envBool("ENABLE_DARK_POOL");

        console2.log("=== Deploying BAMM Pool ===");
        console2.log("Factory:", factory);
        console2.log("Base Token:", baseToken);
        console2.log("Pool Admin:", poolAdmin);
        console2.log("Enable DarkPool:", enableDarkPool);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        address pool = BAMMFactory(factory).deployPool(
            baseToken,
            baseMainOracle,
            baseFallbackOracle,
            baseMinLiquidity,
            poolAdmin,
            keeper,
            treasury,
            baseFee,
            maxFee,
            withdrawalFee,
            maxTWAPChange,
            protocolFeeBps,
            enableDarkPool
        );

        vm.stopBroadcast();

        console2.log("=== Pool Deployed ===");
        console2.log("BAMM Pool:", pool);

        if (enableDarkPool) {
            address darkPool = BAMMFactory(factory).getDarkPool(pool);
            console2.log("DarkPool:", darkPool);
        } else {
            console2.log("DarkPool: Not enabled");
            console2.log("  To enable later: bammFactory.enableDarkPool(pool, admin)");
        }
    }
}
