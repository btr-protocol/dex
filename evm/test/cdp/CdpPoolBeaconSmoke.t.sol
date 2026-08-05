// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {MockERC20} from "../../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../../src/Pool.sol";
import {PoolAux} from "../../src/PoolAux.sol";
import {PoolFactory} from "../../src/PoolFactory.sol";
import {Admin} from "../../src/Admin.sol";
import {Flash} from "../../src/Flash.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {ICdp} from "../../src/interfaces/ICdp.sol";
import {Constants as C} from "../../src/libraries/Constants.sol";
import {CdpValuation} from "../../src/libraries/CdpValuation.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {CDPEngine} from "../../src/CDPEngine.sol";
import {DebtToken} from "../../src/DebtToken.sol";
import {DebtTokenFactory} from "./mocks/DebtTokenFactory.sol";
import {BaseTestSetup, MockAC, MockOracle} from "../fixtures/BaseTestSetup.sol";
import {CdpTestBase} from "./CdpTestBase.sol";

interface IERC20Approve {
  function approve(address spender, uint256 amount) external returns (bool);
}

contract CdpPoolBeaconSmokeTest is CdpTestBase, BaseTestSetup {
  address constant OWNER = address(0xA11CE);
  address constant USER = address(0xBEEF);

  MockAC ac;
  Admin admin;
  PoolFactory factory;
  Pool pool;
  MockOracle oracle;
  MockERC20 base;
  CollateralRegistry registry;
  CDPEngine engine;
  DebtToken btrUSD;

  function _defaultRisk() internal pure returns (IPool.RiskConfig memory r) {
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20000;
    r.decaySlope = 0;
    r.depthAmplifier = 10000;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
  }

  function _oracleCfg(address token) internal returns (IPool.OracleConfig memory o) {
    o = externalOracleCfg(oracle, token);
  }

  function setUp() public override {
    BaseTestSetup.setUp();
    ac = new MockAC(OWNER);
    admin = new Admin(address(ac));
    Flash flashSingleton = new Flash();
    PoolAux poolAux = new PoolAux(address(ac), address(admin), address(flashSingleton));
    Pool poolImpl = new Pool(address(ac), address(admin), address(flashSingleton), address(poolAux));
    factory = new PoolFactory(address(poolImpl), address(this), address(ac));

    base = new MockERC20("USD", "USD", 18);
    address[] memory toks = new address[](1);
    toks[0] = address(base);
    IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 25, flashFeePbps: 100});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0), fp);
    pool = Pool(payable(factory.createPool(address(base), toks, initdata)));

    oracle = new MockOracle();
    oracle.setMark(address(base), M.encodeB64(1e18, 18));

    vm.startPrank(OWNER);
    admin.setCurve(address(pool), DEFAULT_PRESET, defaultCurveInterior(), defaultCurveWQ(), 1000, 0);
    admin.addAsset(
      address(pool),
      address(base),
      _oracleCfg(address(base)),
      _defaultRisk(),
      DEFAULT_PRESET,
      1000,
      18,
      1000,
      100_000,
      10_000,
      10_000
    );
    vm.stopPrank();

    registry = new CollateralRegistry(address(ac));
    engine = new CDPEngine(address(ac), address(registry));
    (address usd,,,) = (new DebtTokenFactory()).deploySuite(address(engine));
    btrUSD = DebtToken(usd);
    _zeroHaircuts(engine, OWNER);
    _listUsd(
      registry, OWNER, pool.lpToken(address(base)), address(pool), address(base), address(btrUSD), 1e27
    );
  }

  function test_deposit_list_open_smoke() public {
    uint256 amt = 1_000e18;
    base.mint(USER, amt);
    vm.startPrank(USER);
    base.approve(address(pool), type(uint256).max);
    pool.deposit(address(base), amt);
    vm.stopPrank();

    address lp = pool.lpToken(address(base));
    uint256 shares = pool.getLPBalance(USER, address(base));
    assertGt(shares, 0, "LP minted");
    assertLt(shares, amt);
    assertEq(pool.maxRedeem(USER, address(base)), 0, "frozen during cooldown");
    vm.warp(block.timestamp + uint256(pool.flowCooldownSeconds()) + 1);
    assertEq(pool.maxRedeem(USER, address(base)), shares, "unlocked after cooldown");
    oracle.setMark(address(base), M.encodeB64(1e18, 18));

    (uint256 R,) = pool.previewWithdrawFresh(address(base), shares);
    assertGt(R, 0);
    ICdp.ValueParams memory vp = engine.valueParams(lp);
    assertEq(vp.basisWad, 1e18, "EXTERNAL mark at 1.0");
    uint256 V = CdpValuation.collateralValue(address(pool), address(base), shares, vp);
    uint256 maxDebt = CdpValuation.maxDebt(V, 8500);
    assertGt(maxDebt, 0);

    vm.startPrank(USER);
    IERC20Approve(lp).approve(address(engine), type(uint256).max);
    engine.open(lp, shares, maxDebt);
    vm.stopPrank();

    (uint128 coll, uint128 debt) = engine.positions(USER, lp);
    assertEq(coll, shares);
    assertEq(debt, maxDebt);
    assertEq(btrUSD.balanceOf(USER), maxDebt);
    assertEq(pool.getLPBalance(address(engine), address(base)), shares, "engine custody");
  }

  function test_open_duringCooldown_capacityShort() public {
    uint256 amt = 500e18;
    base.mint(USER, amt);
    vm.startPrank(USER);
    base.approve(address(pool), type(uint256).max);
    pool.deposit(address(base), amt);
    address lp = pool.lpToken(address(base));
    uint256 shares = pool.getLPBalance(USER, address(base));
    IERC20Approve(lp).approve(address(engine), type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(ICdp.CapacityShortfall.selector, lp));
    engine.open(lp, shares, 1e18);
    vm.stopPrank();
  }
}
