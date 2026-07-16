// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {CurveStableSwap} from "../../src/incumbents/curve/CurveStableSwap.sol";
import {UniswapV2Factory} from "../../src/incumbents/univ2/vendor/UniswapV2Factory.sol";
import {UniswapV2Pair} from "../../src/incumbents/univ2/vendor/UniswapV2Pair.sol";
import {RangeCLFactory, RangeCLPool} from "../../src/incumbents/univ4/RangeCLPool.sol";
import {TestnetERC20} from "../../src/testnet/TestnetERC20.sol";
import {TestnetFaucet} from "../../src/testnet/TestnetFaucet.sol";

/// @title ChapelCoverageDeploy — fill volatile coverage gaps on Chapel (97).
/// @notice Deploys: (1) Curve NG tricrypto-style pools, (2) UniV2 volatile pairs,
///         (3) RangeCL BTCB/USDC reseed at fee=3010 with literal 10k/side,
///         (4) funds XAUT on existing faucet.
/// @dev forge script script/incumbents/ChapelCoverageDeploy.s.sol:ChapelCoverageDeploy \
///        --sig runCoverage --rpc-url chapel --broadcast --with-gas-price 100000000
contract ChapelCoverageDeploy is Script {
  using stdJson for string;

  uint256 internal constant SEED = 10_000 ether;
  // Curve NG fee denom 1e10 → 3e7 = 30 bps (volatile tricrypto-ish)
  uint256 internal constant CURVE_FEE_30BP = 3e7;
  uint256 internal constant CURVE_A_VOL = 100; // lower A than fiat stables
  uint24 internal constant RANGE_FEE_BTCB = 3010; // new tier (3000 already seeded lean)
  uint256 internal constant RANGE_BPS = 1_000;
  uint256 internal constant PX_BTCB = 64_300e18;

  struct Tokens {
    address usdc;
    address usdt;
    address btcb;
    address eth;
    address wbnb;
    address xaut;
    address faucet;
    address uniV2Factory;
    address rangeFactory;
  }

  struct Out {
    address curveUsdtBnbBtcb;
    address curveUsdcEthBtcb;
    address uniBtcbUsdc;
    address uniEthUsdc;
    address uniWbnbUsdc;
    address uniXautUsdc;
    address uniBtcbUsdt;
    address uniEthUsdt;
    address uniWbnbUsdt;
    address uniXautUsdt;
    address rangeBtcbUsdc;
  }

  function runCoverage() external returns (Out memory o) {
    uint256 pk = vm.envUint("DEPLOYER_PK");
    address deployer = vm.addr(pk);
    Tokens memory t = _load();

    vm.startBroadcast(pk);

    // Mint inventory for seeds + faucet top-up
    address[6] memory mintToks = [t.usdc, t.usdt, t.btcb, t.eth, t.wbnb, t.xaut];
    for (uint256 i; i < 6; i++) {
      TestnetERC20(mintToks[i]).mint(deployer, SEED * 40);
    }

    // ── Curve tricrypto-style (StableSwap NG math, 3 coins) ──────────────
    {
      address[] memory c1 = new address[](3);
      c1[0] = t.usdt;
      c1[1] = t.wbnb;
      c1[2] = t.btcb;
      o.curveUsdtBnbBtcb = _deployCurve3(c1, deployer);
    }
    {
      address[] memory c2 = new address[](3);
      c2[0] = t.usdc;
      c2[1] = t.eth;
      c2[2] = t.btcb;
      o.curveUsdcEthBtcb = _deployCurve3(c2, deployer);
    }

    // ── UniV2 volatile pairs (10k/side) ──────────────────────────────────
    UniswapV2Factory fac = UniswapV2Factory(t.uniV2Factory);
    o.uniBtcbUsdc = _seedUniV2(fac, t.btcb, t.usdc, deployer);
    o.uniEthUsdc = _seedUniV2(fac, t.eth, t.usdc, deployer);
    o.uniWbnbUsdc = _seedUniV2(fac, t.wbnb, t.usdc, deployer);
    o.uniXautUsdc = _seedUniV2(fac, t.xaut, t.usdc, deployer);
    o.uniBtcbUsdt = _seedUniV2(fac, t.btcb, t.usdt, deployer);
    o.uniEthUsdt = _seedUniV2(fac, t.eth, t.usdt, deployer);
    o.uniWbnbUsdt = _seedUniV2(fac, t.wbnb, t.usdt, deployer);
    o.uniXautUsdt = _seedUniV2(fac, t.xaut, t.usdt, deployer);

    // ── RangeCL BTCB/USDC reseed at new fee (literal 10k each) ───────────
    RangeCLFactory rf = RangeCLFactory(t.rangeFactory);
    o.rangeBtcbUsdc = rf.createPool(t.btcb, t.usdc, RANGE_FEE_BTCB);
    {
      RangeCLPool pool = RangeCLPool(o.rangeBtcbUsdc);
      address t0 = pool.token0();
      uint256 price1e18 = (t0 == t.btcb) ? PX_BTCB : (1e18 * 1e18) / PX_BTCB;
      // Desire 10k of each; CL mint consumes ratio — transfer full 10k then seed
      // with 10k/10k so unused stays with caller; then donate remainder into pool
      // via direct transfer + tiny no-op is unavailable. Instead seed with amounts
      // sized so BOTH sides pull ≥10k at the active range (±10%).
      // At mid, L is limited by the scarcer USD-leg. Force inventory by seeding
      // with max(10k, 10k*price) on USDC leg and 10k on BTCB.
      uint256 amtBtcb = SEED;
      uint256 amtUsdc = SEED; // literal 10k ether units per side (audit rule)
      IERC20(t.btcb).approve(o.rangeBtcbUsdc, amtBtcb);
      IERC20(t.usdc).approve(o.rangeBtcbUsdc, amtUsdc);
      uint256 a0 = t0 == t.btcb ? amtBtcb : amtUsdc;
      uint256 a1 = t0 == t.btcb ? amtUsdc : amtBtcb;
      pool.seed(price1e18, RANGE_BPS, a0, a1);
      // Top up any shortfall so ERC20 balances ≥10k (idle inventory for recenter)
      _ensureBal(t.btcb, o.rangeBtcbUsdc, SEED, deployer);
      _ensureBal(t.usdc, o.rangeBtcbUsdc, SEED, deployer);
    }

    // ── XAUT faucet fund ────────────────────────────────────────────────
    TestnetFaucet faucet = TestnetFaucet(t.faucet);
    uint256 xautCap = 1 ether; // ~$4k/day illustrative
    faucet.setCap(t.xaut, xautCap);
    uint256 xautFund = 1_000 ether;
    IERC20(t.xaut).approve(t.faucet, xautFund);
    faucet.fund(t.xaut, xautFund);

    vm.stopBroadcast();

    _log(o);
    _persist(o, t);
  }

  function _deployCurve3(
    address[] memory coins,
    address /*deployer*/
  )
    internal
    returns (address pool)
  {
    CurveStableSwap p = new CurveStableSwap(coins, CURVE_A_VOL, CURVE_FEE_30BP);
    pool = address(p);
    uint256[] memory amts = new uint256[](3);
    amts[0] = SEED;
    amts[1] = SEED;
    amts[2] = SEED;
    for (uint256 i; i < 3; i++) {
      IERC20(coins[i]).approve(pool, SEED);
    }
    p.add_liquidity(amts, 0);
  }

  function _seedUniV2(UniswapV2Factory fac, address a, address b, address to)
    internal
    returns (address pair)
  {
    pair = fac.getPair(a, b);
    if (pair == address(0)) {
      pair = fac.createPair(a, b);
    }
    // Top up to ≥SEED each side via mint
    (uint112 r0, uint112 r1,) = UniswapV2Pair(pair).getReserves();
    address t0 = UniswapV2Pair(pair).token0();
    address t1 = UniswapV2Pair(pair).token1();
    uint256 need0 = r0 >= SEED ? 0 : SEED - uint256(r0);
    uint256 need1 = r1 >= SEED ? 0 : SEED - uint256(r1);
    if (need0 == 0 && need1 == 0) return pair;
    // First mint needs both sides; subsequent proportional. For empty pair send SEED/SEED.
    if (r0 == 0 && r1 == 0) {
      need0 = SEED;
      need1 = SEED;
    } else if (need0 > 0 && need1 == 0) {
      // keep ratio: need1 ≈ need0 * r1/r0
      need1 = (need0 * uint256(r1)) / uint256(r0);
      if (need1 == 0) need1 = 1;
    } else if (need1 > 0 && need0 == 0) {
      need0 = (need1 * uint256(r0)) / uint256(r1);
      if (need0 == 0) need0 = 1;
    }
    // Ensure post-mint balances ≥ SEED by overshooting if needed
    uint256 send0 = need0;
    uint256 send1 = need1;
    if (uint256(r0) + send0 < SEED) send0 = SEED - uint256(r0);
    if (uint256(r1) + send1 < SEED) send1 = SEED - uint256(r1);
    IERC20(t0).transfer(pair, send0);
    IERC20(t1).transfer(pair, send1);
    UniswapV2Pair(pair).mint(to);
  }

  function _ensureBal(address token, address pool, uint256 minBal, address from) internal {
    uint256 bal = IERC20(token).balanceOf(pool);
    if (bal >= minBal) return;
    uint256 gap = minBal - bal;
    IERC20(token).transfer(pool, gap);
  }

  function _load() internal returns (Tokens memory t) {
    string memory path = vm.envOr(
      "DEPLOY_JSON", string.concat("deployments/", vm.toString(block.chainid), ".deploy.json")
    );
    string memory json = vm.readFile(path);
    t.usdc = json.readAddress(".usdc");
    t.usdt = json.readAddress(".usdt");
    t.btcb = json.readAddress(".btcb");
    t.eth = json.readAddress(".eth");
    t.wbnb = json.readAddress(".wbnb");
    t.xaut = json.readAddress(".xaut");
    t.faucet = json.readAddress(".faucet");

    t.uniV2Factory = vm.envOr("UNIV2_FACTORY", address(0xD2F5488f1930Df661eceCbD4B122Ef767B6C92D4));
    string memory pigPath =
      string.concat("deployments/", vm.toString(block.chainid), ".uni-piggyback.json");
    string memory pig = vm.readFile(pigPath);
    t.rangeFactory = pig.readAddress(".factory");
  }

  function _log(Out memory o) internal pure {
    console2.log("=== Chapel coverage ===");
    console2.log("curveUsdtBnbBtcb", o.curveUsdtBnbBtcb);
    console2.log("curveUsdcEthBtcb", o.curveUsdcEthBtcb);
    console2.log("uniBtcbUsdc", o.uniBtcbUsdc);
    console2.log("uniEthUsdc", o.uniEthUsdc);
    console2.log("uniWbnbUsdc", o.uniWbnbUsdc);
    console2.log("uniXautUsdc", o.uniXautUsdc);
    console2.log("rangeBtcbUsdc", o.rangeBtcbUsdc);
  }

  function _persist(Out memory o, Tokens memory t) internal {
    string memory k = "cov";
    vm.serializeUint(k, "chainId", block.chainid);
    vm.serializeAddress(k, "curveUsdtBnbBtcb", o.curveUsdtBnbBtcb);
    vm.serializeAddress(k, "curveUsdcEthBtcb", o.curveUsdcEthBtcb);
    vm.serializeAddress(k, "uniBtcbUsdc", o.uniBtcbUsdc);
    vm.serializeAddress(k, "uniEthUsdc", o.uniEthUsdc);
    vm.serializeAddress(k, "uniWbnbUsdc", o.uniWbnbUsdc);
    vm.serializeAddress(k, "uniXautUsdc", o.uniXautUsdc);
    vm.serializeAddress(k, "uniBtcbUsdt", o.uniBtcbUsdt);
    vm.serializeAddress(k, "uniEthUsdt", o.uniEthUsdt);
    vm.serializeAddress(k, "uniWbnbUsdt", o.uniWbnbUsdt);
    vm.serializeAddress(k, "uniXautUsdt", o.uniXautUsdt);
    vm.serializeAddress(k, "rangeBtcbUsdc", o.rangeBtcbUsdc);
    vm.serializeAddress(k, "uniV2Factory", t.uniV2Factory);
    string memory out = vm.serializeAddress(k, "usdc", t.usdc);
    string memory path = string.concat("deployments/", vm.toString(block.chainid), ".coverage.json");
    vm.writeJson(out, path);
    console2.log("wrote", path);
  }
}
