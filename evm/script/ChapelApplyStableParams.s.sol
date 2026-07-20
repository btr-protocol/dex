// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Script.sol";

import {Admin} from "../src/Admin.sol";
import {IAdmin} from "../src/interfaces/IAdmin.sol";
import {IPool} from "../src/interfaces/IPool.sol";

/// @title ChapelApplyStableParams — push stable-core risk params onto the live Chapel stable pool.
/// @notice Immediate: `setAssetParams` (fees/gamma/vega). Timelocked (Chapel LOW=5m / BASE=15m):
///         `requestSetCurve` (preset 2, tight stable) + `requestUpdateProfile` (preset + dispersion)
///         + `requestUpdateOracle` (refBand). Pool is sealed ⇒ curve goes through the timelocked
///         twin, not the bootstrap `setCurve`. Risk coverage/flags already correct (flags=6).
/// @dev Run (gas 0.1 gwei):
///   # 1) fees now + queue profile/oracle
///   forge script script/ChapelApplyStableParams.s.sol:ChapelApplyStableParams --sig run \
///     --rpc-url chapel --broadcast --with-gas-price 100000000
///   # 2) after ≥5m: execute profiles
///   forge script ... --sig executeProfiles --rpc-url chapel --broadcast --with-gas-price 100000000
///   # 3) after ≥15m: execute oracles
///   forge script ... --sig executeOracles --rpc-url chapel --broadcast --with-gas-price 100000000
contract ChapelApplyStableParams is Script {
  address constant ADMIN = 0x71ad34866B2bB0E99478297DA735E9b94922B7Fb;
  address constant STABLE = 0xC954A27E69ae7C9d10a136c4f7F3910b38F09324;
  address constant ORACLE = 0xD91712c9F4037D0010041691Df191AB45994F2bF;
  bytes32 constant USDC_FEED = 0xdacab87341ef44905f4cfdb16cbfbd61ad65accd449f2df15ae6fb26f53ba17d;

  address constant USDC = 0x6dF80a290E0585dad752c25f2808E83b5624290d;
  address constant USDT = 0xB7b7722369Ab72cb044DE6bb511A4586F3a7dD64;
  address constant USD1 = 0xC28bE4D407096E771F932c202F13D866B4d6BA07;
  address constant USDE = 0xebF751546832ec77a039083E9FDd8158B21c0172;
  address constant FDUSD = 0x4Aa480f3dc3a1f08c24472E083fBDBE919b8BdFc;

  function run() external {
    uint256 pk = vm.envUint("DEPLOYER_PK");
    Admin admin = Admin(ADMIN);
    address refOracle = vm.envAddress("REF_ORACLE");
    require(refOracle != address(0) && refOracle != ORACLE, "independent REF_ORACLE required");
    address[5] memory toks = [USDC, USDT, USD1, USDE, FDUSD];

    vm.startBroadcast(pk);
    (uint256[] memory interior, int256[] memory wQ) = _curve();
    admin.requestSetCurve(STABLE, 2, interior, wQ, 100, 0);
    for (uint256 i = 0; i < toks.length; i++) {
      address tok = toks[i];
      (uint16 minFee, uint32 minDisp, uint32 maxDisp, uint16 refBand) = _params(tok);
      // gamma=20000 (2× inventory skew), vega=1×, haircutSuppressor=10000
      admin.setAssetParams(STABLE, tok, 0, minFee, 2000, 20_000, 10_000, 10_000, 0, 0);
      admin.setRiskFences(STABLE, tok, _fences(tok));
      admin.requestUpdateProfile(STABLE, tok, 2, minDisp, maxDisp);
      admin.requestOracleUpdate(STABLE, tok, _oracle(tok, refBand, refOracle));
      console2.log("queued", tok, minFee, refBand);
    }
    vm.stopBroadcast();
    console2.log("setAssetParams+fences done; profile ETA ~5m; oracle ETA ~15m");
  }

  function executeProfiles() external {
    uint256 pk = vm.envUint("DEPLOYER_PK");
    Admin admin = Admin(ADMIN);
    address[5] memory toks = [USDC, USDT, USD1, USDE, FDUSD];
    vm.startBroadcast(pk);
    admin.executeSetCurve(STABLE, 2); // preset 2 must land before profiles referencing it
    for (uint256 i = 0; i < toks.length; i++) {
      admin.executeUpdateProfile(STABLE, toks[i]);
      console2.log("profile ok", toks[i]);
    }
    vm.stopBroadcast();
  }

  function executeOracles() external {
    uint256 pk = vm.envUint("DEPLOYER_PK");
    Admin admin = Admin(ADMIN);
    address[5] memory toks = [USDC, USDT, USD1, USDE, FDUSD];
    vm.startBroadcast(pk);
    for (uint256 i = 0; i < toks.length; i++) {
      admin.executeOracleUpdate(STABLE, toks[i]);
      console2.log("oracle ok", toks[i]);
    }
    vm.stopBroadcast();
  }

  // placeholder: production weights come from research/stable-core/out/spline_shared_grid.json at deploy
  /// @dev Preset 2 = tight stable: linear ±50 pbps ramp over 9 quartic weights, dispRef 100.
  function _curve() internal pure returns (uint256[] memory interior, int256[] memory wQ) {
    interior = new uint256[](4);
    interior[0] = 2000;
    interior[1] = 4000;
    interior[2] = 6000;
    interior[3] = 8000;
    wQ = new int256[](9);
    for (uint256 i = 0; i < 9; i++) {
      wQ[i] = (int256(i) - 4) * 12_500_000_000;
    }
  }

  function _params(address tok)
    internal
    pure
    returns (uint16 minFee, uint32 minDisp, uint32 maxDisp, uint16 refBand)
  {
    // minFee PBPS (100=1bp). refBand: ±1% depeg vs USDC for every non-base stable.
    if (tok == USDC) return (50, 200, 2000, 0);
    if (tok == USDT) return (50, 600, 6000, 100);
    if (tok == USD1) return (50, 500, 5000, 100);
    if (tok == USDE) return (75, 800, 5000, 100);
    if (tok == FDUSD) return (100, 1000, 8000, 100);
    revert("unknown");
  }

  function _oracle(address tok, uint16 refBand, address refOracle)
    internal
    pure
    returns (IPool.OracleConfig memory o)
  {
    o.primary = ORACLE;
    o.feedId = tok == USDC ? USDC_FEED : keccak256(abi.encodePacked(tok, USDC));
    // All non-base stables: USDC refFeed + refBand (±1%). USDC itself: no self-ref.
    if (tok != USDC && refBand != 0) {
      o.refFeedId = USDC_FEED;
      o.refBandBps = refBand;
      o.refPrimary = refOracle;
    } else {
      o.refFeedId = bytes32(0);
      o.refBandBps = 0;
    }
    o.mode = 0; // EXTERNAL
  }

  /// @dev Steward-lite fences: hard band + ±25% risk-up. Tighten is clamp-exempt on-chain.
  function _fences(address tok) internal pure returns (IAdmin.RiskFences memory f) {
    f.minFeeHardMin = tok == FDUSD ? 50 : 25;
    f.minFeeHardMax = 2_000;
    f.maxFeeHardMax = 10_000;
    f.gammaHardMin = 5_000;
    f.gammaHardMax = 40_000;
    f.vegaHardMin = 5_000;
    f.vegaHardMax = 20_000;
    f.haircutHardMax = 10_000;
    f.maxDeltaBps = 2_500;
  }
}
