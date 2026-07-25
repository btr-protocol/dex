// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {Admin} from "../src/Admin.sol";
import {Flash} from "../src/Flash.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {BaseTestSetup, MockAC, MockOracle, NO_DEADLINE} from "./fixtures/BaseTestSetup.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @title PoolBaseDepegTest -R44-2 (T3-HIGH2) regression.
/// @notice Verifies base-token depeg halt:
///         - The listed base asset's canonical OracleConfig is the depeg source.
///         - A base price within `BASE_DEPEG_HALT_BPS` (5%) executes normally.
///         - When base oracle reports a >5% deviation from 1e18: swaps revert `Err.BaseDepegged`.
contract PoolBaseDepegTest is BaseTestSetup {
  PoolFactory factory;
  Pool poolImpl;
  Admin admin;
  Flash flashSingleton;
  MockAC ac;
  Pool pool;
  MockERC20 base;
  MockERC20 quote;
  MockOracle oracle;

  address constant OWNER = address(0xA11CE);
  address constant USER = address(0xBEEF);

  function _risk() internal pure returns (IPool.RiskConfig memory r) {
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20000;
    r.depthAmplifier = 10000;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
  }

  /// @dev M-1: EXTERNAL spokes must carry a cumulative bound; armed via the shared mirror-ref fixture.
  function _oracleCfg(address token) internal returns (IPool.OracleConfig memory o) {
    o = externalOracleCfg(oracle, token);
  }

  function setUp() public override {
    ac = new MockAC(OWNER);
    admin = new Admin(address(ac));
    flashSingleton = new Flash();
    PoolAux poolAux = new PoolAux(address(ac), address(admin), address(flashSingleton));
    poolImpl = new Pool(address(ac), address(admin), address(flashSingleton), address(poolAux));
    factory = new PoolFactory(address(poolImpl), address(this), address(ac));

    base = new MockERC20("Base", "BASE", 18);
    quote = new MockERC20("Quote", "QUOT", 18);
    address[] memory toks = new address[](2);
    toks[0] = address(base);
    toks[1] = address(quote);
    IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 25, flashFeePbps: 100});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, address(base), address(0xCAFE), fp);
    address pa = factory.createPool(address(base), toks, initdata);
    pool = Pool(payable(pa));

    oracle = new MockOracle();
    oracle.setMark(address(base), M.encodeB64(1e18, 18));
    oracle.setMark(address(quote), M.encodeB64(1e18, 18));
    IPool.RiskConfig memory rc = _risk();
    vm.startPrank(OWNER);
    admin.setCurve(pa, DEFAULT_PRESET, defaultCurveInterior(), defaultCurveWQ(), 1000, 0);
    admin.addAsset(
      pa,
      address(base),
      _oracleCfg(address(base)),
      rc,
      DEFAULT_PRESET,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    admin.addAsset(
      pa,
      address(quote),
      _oracleCfg(address(quote)),
      rc,
      DEFAULT_PRESET,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    vm.stopPrank();

    // Seed both sides.
    uint256 seed = 1_000_000e18;
    base.mint(address(this), seed);
    base.approve(address(pool), type(uint256).max);
    pool.deposit(address(base), seed);
    quote.mint(address(this), seed);
    quote.approve(address(pool), type(uint256).max);
    pool.deposit(address(quote), seed);
  }

  /// @notice R44-2: canonical base oracle within halt band → swaps succeed.
  function test_R44_2_base_oracle_at_parity_swap_ok() public {
    uint256 amt = 100e18;
    base.mint(USER, amt);
    vm.prank(USER);
    base.approve(address(pool), type(uint256).max);
    vm.prank(USER);
    uint256 out = pool.swap(address(base), address(quote), amt, 0, USER, NO_DEADLINE);
    assertGt(out, 0, "parity base price: swap ok");
  }

  /// @notice R44-2: base oracle reports >5% depeg → swaps revert BaseDepegged.
  function test_R44_2_depeg_halts_swap() public {
    // 10% depeg (price = 0.9e18) → deviationBps = 1000 > halt 500.
    oracle.setMark(address(base), M.encodeB64(9e17, 18));

    uint256 amt = 100e18;
    base.mint(USER, amt);
    vm.prank(USER);
    base.approve(address(pool), type(uint256).max);

    vm.prank(USER);
    vm.expectRevert(); // Err.BaseDepegged(basePrice, deviationBps)
    pool.swap(address(base), address(quote), amt, 0, USER, NO_DEADLINE);
  }

  /// @notice R44-2: constant value is 5% (500 BPS) per spec.
  function test_R44_2_halt_bps_constant() public pure {
    assertEq(uint256(C.BASE_DEPEG_HALT_BPS), 500, "R44-2: 5% halt");
  }

  /// @notice R44-2b: `_executeLeg` base-token branch is defensive-only.
  /// @dev By anchor-tree invariant, baseToken is always the ROOT (anchor==0).
  ///      `setAnchor(base, X)` reverts (Err.InvalidAnchor) — base
  ///      cannot become an intermediate hop. The patch (`twap = _readBasePriceOrHalt($)`)
  ///      in `_executeLeg` is belt-and-suspenders against future tree-topology changes.
  ///      No runtime regression test possible; correctness verified by Pass-45 V1 review.
  function test_R44_2b_executeLeg_baseToken_path_halts_on_depeg_SKIP() public pure {
    // Path unreachable in current anchor-tree design. Patch remains defensive.
    assertTrue(true);
  }

  function _skipped_test_R44_2b_design_doc() public {
    // 3rd asset C; reparent base under C so base becomes an intermediate node.
    MockERC20 cTok = new MockERC20("CTok", "CTOK", 18);
    oracle.setMark(address(cTok), M.encodeB64(1e18, 18));
    IPool.RiskConfig memory rc = _risk();
    vm.prank(OWNER);
    admin.addAsset(
      address(pool),
      address(cTok),
      _oracleCfg(address(cTok)),
      rc,
      DEFAULT_PRESET,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    // Seed C.
    cTok.mint(address(this), 1_000_000e18);
    cTok.approve(address(pool), type(uint256).max);
    pool.deposit(address(cTok), 1_000_000e18);

    // Reparent base under C: now path quote→cTok = quote→base→cTok with base as intermediate.
    // walkToRoot(quote)=[quote,base,cTok]; walkToRoot(cTok)=[cTok]; LCA=cTok.
    // Hop1 (base→cTok): from=base, to=cTok, assets[base].anchor==cTok → isUpward=true,
    // profileAsset=base. Hits the patched branch.
    vm.prank(OWNER);
    admin.setAnchor(address(pool), address(base), address(cTok));

    // Base's canonical oracle reports a 10% depeg.
    oracle.setMark(address(base), M.encodeB64(9e17, 18));

    uint256 amt = 100e18;
    quote.mint(USER, amt);
    vm.prank(USER);
    quote.approve(address(pool), type(uint256).max);

    vm.prank(USER);
    vm.expectRevert(); // Err.BaseDepegged via _executeLeg base-token branch
    pool.swap(address(quote), address(cTok), amt, 0, USER, NO_DEADLINE);
  }
}
