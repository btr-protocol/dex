// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BAMMFactory} from "../src/bamm/BAMMFactory.sol";
import {BAMMAdmin} from "../src/bamm/BAMMAdmin.sol";
import {BAMMPricing} from "../src/bamm/BAMMPricing.sol";
import {BAMMInternalOracle} from "../src/bamm/BAMMInternalOracle.sol";

/// @title DeployBAMMPoolWithDarkPool
/// @notice Deploy a BAMMCore pool with optional DarkPool enabled
contract DeployBAMMPoolWithDarkPool is Script {
    function run() external {
        // Read from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address factory = vm.envAddress("BAMM_FACTORY");

        // Pool parameters
        address baseToken = vm.envAddress("BASE_TOKEN");
        address poolOwner = vm.envAddress("POOL_OWNER");
        bool enableDarkPool = vm.envBool("ENABLE_DARK_POOL");

        console2.log("=== Deploying BAMMCore Pool ===");
        console2.log("Factory:", factory);
        console2.log("Base Token:", baseToken);
        console2.log("Pool Owner:", poolOwner);
        console2.log("Enable DarkPool:", enableDarkPool);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy facets
        console2.log("Deploying facets...");
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

        console2.log("Deploying pool...");
        address pool = BAMMFactory(factory).deployPool(
            baseToken,
            poolOwner,
            address(pricingFacet),
            address(adminFacet),
            address(oracleFacet),
            adminSelectors,
            oracleSelectors
        );

        vm.stopBroadcast();

        console2.log("=== Pool Deployed ===");
        console2.log("BAMM Pool:", pool);

        if (enableDarkPool) {
            address darkPool = BAMMFactory(factory).getDarkPool(pool);
            console2.log("DarkPool:", darkPool);
        } else {
            console2.log("DarkPool: Not enabled");
            console2.log("  To enable later: bammFactory.enableDarkPool(pool, owner)");
        }
    }
}
