// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {StableSwapPool} from "../../src/incumbents/curve/StableSwapPool.sol";
import {LiteCLFactory, LiteCLPool} from "../../src/incumbents/univ4/LiteCLPool.sol";
import {WombatLite} from "../../src/incumbents/wombat/WombatLite.sol";
import {FluidDexFactory, FluidDexPool} from "../../src/incumbents/fluid/FluidDexPool.sol";
import {TestnetERC20} from "../../src/testnet/TestnetERC20.sol";

/// @title IncumbentsDeploy — Curve / UniV4-lite / Wombat / Fluid Dex (exact math) on Chapel mocks.
/// @dev Env: DEPLOYER_PK. Tokens via USDC/USDT/USD1/USDE/FDUSD env OR auto-read
///      deployments/<chainId>.deploy.json from TestnetDeploy.
/// @dev forge script script/incumbents/IncumbentsDeploy.s.sol:IncumbentsDeploy \
///        --sig deployIncumbents --rpc-url chapel --broadcast
contract IncumbentsDeploy is Script {
  using stdJson for string;
  // Curve fee: 1e10 denom → 1e6 = 1 bp = 0.01%
  uint256 internal constant CURVE_FEE_1BP = 1e6;
  uint256 internal constant CURVE_A = 1000; // PCS Infinity fiat-stable preset

  // UniV4 fee units (hundredths of a bip)
  uint24 internal constant FEE_ULTRA = 5; // ~0.0005%
  uint24 internal constant FEE_1BP = 100; // 0.01%
  int24 internal constant TICK_STABLE = 1;

  // Wombat: amp k ≈ 0.0001 (flat), fee 2 bps
  uint256 internal constant WOMBAT_K = 1e14;
  uint256 internal constant WOMBAT_FEE_BPS = 2;

  // Fluid DexT1/DexLite: fee 100 = 1bp (10000=1%); range ±0.5%; center 1e27
  uint256 internal constant FLUID_FEE = 100;
  uint256 internal constant FLUID_RANGE_PCT = 50;
  uint256 internal constant FLUID_CENTER = 1e27;

  struct Tokens {
    address usdc;
    address usdt;
    address usd1;
    address usde;
    address fdusd;
  }

  struct Out {
    address curve3pool;
    address curveUsde;
    address curveFdusd;
    address clFactory;
    address wombat;
    address fluidFactory;
    uint256 nClPools;
    uint256 nFluidPools;
  }

  function deployIncumbents() external returns (Out memory o) {
    uint256 pk = vm.envUint("DEPLOYER_PK");
    address deployer = vm.addr(pk);
    Tokens memory t = _loadTokens();
    uint256 seed = vm.envOr("SEED_USDC", uint256(500_000 ether));

    vm.startBroadcast(pk);

    address[5] memory all = [t.usdc, t.usdt, t.usd1, t.usde, t.fdusd];
    for (uint256 i; i < 5; i++) {
      TestnetERC20(all[i]).mint(deployer, seed * 20);
    }

    o.curve3pool = _deployCurve3(t, seed);
    o.curveUsde = _deployCurve2(t.usdt, t.usde, seed);
    o.curveFdusd = _deployCurve2(t.usdc, t.fdusd, seed);

    LiteCLFactory clf = new LiteCLFactory();
    o.clFactory = address(clf);
    o.nClPools = _deployAllCL(clf, t, seed);

    o.wombat = _deployWombat(t, seed);

    FluidDexFactory ff = new FluidDexFactory();
    o.fluidFactory = address(ff);
    o.nFluidPools = _deployFluid(ff, t, seed);

    vm.stopBroadcast();

    _log(o);
    _persist(o, t);
  }

  function _loadTokens() internal returns (Tokens memory t) {
    try vm.envAddress("USDC") returns (address usdc) {
      t.usdc = usdc;
      t.usdt = vm.envAddress("USDT");
      t.usd1 = vm.envAddress("USD1");
      t.usde = vm.envAddress("USDE");
      t.fdusd = vm.envAddress("FDUSD");
      return t;
    } catch {}

    string memory path = vm.envOr(
      "DEPLOY_JSON", string.concat("deployments/", vm.toString(block.chainid), ".deploy.json")
    );
    string memory json = vm.readFile(path);
    t.usdc = json.readAddress(".usdc");
    t.usdt = json.readAddress(".usdt");
    t.usd1 = json.readAddress(".usd1");
    t.usde = json.readAddress(".usde");
    t.fdusd = json.readAddress(".fdusd");
  }

  function _approve(address token, address spender, uint256 amt) internal {
    IERC20(token).approve(spender, amt);
  }

  function _deployCurve3(Tokens memory t, uint256 seed) internal returns (address pool) {
    address[] memory coins = new address[](3);
    coins[0] = t.usdt;
    coins[1] = t.usdc;
    coins[2] = t.usd1;
    StableSwapPool p = new StableSwapPool(coins, CURVE_A, CURVE_FEE_1BP);
    pool = address(p);
    uint256[] memory amts = new uint256[](3);
    amts[0] = seed;
    amts[1] = seed;
    amts[2] = seed;
    for (uint256 i; i < 3; i++) {
      _approve(coins[i], pool, seed);
    }
    p.add_liquidity(amts, 0);
  }

  function _deployCurve2(address a, address b, uint256 seed) internal returns (address pool) {
    address[] memory coins = new address[](2);
    coins[0] = a;
    coins[1] = b;
    StableSwapPool p = new StableSwapPool(coins, CURVE_A, CURVE_FEE_1BP);
    pool = address(p);
    uint256[] memory amts = new uint256[](2);
    amts[0] = seed;
    amts[1] = seed;
    _approve(a, pool, seed);
    _approve(b, pool, seed);
    p.add_liquidity(amts, 0);
  }

  function _deployAllCL(LiteCLFactory clf, Tokens memory t, uint256 seed)
    internal
    returns (uint256 n)
  {
    address[5] memory toks = [t.usdc, t.usdt, t.usd1, t.usde, t.fdusd];
    uint24[2] memory fees = [FEE_ULTRA, FEE_1BP];
    for (uint256 i; i < 5; i++) {
      for (uint256 j = i + 1; j < 5; j++) {
        for (uint256 f; f < 2; f++) {
          address pool = clf.createPool(toks[i], toks[j], fees[f], TICK_STABLE);
          _approve(toks[i], pool, seed);
          _approve(toks[j], pool, seed);
          LiteCLPool(pool).mint(seed, seed, msg.sender);
          n++;
        }
      }
    }
  }

  function _deployWombat(Tokens memory t, uint256 seed) internal returns (address pool) {
    address[] memory toks = new address[](4);
    toks[0] = t.usdc;
    toks[1] = t.usdt;
    toks[2] = t.usd1;
    toks[3] = t.usde;
    WombatLite w = new WombatLite(toks, WOMBAT_K, WOMBAT_FEE_BPS);
    pool = address(w);
    for (uint256 i; i < 4; i++) {
      _approve(toks[i], pool, seed);
      w.deposit(toks[i], seed, 0);
    }
  }

  function _deployFluid(FluidDexFactory ff, Tokens memory t, uint256 seed)
    internal
    returns (uint256 n)
  {
    address[2][6] memory pairs = [
      [t.usdt, t.usdc],
      [t.usdt, t.usd1],
      [t.usdc, t.usd1],
      [t.usdt, t.usde],
      [t.usdc, t.fdusd],
      [t.usdt, t.fdusd]
    ];
    for (uint256 i; i < 6; i++) {
      address pool = ff.createPool(
        pairs[i][0], pairs[i][1], FLUID_FEE, FLUID_RANGE_PCT, FLUID_RANGE_PCT, FLUID_CENTER
      );
      _approve(pairs[i][0], pool, seed);
      _approve(pairs[i][1], pool, seed);
      FluidDexPool(pool).initialize(seed, seed);
      n++;
    }
  }

  function _log(Out memory o) internal pure {
    console2.log("=== incumbents ===");
    console2.log("curve3pool", o.curve3pool);
    console2.log("curveUsde", o.curveUsde);
    console2.log("curveFdusd", o.curveFdusd);
    console2.log("clFactory", o.clFactory);
    console2.log("nClPools", o.nClPools);
    console2.log("wombat", o.wombat);
    console2.log("fluidFactory", o.fluidFactory);
    console2.log("nFluidPools", o.nFluidPools);
  }

  function _persist(Out memory o, Tokens memory t) internal {
    string memory k = "incumbents";
    vm.serializeUint(k, "chainId", block.chainid);
    vm.serializeAddress(k, "usdc", t.usdc);
    vm.serializeAddress(k, "usdt", t.usdt);
    vm.serializeAddress(k, "usd1", t.usd1);
    vm.serializeAddress(k, "usde", t.usde);
    vm.serializeAddress(k, "fdusd", t.fdusd);
    vm.serializeAddress(k, "curve3pool", o.curve3pool);
    vm.serializeAddress(k, "curveUsdeUsdt", o.curveUsde);
    vm.serializeAddress(k, "curveFdusdUsdc", o.curveFdusd);
    vm.serializeAddress(k, "clFactory", o.clFactory);
    vm.serializeUint(k, "clFeeUltra", FEE_ULTRA);
    vm.serializeUint(k, "clFee1bp", FEE_1BP);
    vm.serializeUint(k, "nClPools", o.nClPools);
    vm.serializeAddress(k, "wombat", o.wombat);
    vm.serializeAddress(k, "fluidFactory", o.fluidFactory);
    string memory json = vm.serializeUint(k, "nFluidPools", o.nFluidPools);

    string memory outPath = vm.envOr(
      "INCUMBENTS_OUT",
      string.concat("deployments/", vm.toString(block.chainid), ".incumbents.json")
    );
    try vm.writeJson(json, outPath) {}
    catch {
      console2.log("(skip) writeJson not permitted");
    }
  }
}
