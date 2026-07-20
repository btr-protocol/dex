// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {MockERC20} from "../../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../../src/Pool.sol";
import {PoolAux} from "../../src/PoolAux.sol";
import {PoolFactory} from "../../src/PoolFactory.sol";
import {Admin} from "../../src/Admin.sol";
import {Flash} from "../../src/Flash.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {Constants as C} from "../../src/libraries/Constants.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {Err} from "@btr-shared/Errors.sol";
import {BaseTestSetup, MockAC, MockOracle} from "../fixtures/BaseTestSetup.sol";

/// @title InternalOracleTest
/// @notice INTERNAL-mode stableswap: constant peg quote + external gate feed (depeg breaker).
contract InternalOracleTest is BaseTestSetup {
  PoolFactory factory;
  Pool poolImpl;
  Admin admin;
  Flash flashSingleton;
  MockAC ac;
  MockOracle oracle;
  MockOracle refOracle;

  Pool pool;
  MockERC20 base;
  MockERC20 stable;

  address constant OWNER = address(0xA11CE);
  address constant USER = address(0xBEEF);
  bytes32 constant REF_ID = bytes32(uint256(0x571A));

  function _riskStable() internal pure returns (IPool.RiskConfig memory r) {
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20000;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
    r.depthAmplifier = 0;
  }

  function _oracleExt(address token) internal view returns (IPool.OracleConfig memory o) {
    o.primary = address(oracle);
    o.feedId = bytes32(uint256(uint160(token)));
  }

  function _internalOracle() internal view returns (IPool.OracleConfig memory o) {
    o.primary = address(oracle);
    o.feedId = bytes32(uint256(uint160(address(stable))));
    o.refFeedId = REF_ID;
    o.refBandBps = C.MAX_STABLE_DEPEG_BAND_BPS;
    o.refPrimary = address(refOracle);
    o.mode = C.ORACLE_MODE_INTERNAL;
  }

  function setUp() public override {
    ac = new MockAC(OWNER);
    admin = new Admin(address(ac));
    flashSingleton = new Flash();
    PoolAux poolAux = new PoolAux(address(ac), address(admin), address(flashSingleton));
    poolImpl = new Pool(address(ac), address(admin), address(flashSingleton), address(poolAux));
    factory = new PoolFactory(address(poolImpl), address(this), address(ac));

    base = new MockERC20("Base", "BASE", 18);
    stable = new MockERC20("Stable", "STBL", 18);

    address[] memory toks = new address[](2);
    toks[0] = address(base);
    toks[1] = address(stable);
    IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 25, flashFeePbps: 100});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
    pool = Pool(payable(factory.createPool(address(base), toks, initdata)));

    oracle = new MockOracle();
    refOracle = new MockOracle();
    oracle.setMark(address(base), M.encodeB64(1e18, 18));
    oracle.setFeed(
      bytes32(uint256(uint160(address(stable)))), M.encodeB64(1e18, 18), C.STABLE_SIGMA_PBPS, 0, 3600
    );
    refOracle.setFeed(REF_ID, M.encodeB64(1e18, 18), C.STABLE_SIGMA_PBPS, 0, 3600);

    vm.startPrank(OWNER);
    admin.setCurve(address(pool), DEFAULT_PRESET, defaultCurveInterior(), defaultCurveWQ(), 1000, 0);
    admin.addAsset(
      address(pool),
      address(base),
      _oracleExt(address(base)),
      _riskStable(),
      DEFAULT_PRESET,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    admin.addAsset(
      address(pool),
      address(stable),
      _internalOracle(),
      _riskStable(),
      DEFAULT_PRESET,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    vm.stopPrank();

    base.mint(address(this), 1_000_000e18);
    stable.mint(address(this), 1_000_000e18);
    base.approve(address(pool), type(uint256).max);
    stable.approve(address(pool), type(uint256).max);
    pool.deposit(address(base), 500_000e18);
    pool.deposit(address(stable), 500_000e18);
  }

  function test_walk_off_peg_quotes_constant_peg() public {
    oracle.setFeed(
      bytes32(uint256(uint160(address(stable)))), M.encodeB64(995e15, 18), C.STABLE_SIGMA_PBPS, 0, 3600
    );
    refOracle.setFeed(REF_ID, M.encodeB64(1e18, 18), C.STABLE_SIGMA_PBPS, 0, 3600);

    uint256 amtIn = 10_000e18;
    IPool.SwapQuote memory q = pool.getSwapQuote(address(base), address(stable), amtIn);
    assertGt(q.amountOut, amtIn * 995e15 / 1e18, "must quote off peg not external gate mark");
    assertApproxEqRel(q.amountOut, amtIn, 0.02e18, "peg quote ~1:1 before fees");
  }

  function test_band_halt_when_gate_depegs() public {
    oracle.setFeed(
      bytes32(uint256(uint160(address(stable)))), M.encodeB64(101e16, 18), C.STABLE_SIGMA_PBPS, 0, 3600
    );

    base.mint(USER, 1000e18);
    vm.startPrank(USER);
    base.approve(address(pool), type(uint256).max);
    vm.expectRevert();
    pool.swap(address(base), address(stable), 500e18, 0, USER);
    vm.stopPrank();
  }

  function test_stale_gate_revert_on_exec() public {
    vm.warp(block.timestamp + 4000);

    base.mint(USER, 1000e18);
    vm.startPrank(USER);
    base.approve(address(pool), type(uint256).max);
    IPool.SwapQuote memory q = pool.getSwapQuote(address(base), address(stable), 500e18);
    assertGt(q.amountOut, 0, "quote off synthetic peg");
    vm.expectPartialRevert(Err.StaleData.selector);
    pool.swap(address(base), address(stable), 500e18, 0, USER);
    vm.stopPrank();
  }

  function test_round_trip_fees_only() public {
    uint256 amt = 50_000e18;
    base.mint(USER, amt);
    vm.startPrank(USER);
    base.approve(address(pool), type(uint256).max);
    stable.approve(address(pool), type(uint256).max);

    uint256 baseBefore = base.balanceOf(USER);
    uint256 outStable = pool.swap(address(base), address(stable), amt, 0, USER);
    uint256 outBase = pool.swap(address(stable), address(base), outStable, 0, USER);
    uint256 baseAfter = base.balanceOf(USER);

    assertLt(outBase, baseBefore, "round trip must not mint base");
    uint256 loss = baseBefore - outBase;
    assertGt(loss, 0, "fees/slippage consume value");
    assertLt(loss, amt / 20, "loss bounded - no free extraction beyond fees");
    vm.stopPrank();
  }
}
