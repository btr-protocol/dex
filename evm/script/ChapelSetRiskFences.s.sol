// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Script.sol";

import {Admin} from "../src/Admin.sol";
import {IAdmin} from "../src/interfaces/IAdmin.sol";

/// @title ChapelSetRiskFences — owner-set Steward-lite fences on live testnet pools.
/// @notice Requires Admin bytecode that exposes `setRiskFences` (post Steward-lite redeploy).
///         AccessControl must also expose `setGuardian` / `setRiskSteward` for those roles to work;
///         fences themselves are Admin storage and only need the owner key.
/// @dev Run:
///   forge script script/ChapelSetRiskFences.s.sol:ChapelSetRiskFences --sig run \
///     --rpc-url chapel --broadcast --with-gas-price 100000000
contract ChapelSetRiskFences is Script {
  address constant ADMIN = 0x71ad34866B2bB0E99478297DA735E9b94922B7Fb;
  address constant STABLE = 0xC954A27E69ae7C9d10a136c4f7F3910b38F09324;
  address constant VOL = 0x88d5EC4C0c83391a9C84Bc196911084D7179AA40;

  address constant USDC = 0x6dF80a290E0585dad752c25f2808E83b5624290d;
  address constant USDT = 0xB7b7722369Ab72cb044DE6bb511A4586F3a7dD64;
  address constant USD1 = 0xC28bE4D407096E771F932c202F13D866B4d6BA07;
  address constant USDE = 0xebF751546832ec77a039083E9FDd8158B21c0172;
  address constant FDUSD = 0x4Aa480f3dc3a1f08c24472E083fBDBE919b8BdFc;
  address constant BTCB = 0xd719319e853670ac938e426fbdB70CFdb34c11Fa;
  address constant ETH = 0x24Ff1aCD4e8fdBFEBee2e7e63ad36B1E72821189;
  address constant WBNB = 0x31B7DCA9e901F7D34fb4a3Ee07eD2994de16685D;
  address constant CAKE = 0xa7E62dd82789346bEb48a80227B5d926c6403400;
  address constant XAUT = 0xd384aC4696FA230c9049F6534Fc35aC3af586073;

  function run() external {
    uint256 pk = vm.envUint("DEPLOYER_PK");
    Admin admin = Admin(ADMIN);

    address[5] memory stables = [USDC, USDT, USD1, USDE, FDUSD];
    address[7] memory vols = [USDC, USDT, BTCB, ETH, WBNB, CAKE, XAUT];

    vm.startBroadcast(pk);
    for (uint256 i = 0; i < stables.length; i++) {
      admin.setRiskFences(STABLE, stables[i], _stableFences(stables[i]));
      console2.log("stable fences", stables[i]);
    }
    for (uint256 i = 0; i < vols.length; i++) {
      admin.setRiskFences(VOL, vols[i], _volatileFences(vols[i]));
      console2.log("volatile fences", vols[i]);
    }
    vm.stopBroadcast();
  }

  /// @dev Hard band around current testnet stable-core operating range; ±25% risk-up clamp.
  function _stableFences(address tok) internal pure returns (IAdmin.RiskFences memory f) {
    f.minFeeHardMin = 25; // 0.25 bp PBPS
    f.minFeeHardMax = 2_000; // 20 bp
    f.maxFeeHardMax = 10_000;
    f.gammaHardMin = 5_000;
    f.gammaHardMax = 40_000;
    f.vegaHardMin = 5_000;
    f.vegaHardMax = 20_000;
    f.haircutHardMax = 10_000;
    f.maxDeltaBps = 2_500;
    // FDUSD can sit a bit higher on minFee floor intent.
    if (tok == FDUSD) f.minFeeHardMin = 50;
  }

  function _volatileFences(address tok) internal pure returns (IAdmin.RiskFences memory f) {
    f.minFeeHardMin = 100; // 1 bp
    f.minFeeHardMax = 20_000; // 200 bp
    f.maxFeeHardMax = 50_000;
    f.gammaHardMin = 5_000;
    f.gammaHardMax = 40_000;
    f.vegaHardMin = 5_000;
    f.vegaHardMax = 30_000;
    f.haircutHardMax = 10_000;
    f.maxDeltaBps = 2_500;
    // Stable legs inside the volatile pool keep the tighter stable band.
    if (tok == USDC || tok == USDT) {
      f.minFeeHardMin = 25;
      f.minFeeHardMax = 2_000;
      f.maxFeeHardMax = 10_000;
      f.vegaHardMax = 20_000;
    }
  }
}
