// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {RecenterHook} from "../../src/incumbents/univ4/RecenterHook.sol";
import {RangeCLPool, RangeCLFactory} from "../../src/incumbents/univ4/RangeCLPool.sol";
import {UniPoolOracle} from "../../src/oracles/UniPoolOracle.sol";
import {TestnetERC20} from "../../src/testnet/TestnetERC20.sol";

/// @title UniPiggybackDeploy — Chapel volatile Uni-range pools + pull oracle.
/// @notice Deploys RecenterHook, RangeCLFactory, 4 volatile pools (BTCB/ETH/WBNB/XAUT vs USDC)
///         with ±10% range liquidity, and UniPoolOracle feeds reading those pools.
/// @dev forge script script/incumbents/UniPiggybackDeploy.s.sol:UniPiggybackDeploy \
///        --sig deployPiggyback --rpc-url chapel --broadcast --with-gas-price 100000000
///      Env: DEPLOYER_PK (or source .env.chapel). Optional SEED_USDC (default 50_000e18).
contract UniPiggybackDeploy is Script {
  using stdJson for string;

  uint24 internal constant FEE = 3000; // 0.3%
  uint256 internal constant RANGE_BPS = 1_000; // ±10%
  uint32 internal constant SIGMA = 50_000; // 5% PBPS — volatile default
  uint16 internal constant CONF = 5;
  uint16 internal constant TTL = 3600;

  // Seed marks (token/USDC) — align with TestnetDeploy volatile seeds
  uint256 internal constant PX_BTCB = 64_300e18;
  uint256 internal constant PX_ETH = 1_795e18;
  uint256 internal constant PX_WBNB = 574e18;
  uint256 internal constant PX_XAUT = 4_090e18;

  struct Tokens {
    address usdc;
    address btcb;
    address eth;
    address wbnb;
    address xaut;
    address ac;
  }

  struct Out {
    address hook;
    address factory;
    address oracle;
    address btcbUsdc;
    address ethUsdc;
    address wbnbUsdc;
    address xautUsdc;
    bytes32 btcbFeed;
    bytes32 ethFeed;
    bytes32 wbnbFeed;
    bytes32 xautFeed;
  }

  function deployPiggyback() external returns (Out memory o) {
    uint256 pk = vm.envUint("DEPLOYER_PK");
    address deployer = vm.addr(pk);
    Tokens memory t = _load();
    uint256 seedUsdc = vm.envOr("SEED_USDC", uint256(50_000 ether));

    vm.startBroadcast(pk);

    RecenterHook hook = new RecenterHook();
    RangeCLFactory factory = new RangeCLFactory(address(hook));
    UniPoolOracle oracle = new UniPoolOracle(t.ac);

    o.hook = address(hook);
    o.factory = address(factory);
    o.oracle = address(oracle);

    o.btcbUsdc = _seedPool(factory, t.btcb, t.usdc, PX_BTCB, seedUsdc, deployer);
    o.ethUsdc = _seedPool(factory, t.eth, t.usdc, PX_ETH, seedUsdc, deployer);
    o.wbnbUsdc = _seedPool(factory, t.wbnb, t.usdc, PX_WBNB, seedUsdc, deployer);
    o.xautUsdc = _seedPool(factory, t.xaut, t.usdc, PX_XAUT, seedUsdc, deployer);

    o.btcbFeed = oracle.addFeed(t.btcb, t.usdc, o.btcbUsdc, SIGMA, CONF, TTL);
    o.ethFeed = oracle.addFeed(t.eth, t.usdc, o.ethUsdc, SIGMA, CONF, TTL);
    o.wbnbFeed = oracle.addFeed(t.wbnb, t.usdc, o.wbnbUsdc, SIGMA, CONF, TTL);
    o.xautFeed = oracle.addFeed(t.xaut, t.usdc, o.xautUsdc, SIGMA, CONF, TTL);

    vm.stopBroadcast();

    _log(o, t);
    _persist(o, t);
  }

  function _seedPool(
    RangeCLFactory factory,
    address base,
    address usdc,
    uint256 basePriceUsdc,
    uint256 seedUsdc,
    address deployer
  ) internal returns (address poolAddr) {
    poolAddr = factory.createPool(base, usdc, FEE);
    RangeCLPool pool = RangeCLPool(poolAddr);

    // price1e18 = token1/token0 in pool order
    address t0 = pool.token0();
    uint256 price1e18 = (t0 == base) ? basePriceUsdc : (1e18 * 1e18) / basePriceUsdc;

    // Size inventory: ~seedUsdc of USDC-leg value on each side.
    uint256 amountUsdc = seedUsdc;
    uint256 amountBase = (seedUsdc * 1e18) / basePriceUsdc;

    TestnetERC20(usdc).mint(deployer, amountUsdc);
    TestnetERC20(base).mint(deployer, amountBase);
    IERC20(usdc).approve(poolAddr, amountUsdc);
    IERC20(base).approve(poolAddr, amountBase);

    uint256 a0 = t0 == base ? amountBase : amountUsdc;
    uint256 a1 = t0 == base ? amountUsdc : amountBase;
    pool.seed(price1e18, RANGE_BPS, a0, a1);
  }

  function _load() internal returns (Tokens memory t) {
    string memory path = vm.envOr(
      "DEPLOY_JSON", string.concat("deployments/", vm.toString(block.chainid), ".deploy.json")
    );
    string memory json = vm.readFile(path);
    t.usdc = json.readAddress(".usdc");
    t.btcb = json.readAddress(".btcb");
    t.eth = json.readAddress(".eth");
    t.wbnb = json.readAddress(".wbnb");
    t.xaut = json.readAddress(".xaut");
    t.ac = json.readAddress(".ac");
  }

  function _log(Out memory o, Tokens memory t) internal pure {
    console2.log("=== Uni piggyback (Chapel) ===");
    console2.log("hook", o.hook);
    console2.log("factory", o.factory);
    console2.log("oracle", o.oracle);
    console2.log("btcb/usdc", o.btcbUsdc);
    console2.log("eth/usdc", o.ethUsdc);
    console2.log("wbnb/usdc", o.wbnbUsdc);
    console2.log("xaut/usdc", o.xautUsdc);
    console2.log("usdc", t.usdc);
  }

  function _persist(Out memory o, Tokens memory t) internal {
    string memory obj = "piggy";
    vm.serializeUint(obj, "chainId", block.chainid);
    vm.serializeAddress(obj, "hook", o.hook);
    vm.serializeAddress(obj, "factory", o.factory);
    vm.serializeAddress(obj, "oracle", o.oracle);
    vm.serializeAddress(obj, "usdc", t.usdc);
    vm.serializeAddress(obj, "btcbUsdc", o.btcbUsdc);
    vm.serializeAddress(obj, "ethUsdc", o.ethUsdc);
    vm.serializeAddress(obj, "wbnbUsdc", o.wbnbUsdc);
    vm.serializeAddress(obj, "xautUsdc", o.xautUsdc);
    vm.serializeBytes32(obj, "btcbFeed", o.btcbFeed);
    vm.serializeBytes32(obj, "ethFeed", o.ethFeed);
    vm.serializeBytes32(obj, "wbnbFeed", o.wbnbFeed);
    string memory out = vm.serializeBytes32(obj, "xautFeed", o.xautFeed);

    string memory path =
      string.concat("deployments/", vm.toString(block.chainid), ".uni-piggyback.json");
    vm.writeJson(out, path);
    console2.log("wrote", path);
  }
}
