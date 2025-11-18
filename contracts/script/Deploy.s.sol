// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BAMMCore} from "../src/bamm/BAMMCore.sol";
import {BAMMFactory} from "../src/bamm/BAMMFactory.sol";
import {BAMMAdmin} from "../src/bamm/BAMMAdmin.sol";
import {BAMMPricing} from "../src/bamm/BAMMPricing.sol";
import {BAMMInternalOracle} from "../src/bamm/BAMMInternalOracle.sol";

/// @title Deploy BAMM
/// @notice Deployment script for BAMM
contract Deploy is Script {

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        console2.log("Deploying BAMM...");
        BAMMCore implementation = new BAMMCore();
        console2.log("Implementation:", address(implementation));

        console2.log("Deploying BAMMFactory...");
        BAMMFactory factory = new BAMMFactory(address(implementation), msg.sender);
        console2.log("Factory:", address(factory));
        console2.log("Beacon:", address(factory.beacon()));

        if (vm.envBool("DEPLOY_POOL")) {
            console2.log("\nDeploying facets...");
            BAMMAdmin adminFacet = new BAMMAdmin();
            console2.log("Admin facet:", address(adminFacet));

            BAMMPricing pricingFacet = new BAMMPricing();
            console2.log("Pricing facet:", address(pricingFacet));

            BAMMInternalOracle oracleFacet = new BAMMInternalOracle();
            console2.log("Oracle facet:", address(oracleFacet));

            address baseToken = vm.envAddress("BASE_TOKEN");
            address poolOwner = vm.envAddress("POOL_OWNER");

            // Admin facet selectors: addAsset, pausePool, unpausePool, collectProtocolFees, freezeAsset, unfreezeAsset, updateFeeConfig, blacklistAddress, unblacklistAddress
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

            // Oracle facet selectors: pushPrice, getOracleData
            bytes4[] memory oracleSelectors = new bytes4[](2);
            oracleSelectors[0] = BAMMInternalOracle.pushPrice.selector;
            oracleSelectors[1] = BAMMInternalOracle.getOracleData.selector;

            console2.log("\nDeploying example pool...");
            address pool = factory.deployPool(
                baseToken,
                poolOwner,
                address(pricingFacet),
                address(adminFacet),
                address(oracleFacet),
                adminSelectors,
                oracleSelectors
            );
            console2.log("Pool:", pool);
        }

        vm.stopBroadcast();

        console2.log("\n========== DEPLOYMENT SUMMARY ==========");
        console2.log("Implementation:", address(implementation));
        console2.log("Factory:", address(factory));
        console2.log("Beacon:", address(factory.beacon()));
        console2.log("Owner:", factory.owner());
        console2.log("=========================================\n");
    }
}
