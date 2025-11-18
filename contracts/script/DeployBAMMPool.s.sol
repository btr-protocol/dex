// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BAMMFactory} from "../src/bamm/BAMMFactory.sol";
import {BAMMAdmin} from "../src/bamm/BAMMAdmin.sol";
import {BAMMPricing} from "../src/bamm/BAMMPricing.sol";
import {BAMMInternalOracle} from "../src/bamm/BAMMInternalOracle.sol";

/// @title DeployBAMMPool
/// @notice Script to deploy a new BAMMCore pool via factory
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

        // DarkPool parameter (default: false for backward compatibility)
        bool enableDarkPool = vm.envOr("ENABLE_DARK_POOL", false);

        // Validate inputs
        require(factoryAddress != address(0), "FACTORY_ADDRESS not set");
        require(baseToken != address(0), "BASE_TOKEN not set");
        require(owner != address(0), "OWNER not set");
        require(guardian != address(0), "GUARDIAN not set");

        vm.startBroadcast(deployerPrivateKey);

        console2.log("Deploying BAMMCore pool via factory...");
        console2.log("Factory:", factoryAddress);
        console2.log("Base Token:", baseToken);
        console2.log("Owner:", owner);
        console2.log("Enable DarkPool:", enableDarkPool);

        // Deploy facets
        console2.log("\nDeploying facets...");
        BAMMAdmin adminFacet = new BAMMAdmin();
        console2.log("Admin facet:", address(adminFacet));

        BAMMPricing pricingFacet = new BAMMPricing();
        console2.log("Pricing facet:", address(pricingFacet));

        BAMMInternalOracle oracleFacet = new BAMMInternalOracle();
        console2.log("Oracle facet:", address(oracleFacet));

        // Admin facet selectors
        bytes4[] memory adminSelectors = new bytes4[](9);
        adminSelectors[0] = BAMMAdmin.addAsset.selector;
        adminSelectors[1] = BAMMAdmin.pausePool.selector;
        adminSelectors[2] = BAMMAdmin.unpausePool.selector;
        adminSelectors[3] = BAMMAdmin.collectProtocolFees.selector;
        adminSelectors[4] = BAMMAdmin.freezeAsset.selector;
        adminSelectors[5] = BAMMAdmin.unfreezeAsset.selector;
        adminSelectors[6] = BAMMAdmin.updateFeeConfig.selector;
        adminSelectors[7] = BAMMAdmin.blacklistAddress.selector;
        adminSelectors[8] = BAMMAdmin.unblacklistAddress.selector;

        // Oracle facet selectors
        bytes4[] memory oracleSelectors = new bytes4[](2);
        oracleSelectors[0] = BAMMInternalOracle.pushPrice.selector;
        oracleSelectors[1] = BAMMInternalOracle.getOracleData.selector;

        console2.log("\nDeploying pool...");
        BAMMFactory factory = BAMMFactory(factoryAddress);

        pool = factory.deployPool(
            baseToken,
            owner,
            address(pricingFacet),
            address(adminFacet),
            address(oracleFacet),
            adminSelectors,
            oracleSelectors
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
