// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BAMM} from "../src/bamm/BAMM.sol";
import {BAMMFactory} from "../src/bamm/BAMMFactory.sol";
import {DarkPool} from "../src/darkpool/DarkPool.sol";
import {DarkPoolFactory} from "../src/darkpool/DarkPoolFactory.sol";
import {ShieldedState} from "../src/darkpool/ShieldedState.sol";

/// @title DeployAll
/// @notice Complete deployment script for BAMM + DarkPool infrastructure
contract DeployAll is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("=== Deploying Complete BAMM + DarkPool Infrastructure ===");
        console2.log("Deployer:", deployer);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ========== STEP 1: Deploy Shared ShieldedState ==========
        console2.log("Step 1: Deploying ShieldedState (global Merkle tree and nullifier set)...");

        ShieldedState shieldedState = new ShieldedState(deployer);
        console2.log("  ShieldedState:", address(shieldedState));

        // ========== STEP 2: Deploy DarkPool Infrastructure ==========
        console2.log("");
        console2.log("Step 2: Deploying DarkPool infrastructure...");

        DarkPool darkPoolImpl = new DarkPool();
        console2.log("  DarkPool implementation:", address(darkPoolImpl));

        DarkPoolFactory darkPoolFactory = new DarkPoolFactory(
            address(darkPoolImpl),
            deployer,
            address(shieldedState)
        );
        console2.log("  DarkPoolFactory:", address(darkPoolFactory));
        console2.log("  DarkPool Beacon:", darkPoolFactory.beacon());

        // ========== STEP 3: Deploy Groth16 Verifier (Placeholder) ==========
        console2.log("");
        console2.log("Step 3: Verifier contract...");
        console2.log("  TODO: Deploy actual Groth16 verifier");
        console2.log("  For now, using placeholder address");
        address verifier = address(0x0); // TODO: Replace with actual verifier
        console2.log("  Verifier (placeholder):", verifier);

        // ========== STEP 4: Deploy BAMM Infrastructure ==========
        console2.log("");
        console2.log("Step 4: Deploying BAMM infrastructure...");

        BAMM bammImpl = new BAMM();
        console2.log("  BAMM implementation:", address(bammImpl));

        BAMMFactory bammFactory = new BAMMFactory(address(bammImpl), deployer);
        console2.log("  BAMMFactory:", address(bammFactory));
        console2.log("  BAMM Beacon:", address(bammFactory.beacon()));

        // ========== STEP 5: Configure BAMM Factory with DarkPool ==========
        console2.log("");
        console2.log("Step 5: Configuring BAMM Factory for DarkPool...");

        bammFactory.setDarkPoolFactory(address(darkPoolFactory));
        console2.log("  DarkPoolFactory set in BAMMFactory");

        if (verifier != address(0)) {
            bammFactory.setDefaultVerifier(verifier);
            console2.log("  Default verifier set in BAMMFactory");
        } else {
            console2.log("  WARNING: Verifier not set (must set before enabling DarkPools)");
        }

        vm.stopBroadcast();

        // ========== SUMMARY ==========
        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("");
        console2.log("Shielded State:");
        console2.log("  ShieldedState:", address(shieldedState));
        console2.log("");
        console2.log("DarkPool Infrastructure:");
        console2.log("  Implementation:", address(darkPoolImpl));
        console2.log("  Factory:", address(darkPoolFactory));
        console2.log("  Beacon:", darkPoolFactory.beacon());
        console2.log("");
        console2.log("BAMM Infrastructure:");
        console2.log("  Implementation:", address(bammImpl));
        console2.log("  Factory:", address(bammFactory));
        console2.log("  Beacon:", address(bammFactory.beacon()));
        console2.log("");
        console2.log("Configuration:");
        console2.log("  Owner:", deployer);
        console2.log("  Verifier:", verifier);
        console2.log("");
        console2.log("=== Next Steps ===");
        console2.log("1. Deploy actual Groth16 verifier contract");
        console2.log("2. Call bammFactory.setDefaultVerifier(verifier)");
        console2.log("3. Deploy BAMM pools with deployPool(..., enableDarkPool=true)");
        console2.log("4. Or enable DarkPool later via bammFactory.enableDarkPool(bammPool, owner)");
    }
}
