// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {Admin} from "../src/Admin.sol";
import {Flash} from "../src/Flash.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {IAdmin} from "../src/interfaces/IAdmin.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {NUQuartic} from "../src/libraries/NUQuartic.sol";
import {TestnetERC20} from "../src/testnet/TestnetERC20.sol";
import {ChapelSeedAmounts} from "./ChapelSeedAmounts.sol";

/// @title ChapelEnableSwaps — surgical Chapel reseed: new AC+Admin+pools; keep oracle/tokens/faucet.
/// @notice Bakes `deploy/testnet-asset-params.json` (2026-07-12b): stable κ wall, γ=2×, refs, fees.
///         New AccessControl so Steward-lite `isGuardian` / `isRiskSteward` exist. ExternalOracle
///         stays on incumbent AC (same owner EOA) — pusher grants unchanged.
/// @dev Required env: DEPLOYER_PK, REF_ORACLE, XAUT_REF_ORACLE, XAUT_REF_FEED_ID.
/// @dev Run:
///   forge script script/ChapelEnableSwaps.s.sol:ChapelEnableSwaps --sig run \
///     --rpc-url chapel --broadcast --with-gas-price 100000000
contract ChapelEnableSwaps is Script {
  address constant OLD_AC = 0x626eb915d4a4136F7c00352A54378d3A322488da;
  address constant ORACLE = 0xD91712c9F4037D0010041691Df191AB45994F2bF;
  address constant FAUCET = 0x6a901982CE6cD2561F677217e012A33b8a88EF27;
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

  uint16 constant GAMMA = 20_000; // 2× inventory skew (SSoT)
  uint16 constant VEGA = 10_000;

  function run() external {
    uint256 pk = vm.envUint("DEPLOYER_PK");
    address deployer = vm.addr(pk);
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

    // Fresh AC (Steward-lite whitelists). Owner+treasury = deployer (matches live Chapel).
    AccessControl ac = new AccessControl(deployer, deployer);

    Admin admin = new Admin(address(ac));
    Flash flash = new Flash();
    PoolAux poolAux = new PoolAux(address(ac), address(admin), address(flash));
    Pool poolImpl = new Pool(address(ac), address(admin), address(flash), address(poolAux));
    PoolFactory factory = new PoolFactory(address(poolImpl), deployer, address(ac));

    address stable = _createPool(
      admin, factory, _stableList(), seedUsdc, true, refOracle, xautRefOracle, xautRefFeedId
    );
    address vol = _createPool(
      admin, factory, _volatileList(), seedUsdc, false, refOracle, xautRefOracle, xautRefFeedId
    );

    vm.stopBroadcast();

    console2.log("=== ChapelEnableSwaps ===");
    console2.log("ac(new)", address(ac));
    console2.log("ac(old/oracle)", OLD_AC);
    console2.log("admin", address(admin));
    console2.log("factory", address(factory));
    console2.log("stablePool", stable);
    console2.log("volatilePool", vol);
    console2.log("oracle(kept)", ORACLE);
    console2.log("faucet(kept)", FAUCET);

    _persist(address(ac), address(admin), address(factory), stable, vol);
  }

  function _stableList() internal pure returns (address[] memory list) {
    // SSoT also lists USDG — no Chapel mock token yet; 5 live stables only.
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

    IPool.RiskConfig memory rcBase = _riskStableBase();
    IPool.RiskConfig memory rcSpoke = stable ? _riskStableSpoke() : _riskVolatile();
    // Fitted preset curves must exist pre-seal, before the first addAsset referencing them.
    _installPresets(admin, poolAddr, stable);

    for (uint256 i = 0; i < tokens.length; i++) {
      address tok = tokens[i];
      (uint16 minFee, uint16 refBand, uint32 minDisp, uint32 maxDisp) = _assetParams(tok, stable);
      IPool.OracleConfig memory oc =
        _oracleCfg(tok, tokens[0], refBand, refOracle, xautRefOracle, xautRefFeedId);
      // Base numeraire forbids κ wall (PoolAdminWrite); spokes use stable κ=100.
      IPool.RiskConfig memory rc = (tok == tokens[0]) ? rcBase : rcSpoke;
      uint16 presetId = _presetFor(tok, stable);
      admin.addAsset(poolAddr, tok, oc, rc, presetId, minFee, 18, minDisp, maxDisp, GAMMA, VEGA);
      // initAsset defaults maxFeeBps=BPS; clamp to SSoT. κ-walled spokes require haircut=0.
      uint16 maxFee = stable ? 2_000 : 10_000;
      uint16 haircut = (rc.kappaCovBps > 0) ? 0 : 10_000;
      admin.setAssetParams(poolAddr, tok, 0, minFee, maxFee, GAMMA, VEGA, haircut, 0, 0);
      admin.setRiskFences(poolAddr, tok, _fences(tok, stable));
    }

    admin.sealBootstrap(poolAddr);
    _seedPool(Pool(payable(poolAddr)), tokens, seedUsdc);
  }

  /// @dev Base USDC: κ must be 0 (numeraire never walled). Shared decay/coverage floors.
  function _riskStableBase() internal pure returns (IPool.RiskConfig memory r) {
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20_000;
    r.depthAmplifier = 10_000;
    r.kappaCovBps = 0;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
  }

  /// @dev Stable spokes: coverage wall ON, no depth subsidy.
  function _riskStableSpoke() internal pure returns (IPool.RiskConfig memory r) {
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20_000;
    r.depthAmplifier = 0;
    r.kappaCovBps = 100;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
  }

  function _riskVolatile() internal pure returns (IPool.RiskConfig memory r) {
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20_000;
    r.depthAmplifier = 10_000;
    r.kappaCovBps = 0;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
  }

  /// @notice Install every fitted preset referenced by this pool, pre-seal (addAsset requires them).
  /// @dev Stable pool: 10 plateau-W1, 11 hyper-W0.5 (REQUIRES_WALL), 12 plateau-W2.
  ///      Volatile pool: 20 plateau-W1, 21 lepto-W5 (BTCB/ETH/WBNB/CAKE/XAUT).
  function _installPresets(Admin admin, address pool, bool stable) internal {
    uint16[3] memory sids = [uint16(10), 11, 12];
    uint16[2] memory vids = [uint16(20), 21];
    uint256 n = stable ? 3 : 2;
    for (uint256 i = 0; i < n; i++) {
      uint16 id = stable ? sids[i] : vids[i];
      (uint256[] memory interior, int256[] memory wQ, uint16 dispRef, uint8 flags) = _preset(id);
      admin.setCurve(pool, id, interior, wQ, dispRef, flags);
    }
  }

  /// @notice Per-asset default preset (SSoT: research/stable-core/RISK_PARAMS_TESTNET.md §3/§4).
  /// @dev hyper (11) is reserved to the coverage-walled USDT spoke; base + un-walled legs use plateau.
  function _presetFor(address tok, bool stable) internal pure returns (uint16) {
    if (stable) {
      if (tok == USDT) return 11; // hyper W0.5 (walled, κ=100)
      if (tok == USDE) return 12; // plateau W2
      return 10; // USDC(base), USD1, FDUSD -> plateau W1
    }
    // CAKE + XAUT reassigned platy/meso -> lepto W5 after the density overlay showed both are
    // fat-tailed (kurt 36/35, tail-alpha ~2-3); platy/meso under-fit the tails, lepto is honest.
    if (tok == BTCB || tok == ETH || tok == WBNB || tok == CAKE || tok == XAUT) return 21; // lepto W5
    return 20; // USDC(base), USDT -> plateau W1
  }

  /// @notice Fitted quartic I-spline presets. Integers verbatim from
  ///         `test/proto/quartic_vectors.json` (pbps·Q, Q=1e9); research SSoT =
  ///         `research/stable-core/out/spline_shared_grid.json`. dispRef(pbps) = wall(bp)·100, and
  ///         the fit's edge wQ[last] ≈ dispRef·Q (verified per preset). flags = FLAG_REQUIRES_WALL
  ///         only on hyper (11).
  function _preset(uint16 presetId)
    internal
    pure
    returns (uint256[] memory interior, int256[] memory wQ, uint16 dispRef, uint8 flags)
  {
    if (presetId == 10 || presetId == 20) return _fitW1Plateau();
    if (presetId == 11) return _fitW05Hyper();
    if (presetId == 12) return _fitW2Plateau();
    if (presetId == 21) return _fitLepto();
    revert("unknown preset");
  }

  // --- Fitted vectors (verbatim from quartic_vectors.json) -----------------------------------

  /// @dev vector key `W1_plateau`; presets 10 (stable) + 20 (volatile). dispRef 100.
  function _fitW1Plateau()
    private
    pure
    returns (uint256[] memory interior, int256[] memory wQ, uint16 dispRef, uint8 flags)
  {
    interior = _dynI9([uint256(500), 1250, 2500, 3750, 5000, 6250, 7500, 8750, 9500]);
    wQ = _dynW14(
      [
        int256(-100_000_000_000),
        -92_850_900_000,
        -83_925_500_000,
        -71_143_900_000,
        -54_153_400_000,
        -33_922_600_000,
        -11_258_100_000,
        11_258_100_000,
        33_922_600_000,
        54_153_400_000,
        71_143_900_000,
        83_925_500_000,
        92_851_000_000,
        99_999_400_000
      ]
    );
    dispRef = 100;
    flags = 0;
  }

  /// @dev vector key `W05_hyper`; preset 11. dispRef 50, FLAG_REQUIRES_WALL (needle only safe walled).
  function _fitW05Hyper()
    private
    pure
    returns (uint256[] memory interior, int256[] memory wQ, uint16 dispRef, uint8 flags)
  {
    interior = _dynI9([uint256(800), 2200, 3600, 4500, 5000, 5500, 6400, 7800, 9200]);
    wQ = _dynW14(
      [
        int256(-50_000_000_000),
        -24_880_500_000,
        -6_394_200_000,
        -2_604_100_000,
        -1_431_200_000,
        -734_700_000,
        -217_600_000,
        217_100_000,
        734_600_000,
        1_432_400_000,
        2_607_400_000,
        6_396_300_000,
        24_858_000_000,
        49_939_900_000
      ]
    );
    dispRef = 50;
    flags = NUQuartic.FLAG_REQUIRES_WALL;
  }

  /// @dev vector key `W2_plateau`; preset 12. dispRef 200 (13 interior / 18 wQ = 14 segs).
  function _fitW2Plateau()
    private
    pure
    returns (uint256[] memory interior, int256[] memory wQ, uint16 dispRef, uint8 flags)
  {
    interior = _dynI13(
      [uint256(500), 1000, 1250, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 8750, 9000, 9500]
    );
    wQ = _dynW18(
      [
        int256(-200_000_000_000),
        -183_640_600_000,
        -173_212_900_000,
        -157_195_400_000,
        -138_182_300_000,
        -114_963_700_000,
        -88_233_800_000,
        -54_109_500_000,
        -18_141_400_000,
        18_141_300_000,
        54_109_500_000,
        88_233_800_000,
        114_963_700_000,
        138_182_300_000,
        157_195_500_000,
        173_212_700_000,
        183_640_900_000,
        199_999_600_000
      ]
    );
    dispRef = 200;
    flags = 0;
  }

  /// @dev vector key `lepto`; preset 21. dispRef 500 (fat Student-t wings).
  function _fitLepto()
    private
    pure
    returns (uint256[] memory interior, int256[] memory wQ, uint16 dispRef, uint8 flags)
  {
    interior = _dynI9([uint256(500), 1000, 1250, 3000, 5000, 7000, 8750, 9000, 9500]);
    wQ = _dynW14(
      [
        int256(-500_000_000_000),
        -395_034_300_000,
        -296_995_100_000,
        -230_482_800_000,
        -138_926_100_000,
        -77_502_900_000,
        -25_288_300_000,
        25_288_300_000,
        77_502_900_000,
        138_926_100_000,
        230_482_800_000,
        296_995_000_000,
        395_034_400_000,
        499_999_800_000
      ]
    );
    dispRef = 500;
    flags = 0;
  }

  // Fixed→dynamic copies: keep the fitted vectors as one-line literals (auditable vs JSON) while
  // setCurve wants dynamic arrays. Sizes: W0.5/W1/W5 = 9 interior / 14 wQ; W2 = 13 interior / 18 wQ.
  function _dynI9(uint256[9] memory a) private pure returns (uint256[] memory o) {
    o = new uint256[](9);
    for (uint256 i = 0; i < 9; i++) {
      o[i] = a[i];
    }
  }

  function _dynI13(uint256[13] memory a) private pure returns (uint256[] memory o) {
    o = new uint256[](13);
    for (uint256 i = 0; i < 13; i++) {
      o[i] = a[i];
    }
  }

  function _dynW14(int256[14] memory a) private pure returns (int256[] memory o) {
    o = new int256[](14);
    for (uint256 i = 0; i < 14; i++) {
      o[i] = a[i];
    }
  }

  function _dynW18(int256[18] memory a) private pure returns (int256[] memory o) {
    o = new int256[](18);
    for (uint256 i = 0; i < 18; i++) {
      o[i] = a[i];
    }
  }

  function _fences(address tok, bool stable) internal pure returns (IAdmin.RiskFences memory f) {
    f.maxDeltaBps = 2_500;
    f.haircutHardMax = 10_000;
    f.gammaHardMin = 5_000;
    f.gammaHardMax = 40_000;
    f.vegaHardMin = 5_000;
    if (stable || tok == USDC || tok == USDT) {
      f.minFeeHardMin = 50; // 0.5 bp = 2θ (θ per keepers/oracle.chapel.toml; θ change MUST ship synced fence+minFee)
      f.minFeeHardMax = 2_000;
      f.maxFeeHardMax = 10_000;
      f.vegaHardMax = 20_000;
      // M-2 Δ2: absolute reservation fences (±5% of peg) — mandatory for any live steward band.
      // XAUT/volatile legs stay 0 (no band).
      f.reservationHardLoMin = M.encodeB64(0.95e18, 18);
      f.reservationHardHiMax = M.encodeB64(1.05e18, 18);
    } else {
      f.minFeeHardMin = 1_000; // 10 bp = 2θ (θ per keepers/oracle.chapel.toml; θ change MUST ship synced fence+minFee)
      f.minFeeHardMax = 20_000;
      f.maxFeeHardMax = 50_000;
      f.vegaHardMax = 30_000;
    }
  }

  /// @dev Per-asset from testnet-asset-params.json stable-core / volatile-core.
  function _assetParams(address tok, bool stable)
    internal
    pure
    returns (uint16 minFee, uint16 refBand, uint32 minDisp, uint32 maxDisp)
  {
    if (stable) {
      // Defaults then per-asset overrides (SSoT 2026-07-12b).
      minFee = 50;
      minDisp = 500;
      maxDisp = 5000;
      refBand = 100;
      if (tok == USDC) {
        minFee = 50;
        minDisp = 200;
        maxDisp = 2000;
        refBand = 0;
      } else if (tok == USDT) {
        minDisp = 600;
        maxDisp = 6000;
      } else if (tok == USD1) {
        minDisp = 500;
        maxDisp = 5000;
      } else if (tok == USDE) {
        minFee = 75;
        minDisp = 800;
        maxDisp = 5000;
      } else if (tok == FDUSD) {
        minFee = 100;
        minDisp = 1000;
        maxDisp = 8000;
      }
      return (minFee, refBand, minDisp, maxDisp);
    }
    minFee = 1000;
    minDisp = 50_000;
    maxDisp = 500_000;
    if (tok == USDT) refBand = 100;
    else if (tok == XAUT) refBand = 200;
    // M-1: every EXTERNAL spoke needs a cumulative bound; BTCB/ETH/WBNB/CAKE get a 3% cross-oracle
    // tolerance vs their OWN pair feed on REF_ORACLE (USDC = base, exempt; band unused there).
    else refBand = 300;
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
    o.feedId = asset == USDC ? USDC_FEED : keccak256(abi.encodePacked(asset, base));
    // Stable legs + volatile USDT use the independent USDC ref. Volatile non-pegged assets
    // (XAUT + BTCB/ETH/WBNB/CAKE) must ref their OWN pair feed on the independent oracle;
    // comparing a non-USD mark to the unit-price USDC feed would halt permanently and
    // provide no meaningful manipulation bound.
    if (asset != USDC && refBandBps != 0) {
      bool isXaut = asset == XAUT;
      bool isVolatileCore = asset == BTCB || asset == ETH || asset == WBNB || asset == CAKE;
      o.refFeedId = isXaut
        ? xautRefFeedId
        : isVolatileCore ? keccak256(abi.encodePacked(asset, base)) : USDC_FEED;
      o.refBandBps = refBandBps;
      o.refPrimary = isXaut ? xautRefOracle : refOracle;
    } else {
      o.refFeedId = bytes32(0);
      o.refBandBps = 0;
    }
    o.mode = 0;
  }

  function _seedAmount(address tok, uint256 seedUsdc) internal view returns (uint256) {
    return ChapelSeedAmounts.seedAmount(tok, seedUsdc);
  }

  function _seedPool(Pool pool, address[] memory tokens, uint256 seedUsdc) internal {
    for (uint256 i = 0; i < tokens.length; i++) {
      address tok = tokens[i];
      uint256 amt = _seedAmount(tok, seedUsdc);
      uint256 bal = IERC20(tok).balanceOf(msg.sender);
      if (bal < amt) TestnetERC20(tok).mint(msg.sender, amt - bal);
      IERC20(tok).approve(address(pool), type(uint256).max);
      pool.deposit(tok, amt);
    }
  }

  function _persist(address ac, address admin, address factory, address stable, address vol)
    internal
  {
    string memory k = "chapel";
    vm.serializeUint(k, "chainId", uint256(97));
    vm.serializeAddress(k, "ac", ac);
    vm.serializeAddress(k, "acOracle", OLD_AC);
    vm.serializeAddress(k, "admin", admin);
    vm.serializeAddress(k, "poolFactory", factory);
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
    try vm.writeJson(json, "deployments/97.deploy.json") {}
    catch {
      console2.log("(skip) writeJson");
      console2.log(json);
    }
  }
}
