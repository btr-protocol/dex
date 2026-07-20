// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Script.sol";

import {Admin} from "../src/Admin.sol";

/// @title ChapelWidenVolatileDisp — widen volatile-core dispersion band (minDisp 50k PBPS).
/// @notice Timelocked LOW (Chapel ~5m): requestUpdateProfile keeps preset 1 (generic default curve,
///         installed at pool deploy), raises dispersion (was minDisp=1000).
/// @dev
///   forge script script/ChapelWidenVolatileDisp.s.sol:ChapelWidenVolatileDisp --sig run \
///     --rpc-url chapel --broadcast --with-gas-price 100000000
///   # after ≥5m:
///   forge script ... --sig executeProfiles --rpc-url chapel --broadcast --with-gas-price 100000000
contract ChapelWidenVolatileDisp is Script {
  address constant ADMIN = 0x71ad34866B2bB0E99478297DA735E9b94922B7Fb;
  address constant VOLATILE = 0x88d5EC4C0c83391a9C84Bc196911084D7179AA40;

  address constant USDC = 0x6dF80a290E0585dad752c25f2808E83b5624290d;
  address constant USDT = 0xB7b7722369Ab72cb044DE6bb511A4586F3a7dD64;
  address constant BTCB = 0xd719319e853670ac938e426fbdB70CFdb34c11Fa;
  address constant ETH = 0x24Ff1aCD4e8fdBFEBee2e7e63ad36B1E72821189;
  address constant WBNB = 0x31B7DCA9e901F7D34fb4a3Ee07eD2994de16685D;
  address constant CAKE = 0xa7E62dd82789346bEb48a80227B5d926c6403400;
  address constant XAUT = 0xd384aC4696FA230c9049F6534Fc35aC3af586073;

  uint32 constant MIN_DISP = 50_000;
  uint32 constant MAX_DISP = 500_000;

  function run() external {
    uint256 pk = vm.envUint("DEPLOYER_PK");
    Admin admin = Admin(ADMIN);
    address[7] memory toks = [USDC, USDT, BTCB, ETH, WBNB, CAKE, XAUT];

    vm.startBroadcast(pk);
    for (uint256 i = 0; i < toks.length; i++) {
      admin.requestUpdateProfile(VOLATILE, toks[i], 1, MIN_DISP, MAX_DISP);
      console2.log("queued profile", toks[i]);
    }
    vm.stopBroadcast();
    console2.log("profile ETA ~5m - then run executeProfiles()");
  }

  function executeProfiles() external {
    uint256 pk = vm.envUint("DEPLOYER_PK");
    Admin admin = Admin(ADMIN);
    address[7] memory toks = [USDC, USDT, BTCB, ETH, WBNB, CAKE, XAUT];
    vm.startBroadcast(pk);
    for (uint256 i = 0; i < toks.length; i++) {
      admin.executeUpdateProfile(VOLATILE, toks[i]);
      console2.log("profile ok", toks[i]);
    }
    vm.stopBroadcast();
  }
}
