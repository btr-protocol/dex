// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Admin} from "../src/Admin.sol";
import {Pool} from "../src/Pool.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {ChapelSeedAmounts} from "./ChapelSeedAmounts.sol";

/// @notice Seed Chapel pools on an already-deployed Admin+Factory (SWAP flags at listing).
/// @dev Env: DEPLOYER_PK, ADMIN, FACTORY, REF_ORACLE, XAUT_REF_ORACLE,
///      XAUT_REF_FEED_ID. Optional SEED_USDC (default 50_000e18).
contract ChapelSeedPools is Script {
  address constant ORACLE = 0xD91712c9F4037D0010041691Df191AB45994F2bF;
  address constant FAUCET = 0x6a901982CE6cD2561F677217e012A33b8a88EF27;
  address constant AC = 0x626eb915d4a4136F7c00352A54378d3A322488da;
  address constant WNATIVE = address(0xCAFE);
  bytes32 constant USDC_FEED = 0xdacab87341ef44905f4cfdb16cbfbd61ad65accd449f2df15ae6fb26f53ba17d;

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
    Admin admin = Admin(vm.envAddress("ADMIN"));
    PoolFactory factory = PoolFactory(payable(vm.envAddress("FACTORY")));
    address refOracle = vm.envAddress("REF_ORACLE");
    address xautRefOracle = vm.envAddress("XAUT_REF_ORACLE");
    bytes32 xautRefFeedId = vm.envBytes32("XAUT_REF_FEED_ID");
    require(refOracle != address(0) && refOracle != ORACLE, "independent REF_ORACLE required");
    require(
      xautRefOracle != address(0) && xautRefOracle != ORACLE, "independent XAUT_REF_ORACLE required"
    );
    require(
      xautRefFeedId == keccak256(abi.encodePacked(XAUT, USDC)), "XAUT_REF_FEED_ID must be XAUT/USDC"
    );
    uint256 seedUsdc = vm.envOr("SEED_USDC", uint256(50_000 ether));

    vm.startBroadcast(pk);
    address stable = _createPool(
      admin, factory, _stableList(), seedUsdc, true, refOracle, xautRefOracle, xautRefFeedId
    );
    address vol = _createPool(
      admin, factory, _volatileList(), seedUsdc, false, refOracle, xautRefOracle, xautRefFeedId
    );
    vm.stopBroadcast();

    console2.log("stablePool", stable);
    console2.log("volatilePool", vol);
    console2.log("admin", address(admin));
    console2.log("factory", address(factory));

    string memory k = "chapel";
    vm.serializeUint(k, "chainId", uint256(97));
    vm.serializeAddress(k, "ac", AC);
    vm.serializeAddress(k, "admin", address(admin));
    vm.serializeAddress(k, "poolFactory", address(factory));
    vm.serializeAddress(k, "oracle", ORACLE);
    vm.serializeAddress(k, "faucet", FAUCET);
    vm.serializeAddress(k, "stablePool", stable);
    vm.serializeAddress(k, "volatilePool", vol);
    vm.serializeBytes32(k, "usdcFeedId", USDC_FEED);
    vm.serializeAddress(k, "usdc", USDC);
    vm.serializeAddress(k, "usdt", USDT);
    vm.serializeAddress(k, "usd1", USD1);
    vm.serializeAddress(k, "usde", USDE);
    vm.serializeAddress(k, "fdusd", FDUSD);
    vm.serializeAddress(k, "btcb", BTCB);
    vm.serializeAddress(k, "eth", ETH);
    vm.serializeAddress(k, "wbnb", WBNB);
    vm.serializeAddress(k, "cake", CAKE);
    string memory json = vm.serializeAddress(k, "xaut", XAUT);
    try vm.writeJson(json, "deployments/97.deploy.json") {} catch {}
  }

  function _stableList() internal pure returns (address[] memory list) {
    list = new address[](5);
    list[0] = USDC;
    list[1] = USDT;
    list[2] = USD1;
    list[3] = USDE;
    list[4] = FDUSD;
  }

  function _volatileList() internal pure returns (address[] memory list) {
    list = new address[](7);
    list[0] = USDC;
    list[1] = USDT;
    list[2] = BTCB;
    list[3] = ETH;
    list[4] = WBNB;
    list[5] = CAKE;
    list[6] = XAUT;
  }

  function _createPool(
    Admin admin,
    PoolFactory factory,
    address[] memory tokens,
    uint256 seedUsdc,
    bool stable,
    address refOracle,
    address xautRefOracle,
    bytes32 xautRefFeedId
  ) internal returns (address poolAddr) {
    IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 20, flashFeePbps: 100});
    bytes memory initdata = abi.encodeWithSelector(Pool.initialize.selector, tokens[0], WNATIVE, fp);
    poolAddr = factory.createPool(tokens[0], tokens, initdata);

    IPool.RiskConfig memory rc = _risk();
    // Preset 1 (generic default) must exist pre-seal, before the first addAsset referencing it.
    (uint256[] memory interior, int256[] memory wQ) = _curve();
    admin.setCurve(poolAddr, 1, interior, wQ, 1000, 0);
    for (uint256 i = 0; i < tokens.length; i++) {
      address tok = tokens[i];
      (uint16 minFee, uint16 refBand) = _assetParams(tok, stable);
      admin.addAsset(
        poolAddr,
        tok,
        _oracleCfg(tok, tokens[0], refBand, refOracle, xautRefOracle, xautRefFeedId),
        rc,
        1,
        minFee,
        18,
        1000,
        100_000,
        10_000,
        10_000
      );
    }
    admin.sealBootstrap(poolAddr);
    _seedPool(Pool(payable(poolAddr)), tokens, seedUsdc);
  }

  function _risk() internal pure returns (IPool.RiskConfig memory r) {
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20_000;
    r.depthAmplifier = 10_000;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
  }

  // placeholder: production weights come from research/stable-core/out/spline_shared_grid.json at deploy
  /// @dev Preset 1 = generic default: linear ±500 pbps ramp over 9 quartic weights.
  function _curve() internal pure returns (uint256[] memory interior, int256[] memory wQ) {
    interior = new uint256[](4);
    interior[0] = 2000;
    interior[1] = 4000;
    interior[2] = 6000;
    interior[3] = 8000;
    wQ = new int256[](9);
    for (uint256 i = 0; i < 9; i++) {
      wQ[i] = (int256(i) - 4) * 125_000_000_000;
    }
  }

  function _assetParams(address tok, bool stable)
    internal
    pure
    returns (uint16 minFee, uint16 refBand)
  {
    minFee = 1;
    if (tok == USDT) refBand = 100;
    else if (stable && tok != USDC) refBand = 150;
    else if (!stable && tok == XAUT) refBand = 200;
    // M-1: every EXTERNAL spoke needs a cumulative bound; BTCB/ETH/WBNB/CAKE get a 3% cross-oracle
    // tolerance vs their OWN pair feed on REF_ORACLE (USDC = base, exempt; band unused there).
    else if (!stable && tok != USDC) refBand = 300;
  }

  function _oracleCfg(
    address asset,
    address base,
    uint16 refBandBps,
    address refOracle,
    address xautRefOracle,
    bytes32 xautRefFeedId
  ) internal pure returns (IPool.OracleConfig memory o) {
    o.primary = ORACLE;
    o.feedId = keccak256(abi.encodePacked(asset, base));
    if (refBandBps != 0) {
      bool isXaut = asset == XAUT;
      bool isVolatileCore = asset == BTCB || asset == ETH || asset == WBNB || asset == CAKE;
      // Volatile non-pegged assets ref their OWN pair feed on the independent oracle; comparing a
      // non-USD mark to the unit-price USDC feed would halt permanently.
      o.refFeedId = isXaut ? xautRefFeedId : isVolatileCore ? o.feedId : USDC_FEED;
      o.refBandBps = refBandBps;
      o.refPrimary = isXaut ? xautRefOracle : refOracle;
    }
  }

  function _seedAmount(address tok, uint256 seedUsdc) internal view returns (uint256) {
    return ChapelSeedAmounts.seedAmount(tok, seedUsdc);
  }

  function _seedPool(Pool pool, address[] memory tokens, uint256 seedUsdc) internal {
    for (uint256 i = 0; i < tokens.length; i++) {
      address tok = tokens[i];
      uint256 amt = _seedAmount(tok, seedUsdc);
      IERC20(tok).approve(address(pool), type(uint256).max);
      pool.deposit(tok, amt);
    }
  }
}
