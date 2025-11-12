// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BAMMFactory} from "../src/bamm/BAMMFactory.sol";

/// @title DeployBAMMPool
/// @notice Script to deploy a new BAMM pool via factory
/// @dev Usage: forge script script/DeployBAMMPool.s.sol:DeployBAMMPool --rpc-url <RPC> --broadcast
///      Set environment variables: FACTORY_ADDRESS, BASE_TOKEN, OWNER, GUARDIAN, BASE_FEE, MAX_FEE, WITHDRAWAL_FEE, MAX_PRICE_CHANGE
contract DeployBAMMPool is Script {

    function run() external returns (address pool) {
        // Read environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        address baseToken = vm.envAddress("BASE_TOKEN");
        address owner = vm.envAddress("OWNER");
        address guardian = vm.envAddress("GUARDIAN");
        address treasury = vm.envOr("TREASURY", address(0));  // address(0) = defaults to owner

        // Base asset oracle parameters
        address baseMainOracle = vm.envOr("BASE_MAIN_ORACLE", address(0));  // address(0) = internal oracle
        address baseFallbackOracle = vm.envOr("BASE_FALLBACK_ORACLE", address(0));  // address(0) = no fallback
        uint128 baseMinLiquidity = uint128(vm.envOr("BASE_MIN_LIQUIDITY", uint256(1000)));

        // Fee parameters with defaults if not set
        uint16 baseFee = uint16(vm.envOr("BASE_FEE", uint256(30)));  // 0.30%
        uint16 maxFee = uint16(vm.envOr("MAX_FEE", uint256(1000)));  // 10%
        uint16 withdrawalFee = uint16(vm.envOr("WITHDRAWAL_FEE", uint256(10)));  // 0.10%
        uint16 maxTWAPChange = uint16(vm.envOr("MAX_PRICE_CHANGE", uint256(500)));  // 5%
        uint16 protocolFeeBps = uint16(vm.envOr("PROTOCOL_FEE_BPS", uint256(1000)));  // 10% to treasury

        // DarkPool parameter (default: false for backward compatibility)
        bool enableDarkPool = vm.envOr("ENABLE_DARK_POOL", false);

        // Validate inputs
        require(factoryAddress != address(0), "FACTORY_ADDRESS not set");
        require(baseToken != address(0), "BASE_TOKEN not set");
        require(owner != address(0), "OWNER not set");
        require(guardian != address(0), "GUARDIAN not set");

        vm.startBroadcast(deployerPrivateKey);

        BAMMFactory factory = BAMMFactory(factoryAddress);

        console2.log("Deploying BAMM pool via factory...");
        console2.log("Factory:", factoryAddress);
        console2.log("Base Token:", baseToken);
        console2.log("Base Main Oracle:", baseMainOracle);
        console2.log("Base Fallback Oracle:", baseFallbackOracle);
        console2.log("Base Min Liquidity:", baseMinLiquidity);
        console2.log("Owner:", owner);
        console2.log("Guardian:", guardian);
        console2.log("Treasury:", treasury == address(0) ? owner : treasury);
        console2.log("Base Fee:", baseFee, "bps");
        console2.log("Max Fee:", maxFee, "bps");
        console2.log("Withdrawal Fee:", withdrawalFee, "bps");
        console2.log("Max TWAP Change:", maxTWAPChange, "bps");
        console2.log("Protocol Fee:", protocolFeeBps, "bps");
        console2.log("Enable DarkPool:", enableDarkPool);

        uint16 flashFeeBps = 0; // Default: 0% (free flash loans)

        pool = factory.deployPool(
            baseToken,
            baseMainOracle,
            baseFallbackOracle,
            baseMinLiquidity,
            owner,
            guardian,
            treasury,
            baseFee,
            maxFee,
            withdrawalFee,
            maxTWAPChange,
            protocolFeeBps,
            flashFeeBps,
            enableDarkPool
        );

        console2.log("\n=== Pool Deployed ===");
        console2.log("Pool Address:", pool);
        console2.log("Implementation:", factory.implementation());

        if (enableDarkPool) {
            address darkPool = factory.getDarkPool(pool);
            console2.log("DarkPool:", darkPool);
        }

        console2.log("===================\n");

        vm.stopBroadcast();
    }
}
