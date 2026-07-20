// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Script.sol";

import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Admin} from "../src/Admin.sol";
import {CompoundV2YieldHook} from "../src/hooks/CompoundV2YieldHook.sol";
import {MockVenus} from "../test/mocks/MockVenus.sol";
import {Constants as C} from "../src/libraries/Constants.sol";

/// @title ChapelWireYield — MockVenus + CompoundV2YieldHook on stable USDC/USDT (Steward-lite AC).
/// @notice Hook install is HIGH-tier (Chapel = 30m). Two-step:
///   1) `run` — deploy mocks/hooks, grant drip keeper, queue setAssetHook
///   2) after >=30m: `execute` — executeSetAssetHook
/// @dev Env: DEPLOYER_PK, ADMIN, AC, STABLE_POOL, optional YIELD_DRIP_KEEPER.
contract ChapelWireYield is Script {
  address constant USDC = 0x6dF80a290E0585dad752c25f2808E83b5624290d;
  address constant USDT = 0xB7b7722369Ab72cb044DE6bb511A4586F3a7dD64;

  /// @notice Venus core-pool Unitroller (Comptroller proxy) on BSC Chapel testnet.
  ///         Reward-claim source for the CompoundV2YieldHook; `claimVenus(address,address[])`
  ///         = 0x86df31ee. ⚠ MockVenus cTokens are NOT registered markets in this Unitroller,
  ///         so live claims (`_claimVenueIncentives`) revert until the vTokens below are swapped
  ///         for real Venus vUSDC/vUSDT Chapel markets.
  address constant VENUS_UNITROLLER = 0x94d1820b2D1c7c7452A163983Dc888CEC546b77D;
  bytes4 constant CLAIM_VENUS = 0x86df31ee;

  uint32 constant FLAGS = C.HOOK_PRE_OUTFLOW | C.HOOK_POST_INFLOW;

  function run() external {
    uint256 pk = vm.envUint("DEPLOYER_PK");
    address adminAddr = vm.envAddress("ADMIN");
    address acAddr = vm.envAddress("AC");
    address stable = vm.envAddress("STABLE_POOL");
    address ops = vm.envAddress("OPS_TREASURY"); // opsTreasuryProxy from Deploy.s.sol
    address drip = vm.envOr("YIELD_DRIP_KEEPER", address(0));

    Admin admin = Admin(adminAddr);
    AccessControl ac = AccessControl(acAddr);

    vm.startBroadcast(pk);

    if (drip != address(0)) ac.setKeeper(drip, true);

    // Wire pool.treasury() → OpsTreasury (HIGH-tier, Chapel = 30m). Pool.initialize leaves
    // treasury=0, so sweepIncentives reverts ZeroAddr until this executes. Queued here,
    // finalized in execute() alongside the hooks (same window).
    admin.requestTreasuryUpdate(stable, ops);

    MockVenus vUsdc = new MockVenus(USDC);
    MockVenus vUsdt = new MockVenus(USDT);
    // Reward source = real Venus Unitroller + claimVenus selector (was 0/0 = no-op claim).
    CompoundV2YieldHook hUsdc =
      new CompoundV2YieldHook(acAddr, stable, USDC, address(vUsdc), VENUS_UNITROLLER, CLAIM_VENUS);
    CompoundV2YieldHook hUsdt =
      new CompoundV2YieldHook(acAddr, stable, USDT, address(vUsdt), VENUS_UNITROLLER, CLAIM_VENUS);

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
    admin.executeTreasuryUpdate(stable);
    admin.executeSetAssetHook(stable, USDC);
    admin.executeSetAssetHook(stable, USDT);
    vm.stopBroadcast();
    console2.log("treasury + hooks live on stable USDC+USDT");
  }
}
