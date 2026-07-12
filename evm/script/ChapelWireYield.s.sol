// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Script.sol";

import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Admin} from "../src/Admin.sol";
import {VenusHook} from "../src/hooks/VenusHook.sol";
import {MockVenus} from "../src/hooks/MockVenus.sol";
import {Constants as C} from "../src/libraries/Constants.sol";

/// @title ChapelWireYield — MockVenus + VenusHook on stable USDC/USDT (Steward-lite AC).
/// @notice Hook install is HIGH-tier (Chapel = 30m). Two-step:
///   1) `run` — deploy mocks/hooks, grant drip keeper, queue setAssetHook
///   2) after >=30m: `execute` — executeSetAssetHook
/// @dev Env: DEPLOYER_PK, ADMIN, AC, STABLE_POOL, optional YIELD_DRIP_KEEPER.
contract ChapelWireYield is Script {
    address constant USDC = 0x6dF80a290E0585dad752c25f2808E83b5624290d;
    address constant USDT = 0xB7b7722369Ab72cb044DE6bb511A4586F3a7dD64;

    uint32 constant FLAGS = C.HOOK_PRE_OUTFLOW | C.HOOK_POST_DEPOSIT;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address adminAddr = vm.envAddress("ADMIN");
        address acAddr = vm.envAddress("AC");
        address stable = vm.envAddress("STABLE_POOL");
        address drip = vm.envOr("YIELD_DRIP_KEEPER", address(0));

        Admin admin = Admin(adminAddr);
        AccessControl ac = AccessControl(acAddr);

        vm.startBroadcast(pk);

        if (drip != address(0)) ac.setKeeper(drip, true);

        MockVenus vUsdc = new MockVenus(USDC);
        MockVenus vUsdt = new MockVenus(USDT);
        VenusHook hUsdc = new VenusHook(acAddr, stable, USDC, address(vUsdc));
        VenusHook hUsdt = new VenusHook(acAddr, stable, USDT, address(vUsdt));

        admin.requestSetAssetHook(stable, USDC, address(hUsdc), FLAGS);
        admin.requestSetAssetHook(stable, USDT, address(hUsdt), FLAGS);

        vm.stopBroadcast();

        console2.log("=== ChapelWireYield queued (execute in >=30m) ===");
        console2.log("mockVenusUsdc", address(vUsdc));
        console2.log("mockVenusUsdt", address(vUsdt));
        console2.log("venusHookUsdc", address(hUsdc));
        console2.log("venusHookUsdt", address(hUsdt));
    }

    function execute() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address adminAddr = vm.envAddress("ADMIN");
        address stable = vm.envAddress("STABLE_POOL");

        Admin admin = Admin(adminAddr);
        vm.startBroadcast(pk);
        admin.executeSetAssetHook(stable, USDC);
        admin.executeSetAssetHook(stable, USDT);
        vm.stopBroadcast();
        console2.log("hooks live on stable USDC+USDT");
    }
}
