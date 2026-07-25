// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../.deps/solady/test/utils/mocks/MockERC20.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAux} from "../src/PoolAux.sol";
import {PoolFactory} from "../src/PoolFactory.sol";
import {Admin} from "../src/Admin.sol";
import {Flash} from "../src/Flash.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {ERC4626YieldHook} from "../src/hooks/ERC4626YieldHook.sol";
import {Constants as C} from "../src/libraries/Constants.sol";
import {IAdmin} from "../src/interfaces/IAdmin.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {BaseTestSetup, MockAC, MockOracle, NO_DEADLINE} from "./fixtures/BaseTestSetup.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Err} from "@btr-shared/Errors.sol";

contract ERC4626YieldHookHarness is ERC4626YieldHook {
  constructor(address ac_, address pool_, address token_, address vault_)
    ERC4626YieldHook(ac_, pool_, token_, vault_)
  {}

  function exposedVenueDeposit(uint256 assets) external {
    _venueDeposit(assets);
  }
}

/// @dev ERC4626-shaped adversary with independently selectable actual, reported and valued shares.
contract AdversarialERC4626 {
  enum Mode {
    ZeroShares,
    DishonestReturn,
    TwoBpsLoss
  }

  address public immutable asset;
  Mode public immutable mode;
  mapping(address => uint256) public balanceOf;

  constructor(address asset_, Mode mode_) {
    asset = asset_;
    mode = mode_;
  }

  function deposit(uint256 assets, address receiver) external returns (uint256 reportedShares) {
    MockERC20(asset).transferFrom(msg.sender, address(this), assets);
    if (mode == Mode.ZeroShares) return 0;
    balanceOf[receiver] += assets;
    if (mode == Mode.DishonestReturn) return assets + 1;
    return assets;
  }

  function convertToAssets(uint256 shares) external view returns (uint256) {
    if (mode == Mode.TwoBpsLoss) return (shares * 9_998) / 10_000;
    return shares;
  }

  function withdraw(uint256, address, address) external pure returns (uint256) {
    revert("unused");
  }

  function maxWithdraw(address) external pure returns (uint256) {
    return 0;
  }
}

/// @notice Regression coverage for ERC4626 adapters that consume assets but lie or round away shares.
contract ERC4626DepositValidationRegressionTest is Test {
  MockERC20 internal token;
  MockAC internal ac;

  function setUp() public {
    token = new MockERC20("Asset", "AST", 18);
    ac = new MockAC(address(this));
  }

  function _harness(AdversarialERC4626.Mode mode) internal returns (ERC4626YieldHookHarness hook) {
    AdversarialERC4626 vault = new AdversarialERC4626(address(token), mode);
    hook = new ERC4626YieldHookHarness(address(ac), address(1), address(token), address(vault));
    token.mint(address(hook), 10_000e18);
  }

  function test_erc4626_rejects_zero_actual_shares() public {
    ERC4626YieldHookHarness hook = _harness(AdversarialERC4626.Mode.ZeroShares);
    vm.expectRevert(Err.ZeroValue.selector);
    hook.exposedVenueDeposit(10_000e18);
    assertEq(token.balanceOf(address(hook)), 10_000e18, "revert restores consumed assets");
  }

  function test_erc4626_rejects_reported_share_lie() public {
    ERC4626YieldHookHarness hook = _harness(AdversarialERC4626.Mode.DishonestReturn);
    vm.expectRevert(Err.BadConfig.selector);
    hook.exposedVenueDeposit(10_000e18);
    assertEq(token.balanceOf(address(hook)), 10_000e18, "revert restores consumed assets");
  }

  function test_erc4626_rejects_value_loss_above_one_bp() public {
    ERC4626YieldHookHarness hook = _harness(AdversarialERC4626.Mode.TwoBpsLoss);
    vm.expectRevert(abi.encodeWithSelector(Err.ThresholdViolation.selector, 9_998e18, 9_999e18));
    hook.exposedVenueDeposit(10_000e18);
    assertEq(token.balanceOf(address(hook)), 10_000e18, "revert restores consumed assets");
  }
}

/// @notice Regression for a permissionless token-index saturation attack against official discovery.
contract PoolFactoryRegistrySaturationRegressionTest is Test {
  PoolFactory internal factory;
  MockERC20 internal commonToken;

  function setUp() public {
    MockAC ac = new MockAC(address(this));
    Admin admin = new Admin(address(ac));
    Flash flash = new Flash();
    PoolAux aux = new PoolAux(address(ac), address(admin), address(flash));
    Pool implementation = new Pool(address(ac), address(admin), address(flash), address(aux));
    factory = new PoolFactory(address(implementation), address(this), address(ac));
    commonToken = new MockERC20("Common", "COM", 18);
  }

  function _createAs(address creator, address other) internal returns (address pool) {
    address[] memory tokens = new address[](2);
    tokens[0] = address(commonToken);
    tokens[1] = other;
    IPool.FeeParams memory fees = IPool.FeeParams({protoShare: 25, flashFeePbps: 100});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, address(commonToken), address(0xCAFE), fees);
    vm.prank(creator);
    pool = factory.createPool(address(commonToken), tokens, initdata);
  }

  function test_official_registration_bypasses_saturated_untrusted_index() public {
    uint256 cap = factory.MAX_TOKEN_POOLS();
    for (uint256 i; i < cap; ++i) {
      _createAs(address(uint160(0x1000 + i)), address(uint160(0x10_000 + i)));
    }
    assertEq(factory.getPoolsForToken(address(commonToken)).length, cap, "untrusted cap reached");
    assertEq(factory.getOfficialPoolsForToken(address(commonToken)).length, 0);

    address officialOther = address(0xB0B);
    address official = _createAs(address(this), officialOther);

    assertTrue(factory.isOfficialPool(official));
    assertEq(
      factory.getPoolsForToken(address(commonToken)).length, cap + 1, "official bypasses cap"
    );
    address[] memory officialForToken = factory.getOfficialPoolsForToken(address(commonToken));
    assertEq(officialForToken.length, 1);
    assertEq(officialForToken[0], official);
    address[] memory route = factory.getCommonPools(address(commonToken), officialOther);
    assertEq(route.length, 1, "official route remains discoverable");
    assertEq(route[0], official);
  }
}

/// @notice REG (unaudited surface, challenge pass 2026-07-16): getCommonPools fill-loop must
///         increment the write index ONLY on a match. The prior code bumped it every iteration, so
///         when a non-common pool preceded a common one in tokenA's official array, the match wrote
///         past the `count`-sized result array → OOB revert = permanent route-discovery DoS for that
///         pair, reachable by permissionless createPool ordering.
contract PoolFactoryCommonRouteRegressionTest is Test {
  PoolFactory internal factory;

  function setUp() public {
    MockAC ac = new MockAC(address(this));
    Admin admin = new Admin(address(ac));
    Flash flash = new Flash();
    PoolAux aux = new PoolAux(address(ac), address(admin), address(flash));
    Pool implementation = new Pool(address(ac), address(admin), address(flash), address(aux));
    factory = new PoolFactory(address(implementation), address(this), address(ac));
  }

  // Official pool with base `base` listing [base, other]; address(this) == protocolDeployer ⇒ official.
  function _official(address base, address other) internal returns (address pool) {
    address[] memory tokens = new address[](2);
    tokens[0] = base;
    tokens[1] = other;
    IPool.FeeParams memory fees = IPool.FeeParams({protoShare: 25, flashFeePbps: 100});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, base, address(0xCAFE), fees);
    pool = factory.createPool(base, tokens, initdata);
  }

  function test_common_route_with_noncommon_pool_first_no_oob() public {
    address a = address(new MockERC20("A", "A", 18));
    address b = address(new MockERC20("B", "B", 18));
    address x = address(new MockERC20("X", "X", 18));
    address y = address(new MockERC20("Y", "Y", 18));

    // A's official array in creation order = [pAX (NOT common with B), pAB (common with B)].
    address pAX = _official(a, x);
    address pAB = _official(a, b);
    // Give B a second pool so neither array is shorter ⇒ no swap ⇒ A stays the iterated array.
    _official(b, y);

    // Pre-fix: writes pAB at index 1 in a length-1 array → OOB revert. Post-fix: returns [pAB].
    address[] memory route = factory.getCommonPools(a, b);
    assertEq(route.length, 1, "exactly one common pool");
    assertEq(route[0], pAB, "the common pool, not the leading non-common one");
    assertTrue(route[0] != pAX, "non-common pool excluded");
  }
}

/// @notice Regression coverage for profile positivity and canonical base-oracle governance.
contract PoolConfigurationRegressionTest is BaseTestSetup {
  uint256 private constant ORACLE_CONFIGS_SLOT = 4;

  address internal constant OWNER = address(0xA11CE);
  address internal constant USER = address(0xBEEF);

  Pool internal pool;
  Admin internal admin;
  MockERC20 internal base;
  MockERC20 internal quote;
  MockAC internal ac;
  MockOracle internal oracle;

  /// @dev Deep-negative curve (±800 pbps ramp): at maxDispersion 1_282_052 its midpoint offset
  ///      drives PBPS + minOffset ≤ 0 — the positivity analog of the retired zero-midpoint profile.
  uint16 internal constant BAD_PRESET = 3;

  function _installBadCurve() internal {
    uint256[] memory interior = new uint256[](0);
    int256[] memory wQ = new int256[](5);
    (wQ[0], wQ[1], wQ[2], wQ[3], wQ[4]) =
    (int256(-800e9), int256(-400e9), int256(0), int256(400e9), int256(800e9));
    vm.prank(OWNER);
    admin.setCurve(address(pool), BAD_PRESET, interior, wQ, 1000, 0);
  }

  function _risk() internal pure returns (IPool.RiskConfig memory r) {
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20000;
    r.depthAmplifier = 10000;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
  }

  /// @dev M-1: EXTERNAL spokes must carry a cumulative bound; armed via the shared mirror-ref fixture.
  function _oracleCfg(MockOracle source, address token)
    internal
    returns (IPool.OracleConfig memory o)
  {
    o = externalOracleCfg(source, token);
  }

  function setUp() public override {
    ac = new MockAC(OWNER);
    admin = new Admin(address(ac));
    Flash flash = new Flash();
    PoolAux aux = new PoolAux(address(ac), address(admin), address(flash));
    Pool implementation = new Pool(address(ac), address(admin), address(flash), address(aux));
    PoolFactory factory = new PoolFactory(address(implementation), address(this), address(ac));

    base = new MockERC20("Wrapped Native", "WNATIVE", 18);
    quote = new MockERC20("Quote", "QUOTE", 18);
    address[] memory tokens = new address[](2);
    tokens[0] = address(base);
    tokens[1] = address(quote);
    IPool.FeeParams memory fees = IPool.FeeParams({protoShare: 25, flashFeePbps: 100});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, address(base), address(base), fees);
    pool = Pool(payable(factory.createPool(address(base), tokens, initdata)));

    oracle = new MockOracle();
    oracle.setMark(address(base), M.encodeB64(1e18, 18));
    oracle.setMark(address(quote), M.encodeB64(1e18, 18));
    vm.startPrank(OWNER);
    admin.setCurve(address(pool), DEFAULT_PRESET, defaultCurveInterior(), defaultCurveWQ(), 1000, 0);
    admin.addAsset(
      address(pool),
      address(base),
      _oracleCfg(oracle, address(base)),
      _risk(),
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
      address(quote),
      _oracleCfg(oracle, address(quote)),
      _risk(),
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
    base.approve(address(pool), type(uint256).max);
    pool.deposit(address(base), 1_000_000e18);
    quote.mint(address(this), 1_000_000e18);
    quote.approve(address(pool), type(uint256).max);
    pool.deposit(address(quote), 1_000_000e18);
  }

  /// @dev Wall-gated (hyper) preset: FLAG_REQUIRES_WALL set. Asset pricing on it MUST stay walled.
  uint16 internal constant WALL_PRESET = 4;

  function _riskWalled() internal pure returns (IPool.RiskConfig memory r) {
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20000;
    r.depthAmplifier = 0; // κ>0 forbids the depth subsidy
    r.kappaCovBps = 500;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
  }

  /// @notice Audit regression: stripping κ from an asset pricing on a FLAG_REQUIRES_WALL preset must
  ///         revert. The re-check must read the NEW kappa against the preset flag, not the pre-write
  ///         storage kappa (the earlier fix called validatePresetAssign, which read stale storage).
  function test_setRiskConfig_cannot_strip_wall_from_hyper_preset_asset() public {
    vm.prank(OWNER);
    admin.setCurve(address(pool), WALL_PRESET, defaultCurveInterior(), defaultCurveWQ(), 1000, 1);
    MockERC20 walled = new MockERC20("Walled", "WALL", 18);
    oracle.setMark(address(walled), M.encodeB64(1e18, 18));
    vm.startPrank(OWNER);
    admin.addAsset(
      address(pool),
      address(walled),
      _oracleCfg(oracle, address(walled)),
      _riskWalled(),
      WALL_PRESET,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    IPool.RiskConfig memory unwalled = _riskWalled();
    unwalled.kappaCovBps = 0;
    unwalled.depthAmplifier = 10000;
    admin.requestUpdateRiskConfig(address(pool), address(walled), unwalled);
    vm.warp(block.timestamp + 3 days);
    vm.expectRevert(Err.BadConfig.selector);
    admin.executeUpdateRiskConfig(address(pool), address(walled));
    vm.stopPrank();
  }

  /// @notice Audit regression: base migration to an INTERNAL-mode token must revert. An INTERNAL base
  ///         would make _readBasePriceOrHalt read the frozen peg and silently disable the depeg halt.
  function test_setBaseToken_rejects_internal_mode_base() public {
    vm.startPrank(OWNER);
    // Arm quote's TWO-SIDED absolute reservation band (M-1a) so INTERNAL mode is eligible, then
    // set it INTERNAL.
    admin.setAssetParams(
      address(pool),
      address(quote),
      0,
      1000,
      10000,
      10000,
      10000,
      10000,
      M.encodeB64(0.9e18, 18),
      M.encodeB64(1.1e18, 18)
    );
    IPool.OracleConfig memory internalCfg = _oracleCfg(oracle, address(quote));
    internalCfg.mode = C.ORACLE_MODE_INTERNAL;
    // INTERNAL ref bands are capped at MAX_STABLE_DEPEG_BAND_BPS — strip the fixture's wide EXTERNAL
    // band and rely on the absolute reservation band armed above.
    internalCfg.refFeedId = bytes32(0);
    internalCfg.refBandBps = 0;
    internalCfg.refPrimary = address(0);
    admin.requestOracleUpdate(address(pool), address(quote), internalCfg);
    vm.warp(block.timestamp + 3 days);
    admin.executeOracleUpdate(address(pool), address(quote));
    // Migrate base -> quote: must revert (base must be EXTERNAL).
    admin.requestBaseMigration(address(pool), address(quote));
    vm.warp(block.timestamp + 7 days);
    address[] memory spokes = new address[](0);
    vm.expectRevert(Err.BadConfig.selector);
    admin.executeBaseMigration(address(pool), spokes);
    vm.stopPrank();
  }

  function test_nonpositive_profile_rejected_at_asset_init() public {
    _installBadCurve();
    MockERC20 other = new MockERC20("Other", "OTHER", 18);
    oracle.setMark(address(other), M.encodeB64(1e18, 18));
    vm.prank(OWNER);
    vm.expectRevert(Err.BadConfig.selector);
    admin.addAsset(
      address(pool),
      address(other),
      _oracleCfg(oracle, address(other)),
      _risk(),
      BAD_PRESET,
      1000,
      18,
      1000,
      1_282_052,
      10000,
      10000
    );
  }

  function test_nonpositive_profile_rejected_at_timelocked_update() public {
    _installBadCurve();
    vm.startPrank(OWNER);
    admin.requestUpdateProfile(address(pool), address(quote), BAD_PRESET, 1000, 1_282_052);
    vm.warp(block.timestamp + 3 days);
    vm.expectRevert(Err.BadConfig.selector);
    admin.executeUpdateProfile(address(pool), address(quote));
    vm.stopPrank();
  }

  function test_native_alias_base_oracle_update_is_timelocked_and_canonical() public {
    MockOracle replacement = new MockOracle();
    replacement.setMark(address(base), M.encodeB64(9e17, 18));
    IPool.OracleConfig memory next = _oracleCfg(replacement, address(base));

    bytes32 canonicalRoot = keccak256(abi.encode(address(base), ORACLE_CONFIGS_SLOT));
    bytes32 sentinelRoot = keccak256(abi.encode(SC.NATIVE, ORACLE_CONFIGS_SLOT));
    assertEq(_storedPrimary(canonicalRoot), address(oracle), "initial canonical source");

    vm.startPrank(OWNER);
    admin.requestOracleUpdate(address(pool), SC.NATIVE, next);
    vm.expectRevert(Err.NotReady.selector);
    admin.executeOracleUpdate(address(pool), SC.NATIVE);
    vm.stopPrank();
    assertEq(_storedPrimary(canonicalRoot), address(oracle), "no immediate replacement");

    vm.warp(block.timestamp + 3 days);
    replacement.setMark(address(base), M.encodeB64(9e17, 18));
    oracle.setMark(address(quote), M.encodeB64(1e18, 18));
    vm.prank(OWNER);
    admin.executeOracleUpdate(address(pool), SC.NATIVE);

    assertEq(_storedPrimary(canonicalRoot), address(replacement), "native alias updates wnative");
    assertEq(vm.load(address(pool), sentinelRoot), bytes32(0), "sentinel feed slot untouched");
    assertEq(
      vm.load(address(pool), bytes32(uint256(sentinelRoot) + 1)),
      bytes32(0),
      "sentinel ref slot untouched"
    );
    assertEq(
      vm.load(address(pool), bytes32(uint256(sentinelRoot) + 2)),
      bytes32(0),
      "sentinel source slot untouched"
    );

    base.mint(USER, 100e18);
    vm.prank(USER);
    base.approve(address(pool), type(uint256).max);
    vm.prank(USER);
    vm.expectRevert(abi.encodeWithSelector(Err.BaseDepegged.selector, 9e17, 1000));
    pool.swap(address(base), address(quote), 100e18, 0, USER, NO_DEADLINE);
  }

  uint256 private constant ASSETS_SLOT = 3;

  /// @notice Empty-curve BUY floor invariant. A fresh listing (liabilities==0 ⇒ skew ≡ −100) on the
  ///         empty preset (presetId 0) at the MAXIMUM admin maxDispersion (= MAX_DISPERSION_PBPS,
  ///         900_000) drives the no-profile mid to its worst case: offset = skew·disp/100 = −900_000
  ///         PBPS. `_skewToPrice` now routes through the shared −90%-offset / 5%-of-mark backstop
  ///         (`_flooredOffsetPrice`) that the spline path uses, closing the one offset→price path that
  ///         previously bypassed it, so the empty-curve BUY execution price stays ≥ 5% of mark. The
  ///         on-chain 900_000 dispersion cap already keeps the raw mid > 0 (m = PBPS − 900_000 = 1e5);
  ///         this locks the floor as defense-in-depth should that cap or the skew clamp ever change.
  function test_empty_curve_buy_floored_at_max_dispersion() public {
    MockERC20 fresh = new MockERC20("Fresh", "FRESH", 18);
    uint256 mark = 1e18;
    // High σ so dispersion clamps to maxDispersion: scaledσ = σ·vega/(1000·BPS) ≫ maxDispersion.
    oracle.setFeed(
      bytes32(uint256(uint160(address(fresh)))),
      M.encodeB64(mark, 18),
      2_000_000_000,
      0,
      type(uint16).max
    );
    vm.prank(OWNER);
    admin.addAsset(
      address(pool),
      address(fresh),
      _oracleCfg(oracle, address(fresh)),
      _risk(),
      0, // presetId 0 = empty curve (header 0 → skew-anchored linear fallback)
      1000,
      18,
      1000,
      900_000, // maxDispersion = MAX_DISPERSION_PBPS (cap): worst-case offset = −900_000 PBPS
      10000,
      10000
    );
    // Seed OUTPUT reserves with liabilities==0 (Asset slot0 = reserves|liabilities): keeps skew ≡ −100
    // and gives the buy an un-clamped fill so the execution price is observable.
    bytes32 assetRoot = keccak256(abi.encode(address(fresh), ASSETS_SLOT));
    vm.store(address(pool), assetRoot, bytes32(uint256(1_000_000e18)));

    IPool.SwapQuote memory q = pool.getSwapQuote(address(base), address(fresh), 1e18);
    assertGt(q.amountOut, 0, "buy quote must not brick/zero-out on empty preset");
    // execPrice (base per FRESH, 1e18) = amountIn·WAD/amountOut; must clear the 5%-of-mark floor.
    uint256 execPrice = (uint256(1e18) * SC.WAD) / q.amountOut;
    assertGe(execPrice, (mark * 500) / SC.BPS, "empty-curve buy execPrice below 5% mark floor");
  }

  function _storedPrimary(bytes32 configRoot) internal view returns (address) {
    uint256 packed = uint256(vm.load(address(pool), bytes32(uint256(configRoot) + 2)));
    return address(uint160(packed));
  }
}

/// @dev Shared live 3-asset pool fixture (base + 2 spokes, marks 1.0, seeded) for the M-1 / M-2 /
///      M-3 / L-9 regressions below.
abstract contract AuditPoolFixture is BaseTestSetup {
  address internal constant OWNER = address(0xA11CE);
  address internal constant USER = address(0xBEEF);

  Pool internal pool;
  Admin internal admin;
  PoolFactory internal factory;
  MockERC20 internal base;
  MockERC20 internal s1;
  MockERC20 internal s2;
  MockAC internal ac;
  MockOracle internal oracle;

  function _risk() internal pure returns (IPool.RiskConfig memory r) {
    r.decayStartRatioBps = 5000;
    r.coverageMin = 5000;
    r.coverageMax = 20000;
    r.depthAmplifier = 10000;
    r.flags = C.SWAP_ENABLED_BIT | C.LIABILITY_SWAP_ENABLED_BIT;
  }

  function _addAsset(address tok, IPool.OracleConfig memory oc) internal {
    admin.addAsset(
      address(pool), tok, oc, _risk(), DEFAULT_PRESET, 1000, 18, 1000, 100000, 10000, 10000
    );
  }

  function _refreshMarks() internal {
    oracle.setMark(address(base), M.encodeB64(1e18, 18));
    oracle.setMark(address(s1), M.encodeB64(1e18, 18));
    oracle.setMark(address(s2), M.encodeB64(1e18, 18));
  }

  function setUp() public virtual override {
    ac = new MockAC(OWNER);
    admin = new Admin(address(ac));
    Flash flash = new Flash();
    PoolAux aux = new PoolAux(address(ac), address(admin), address(flash));
    Pool implementation = new Pool(address(ac), address(admin), address(flash), address(aux));
    factory = new PoolFactory(address(implementation), address(this), address(ac));

    base = new MockERC20("Base", "BASE", 18);
    s1 = new MockERC20("Spoke1", "SPK1", 18);
    s2 = new MockERC20("Spoke2", "SPK2", 18);
    address[] memory tokens = new address[](3);
    tokens[0] = address(base);
    tokens[1] = address(s1);
    tokens[2] = address(s2);
    IPool.FeeParams memory fees = IPool.FeeParams({protoShare: 25, flashFeePbps: 100});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, address(base), address(base), fees);
    pool = Pool(payable(factory.createPool(address(base), tokens, initdata)));

    oracle = new MockOracle();
    _refreshMarks();
    vm.startPrank(OWNER);
    admin.setCurve(address(pool), DEFAULT_PRESET, defaultCurveInterior(), defaultCurveWQ(), 1000, 0);
    _addAsset(address(base), externalOracleCfg(oracle, address(base)));
    _addAsset(address(s1), externalOracleCfg(oracle, address(s1)));
    _addAsset(address(s2), externalOracleCfg(oracle, address(s2)));
    vm.stopPrank();

    for (uint256 i = 0; i < tokens.length; i++) {
      MockERC20 t = MockERC20(tokens[i]);
      t.mint(address(this), 1_000_000e18);
      t.approve(address(pool), type(uint256).max);
      pool.deposit(tokens[i], 1_000_000e18);
    }
  }
}

/// @notice M-1: EXTERNAL non-base spokes must carry a CUMULATIVE bound on a walked mark — an
///         independent ref band or an absolute reservation band. Per-push maxDeviation alone bounds
///         each step only.
contract ExternalSpokeCumulativeBoundRegressionTest is AuditPoolFixture {
  function test_external_spoke_requires_cumulative_bound() public {
    MockERC20 naked = new MockERC20("Naked", "NKD", 18);
    oracle.setMark(address(naked), M.encodeB64(1e18, 18));
    IPool.OracleConfig memory o;
    o.primary = address(oracle);
    o.feedId = oracle.feedIdFor(address(naked)); // EXTERNAL, no ref band, no reservation band
    vm.prank(OWNER);
    vm.expectRevert(
      abi.encodeWithSelector(Err.NotConfigured.selector, Err.Resource.ORACLE, address(naked))
    );
    _addAsset(address(naked), o);
  }

  /// @dev M-1a: a ONE-SIDED abs band does NOT satisfy the mandate — with the ref band stripped, the
  ///      open side lets a compromised quorum walk the mark unboundedly in that direction. Sets the
  ///      band via setAssetParams (legal while the fixture ref band is still armed), then tries to
  ///      strip the ref band; `expectFail` asserts the strip reverts on the one-sided band.
  function _stripRefBandWith(uint64 lo, uint64 hi, bool expectFail) internal {
    vm.startPrank(OWNER);
    admin.setAssetParams(address(pool), address(s1), 0, 1000, 10000, 10000, 10000, 10000, lo, hi);
    IPool.OracleConfig memory o;
    o.primary = address(oracle);
    o.feedId = oracle.feedIdFor(address(s1)); // EXTERNAL, no ref band
    admin.requestOracleUpdate(address(pool), address(s1), o);
    vm.warp(block.timestamp + 3 days);
    if (expectFail) {
      vm.expectRevert(
        abi.encodeWithSelector(Err.NotConfigured.selector, Err.Resource.ORACLE, address(s1))
      );
    }
    admin.executeOracleUpdate(address(pool), address(s1));
    vm.stopPrank();
  }

  function test_one_sided_abs_band_hi_only_rejected() public {
    _stripRefBandWith(0, M.encodeB64(1.1e18, 18), true); // downward walk unbounded
  }

  function test_one_sided_abs_band_lo_only_rejected() public {
    _stripRefBandWith(M.encodeB64(0.9e18, 18), 0, true); // upward walk unbounded
  }

  function test_two_sided_abs_band_accepted() public {
    _stripRefBandWith(M.encodeB64(0.9e18, 18), M.encodeB64(1.1e18, 18), false);
  }

  function test_volatile_refband_halts_walked_mark() public {
    // Re-point s1's ref at an INDEPENDENT oracle (the fixture mirror always agrees with primary).
    MockOracle ref = new MockOracle();
    ref.setMark(address(s1), M.encodeB64(1e18, 18));
    IPool.OracleConfig memory o;
    o.primary = address(oracle);
    o.feedId = oracle.feedIdFor(address(s1));
    o.refPrimary = address(ref);
    o.refFeedId = ref.feedIdFor(address(s1));
    o.refBandBps = 300;
    vm.startPrank(OWNER);
    admin.requestOracleUpdate(address(pool), address(s1), o);
    vm.warp(block.timestamp + 3 days);
    admin.executeOracleUpdate(address(pool), address(s1));
    vm.stopPrank();
    _refreshMarks();
    ref.setMark(address(s1), M.encodeB64(1e18, 18)); // fresh reference at 1.0
    // Walk the primary mark +5% past the ±3% band vs the untouched reference: swap must halt.
    oracle.setMark(address(s1), M.encodeB64(1.05e18, 18));
    base.mint(USER, 200e18);
    vm.startPrank(USER);
    base.approve(address(pool), type(uint256).max);
    vm.expectPartialRevert(Err.PriceOutsideReservation.selector);
    pool.swap(address(base), address(s1), 100e18, 0, USER, NO_DEADLINE);
    vm.stopPrank();
  }
}

/// @notice M-2 Δ1: a live reservation band on the steward path REQUIRES the absolute hard fence —
///         with the fence off, the ±25% relative clamp alone lets repeated calls ratchet the band
///         arbitrarily far.
contract StewardReservationFenceRegressionTest is AuditPoolFixture {
  function _fences(uint64 lo, uint64 hi) internal pure returns (IAdmin.RiskFences memory f) {
    f.minFeeHardMin = 1;
    f.minFeeHardMax = 20_000;
    f.maxFeeHardMax = 50_000;
    f.gammaHardMin = 5_000;
    f.gammaHardMax = 40_000;
    f.vegaHardMin = 5_000;
    f.vegaHardMax = 30_000;
    f.haircutHardMax = 10_000;
    f.maxDeltaBps = 2_500;
    f.reservationHardLoMin = lo;
    f.reservationHardHiMax = hi;
  }

  function test_steward_reservation_requires_hard_fence() public {
    vm.startPrank(OWNER);
    // Owner seeds the live band (steward cannot move a bound off zero).
    admin.setAssetParams(
      address(pool),
      address(s1),
      0,
      1000,
      10000,
      10000,
      10000,
      10000,
      M.encodeB64(0.98e18, 18),
      M.encodeB64(1.02e18, 18)
    );
    admin.setRiskFences(address(pool), address(s1), _fences(0, 0));
    // Fences off + live band ⇒ fail closed.
    vm.expectRevert(
      abi.encodeWithSelector(Err.NotConfigured.selector, Err.Resource.ASSET, address(s1))
    );
    admin.setAssetParamsBounded(
      address(pool),
      address(s1),
      0,
      1000,
      10000,
      10000,
      10000,
      10000,
      M.encodeB64(0.985e18, 18),
      M.encodeB64(1.015e18, 18)
    );
    // Nonzero fences ⇒ the same bounded call succeeds.
    admin.setRiskFences(
      address(pool), address(s1), _fences(M.encodeB64(0.95e18, 18), M.encodeB64(1.05e18, 18))
    );
    admin.setAssetParamsBounded(
      address(pool),
      address(s1),
      0,
      1000,
      10000,
      10000,
      10000,
      10000,
      M.encodeB64(0.985e18, 18),
      M.encodeB64(1.015e18, 18)
    );
    vm.stopPrank();
    assertEq(
      IPool(address(pool)).getAsset(address(s1)).reservationPrice,
      M.encodeB64(0.985e18, 18),
      "bounded write landed"
    );
  }

  function test_steward_reservation_ratchet_terminates_at_fence() public {
    uint64 hardLo = M.encodeB64(0.5e18, 18);
    uint64 hardHi = M.encodeB64(2e18, 18);
    uint64 resMax = M.encodeB64(1.05e18, 18);
    vm.startPrank(OWNER);
    admin.setAssetParams(
      address(pool), address(s1), 0, 1000, 10000, 10000, 10000, 10000, M.encodeB64(1e18, 18), resMax
    );
    admin.setRiskFences(address(pool), address(s1), _fences(hardLo, hardHi));
    // Walk the floor down −25%/call: the absolute fence must terminate the ratchet.
    uint256 cur = 1e18;
    uint64 curB64 = M.encodeB64(1e18, 18);
    uint256 steps;
    for (uint256 i; i < 8; ++i) {
      uint256 next = (cur * 7500) / 10000;
      uint64 nextB64 = M.encodeB64(next, 18);
      try admin.setAssetParamsBounded(
        address(pool), address(s1), 0, 1000, 10000, 10000, 10000, 10000, nextB64, resMax
      ) {
        cur = next;
        curB64 = nextB64;
        steps++;
      } catch {
        break;
      }
    }
    assertGt(steps, 0, "at least one bounded step accepted");
    assertGe(uint256(curB64), uint256(hardLo), "terminal floor >= reservationHardLoMin");
    // The next −25% step must revert on the absolute fence.
    vm.expectRevert();
    admin.setAssetParamsBounded(
      address(pool),
      address(s1),
      0,
      1000,
      10000,
      10000,
      10000,
      10000,
      M.encodeB64((cur * 7500) / 10000, 18),
      resMax
    );
    vm.stopPrank();
  }
}

/// @notice R-1: B64 packs mantissa in the HIGH bits, so raw uint64 `<`/`>` on packed values is
///         non-monotonic across a decimal-decade (exp) boundary. Config-time band/fence ordering
///         checks must compare decoded (1e18) like PoolIO.priceBandGuard, else an inverted band
///         (min 0.9 / max 0.11) is silently accepted and every subsequent mark reverts swaps
///         asset-wide.
contract B64BandOrderingRegressionTest is AuditPoolFixture {
  // Cross-decade counterexample: 0.9 → (mant 9e14, exp 3); 0.11 → (mant 1.1e15, exp 2).
  uint64 internal p090; // 0.9e18
  uint64 internal p011; // 0.11e18
  uint64 internal p110; // 1.1e18
  uint64 internal p900; // 9e18

  function setUp() public override {
    super.setUp();
    p090 = M.encodeB64(0.9e18, 18);
    p011 = M.encodeB64(0.11e18, 18);
    p110 = M.encodeB64(1.1e18, 18);
    p900 = M.encodeB64(9e18, 18);
    // Premise: raw packed order inverts numeric order across the decade boundary.
    assertGt(uint256(p011), uint256(p090), "raw packed 0.11 > 0.9 (mantissa-first)");
    assertLt(uint256(p900), uint256(p110), "raw packed 9 < 1.1 (mantissa-first)");
  }

  function _fences(uint64 lo, uint64 hi) internal pure returns (IAdmin.RiskFences memory f) {
    f.minFeeHardMin = 1;
    f.minFeeHardMax = 20_000;
    f.maxFeeHardMax = 50_000;
    f.gammaHardMin = 5_000;
    f.gammaHardMax = 40_000;
    f.vegaHardMin = 5_000;
    f.vegaHardMax = 30_000;
    f.haircutHardMax = 10_000;
    f.maxDeltaBps = 2_500;
    f.reservationHardLoMin = lo;
    f.reservationHardHiMax = hi;
  }

  function _setParams(uint64 lo, uint64 hi) internal {
    admin.setAssetParams(address(pool), address(s1), 0, 1000, 10000, 10000, 10000, 10000, lo, hi);
  }

  function test_owner_inverted_band_across_decade_reverts() public {
    vm.startPrank(OWNER);
    // min 0.9 / max 0.11: numerically inverted, raw-uint64 ordered — was silently accepted.
    vm.expectRevert(Err.InvalidInput.selector);
    _setParams(p090, p011);
    // Valid band that raw compare would have REJECTED (raw max < raw min): must be accepted.
    _setParams(p011, p090);
    // Valid same-decade band still accepted.
    _setParams(p090, p110);
    vm.stopPrank();
    assertEq(IPool(address(pool)).getAsset(address(s1)).reservationPrice, p090, "band landed");
  }

  function test_fence_inverted_across_decade_reverts() public {
    vm.startPrank(OWNER);
    vm.expectRevert(Err.BadConfig.selector);
    admin.setRiskFences(address(pool), address(s1), _fences(p090, p011));
    // Valid cross-decade fence still accepted.
    admin.setRiskFences(address(pool), address(s1), _fences(p011, p900));
    vm.stopPrank();
  }

  function test_steward_hard_fence_decoded_across_decade() public {
    vm.startPrank(OWNER);
    _setParams(M.encodeB64(0.95e18, 18), M.encodeB64(1.05e18, 18));
    admin.setRiskFences(address(pool), address(s1), _fences(p090, p110));
    // Floor fence: 0.11 < hardLo 0.9 numerically, but raw packed 0.11 > 0.9 — was a bypass.
    vm.expectPartialRevert(Err.ThresholdViolation.selector);
    admin.setAssetParamsBounded(
      address(pool),
      address(s1),
      0,
      1000,
      10000,
      10000,
      10000,
      10000,
      p011,
      M.encodeB64(1.05e18, 18)
    );
    // Ceiling fence: 9 > hardHi 1.1 numerically, but raw packed 9 < 1.1 — was a bypass.
    vm.expectPartialRevert(Err.ThresholdViolation.selector);
    admin.setAssetParamsBounded(
      address(pool),
      address(s1),
      0,
      1000,
      10000,
      10000,
      10000,
      10000,
      M.encodeB64(0.95e18, 18),
      p900
    );
    // In-fence step still accepted.
    admin.setAssetParamsBounded(
      address(pool),
      address(s1),
      0,
      1000,
      10000,
      10000,
      10000,
      10000,
      M.encodeB64(0.94e18, 18),
      M.encodeB64(1.06e18, 18)
    );
    vm.stopPrank();
  }
}

/// @notice M-3: base migration re-anchors EVERY remaining spoke atomically with the numeraire flip —
///         no stale-anchor window, and an incomplete/bogus spoke set reverts the migration.
contract BaseMigrationAtomicReanchorRegressionTest is AuditPoolFixture {
  function _requestAndWarp() internal {
    admin.requestBaseMigration(address(pool), address(s1));
    vm.warp(block.timestamp + 7 days);
    _refreshMarks();
  }

  function test_baseMigration_atomic_reanchors_spokes() public {
    address[] memory spokes = new address[](1);
    spokes[0] = address(s2);
    vm.startPrank(OWNER);
    _requestAndWarp();
    admin.executeBaseMigration(address(pool), spokes);
    vm.stopPrank();

    assertEq(IPool(address(pool)).getAsset(address(s1)).anchor, address(0), "new base is root");
    assertEq(IPool(address(pool)).getAsset(address(base)).anchor, address(s1), "old base demoted");
    assertEq(IPool(address(pool)).getAsset(address(s2)).anchor, address(s1), "spoke re-anchored");

    // spoke ↔ new base and cross (s2 → s1 → oldBase) quotes/swaps still work; old base is a plain
    // spoke, never a mid-hop.
    s2.mint(USER, 300e18);
    vm.startPrank(USER);
    s2.approve(address(pool), type(uint256).max);
    pool.swap(address(s2), address(s1), 100e18, 0, USER, NO_DEADLINE);
    pool.swap(address(s2), address(base), 100e18, 0, USER, NO_DEADLINE);
    vm.stopPrank();
  }

  function test_baseMigration_rejects_unarmed_old_base() public {
    vm.startPrank(OWNER);
    // Strip the base's ref band (legal while base: the numeraire is exempt from the M-1 mandate).
    IPool.OracleConfig memory bare;
    bare.primary = address(oracle);
    bare.feedId = oracle.feedIdFor(address(base));
    admin.requestOracleUpdate(address(pool), address(base), bare);
    vm.warp(block.timestamp + 3 days);
    admin.executeOracleUpdate(address(pool), address(base));
    // Migration must refuse to demote an unarmed old base into an unbounded EXTERNAL spoke.
    _requestAndWarp();
    address[] memory spokes = new address[](1);
    spokes[0] = address(s2);
    vm.expectRevert(
      abi.encodeWithSelector(Err.NotConfigured.selector, Err.Resource.ORACLE, address(base))
    );
    admin.executeBaseMigration(address(pool), spokes);
    // Arm an absolute reservation band on the old base: the same migration now succeeds.
    admin.setAssetParams(
      address(pool),
      address(base),
      0,
      1000,
      10000,
      10000,
      10000,
      10000,
      M.encodeB64(0.9e18, 18),
      M.encodeB64(1.1e18, 18)
    );
    admin.executeBaseMigration(address(pool), spokes);
    vm.stopPrank();
    assertEq(IPool(address(pool)).getAsset(address(base)).anchor, address(s1), "old base demoted");
  }

  function test_baseMigration_rejects_incomplete_spokes() public {
    address[] memory none = new address[](0);
    vm.startPrank(OWNER);
    _requestAndWarp();
    // Roster completeness scan names the missed spoke (s2 still anchored to the old base).
    vm.expectRevert(abi.encodeWithSelector(Err.InvalidAnchor.selector, address(s2), address(base)));
    admin.executeBaseMigration(address(pool), none);
    vm.stopPrank();
  }

  /// @dev M-3 wedge: a roster token never initAsset'd (registered at createPool, listing skipped) is
  ///      a permanent orphan — the old `spokes.length+2 == roster.length` proxy made setBaseToken
  ///      unsatisfiable forever. The listed-assets completeness scan skips it.
  function test_baseMigration_tolerates_roster_orphan() public {
    MockERC20 orphan = new MockERC20("Orphan", "ORPH", 18);
    address[] memory tokens = new address[](4);
    tokens[0] = address(base);
    tokens[1] = address(s1);
    tokens[2] = address(s2);
    tokens[3] = address(orphan);
    bytes memory initdata = abi.encodeWithSelector(
      Pool.initialize.selector,
      address(base),
      address(base),
      IPool.FeeParams({protoShare: 25, flashFeePbps: 100})
    );
    Pool p2 = Pool(payable(factory.createPool(address(base), tokens, initdata)));
    vm.startPrank(OWNER);
    admin.setCurve(address(p2), DEFAULT_PRESET, defaultCurveInterior(), defaultCurveWQ(), 1000, 0);
    admin.addAsset(
      address(p2),
      address(base),
      externalOracleCfg(oracle, address(base)),
      _risk(),
      DEFAULT_PRESET,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    admin.addAsset(
      address(p2),
      address(s1),
      externalOracleCfg(oracle, address(s1)),
      _risk(),
      DEFAULT_PRESET,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    admin.addAsset(
      address(p2),
      address(s2),
      externalOracleCfg(oracle, address(s2)),
      _risk(),
      DEFAULT_PRESET,
      1000,
      18,
      1000,
      100000,
      10000,
      10000
    );
    admin.requestBaseMigration(address(p2), address(s1));
    vm.warp(block.timestamp + 7 days);
    _refreshMarks();
    address[] memory spokes = new address[](1);
    spokes[0] = address(s2);
    admin.executeBaseMigration(address(p2), spokes);
    vm.stopPrank();
    assertEq(IPool(address(p2)).getAsset(address(base)).anchor, address(s1), "old base demoted");
  }

  function test_baseMigration_rejects_bad_spoke() public {
    vm.startPrank(OWNER);
    _requestAndWarp();
    // Duplicate: second entry no longer anchors to the old base.
    address[] memory dup = new address[](2);
    dup[0] = address(s2);
    dup[1] = address(s2);
    vm.expectRevert(abi.encodeWithSelector(Err.InvalidAnchor.selector, address(s2), address(base)));
    admin.executeBaseMigration(address(pool), dup);
    // Unlisted token: anchor is zero, never the old base.
    address[] memory bad = new address[](1);
    bad[0] = address(0xDEAD);
    vm.expectRevert(
      abi.encodeWithSelector(Err.InvalidAnchor.selector, address(0xDEAD), address(base))
    );
    admin.executeBaseMigration(address(pool), bad);
    vm.stopPrank();
  }
}

/// @notice L-9: a live pending timelock op cannot be silently re-queued (payload swap + eta reset);
///         cancel first. Distinct keys stay independent.
contract TimelockRequeueRegressionTest is AuditPoolFixture {
  function test_requeue_pending_op_reverts() public {
    IPool.OracleConfig memory o = externalOracleCfg(oracle, address(s1));
    vm.startPrank(OWNER);
    admin.requestOracleUpdate(address(pool), address(s1), o);
    vm.expectPartialRevert(Err.PendingTimelock.selector);
    admin.requestOracleUpdate(address(pool), address(s1), o);
    vm.stopPrank();
  }

  function test_cancel_then_requeue_succeeds() public {
    IPool.OracleConfig memory o = externalOracleCfg(oracle, address(s1));
    vm.startPrank(OWNER);
    admin.requestOracleUpdate(address(pool), address(s1), o);
    admin.cancelOracleUpdate(address(pool), address(s1));
    admin.requestOracleUpdate(address(pool), address(s1), o);
    vm.stopPrank();
  }

  function test_hook_requeue_reverts() public {
    address hook = address(new MockOracle()); // any code-bearing target passes the EOA gate
    vm.startPrank(OWNER);
    admin.requestSetAssetHook(address(pool), address(s1), hook, 0);
    vm.expectPartialRevert(Err.PendingTimelock.selector);
    admin.requestSetAssetHook(address(pool), address(s1), hook, 0);
    vm.stopPrank();
  }

  function test_distinct_keys_independent() public {
    vm.startPrank(OWNER);
    admin.requestOracleUpdate(address(pool), address(s1), externalOracleCfg(oracle, address(s1)));
    // Different token = different key; different op = different key. Neither reverts.
    admin.requestOracleUpdate(address(pool), address(s2), externalOracleCfg(oracle, address(s2)));
    admin.requestBaseMigration(address(pool), address(s1));
    vm.stopPrank();
  }
}

/// @notice L-10: the 5 user entrypoints (withdraw/withdrawTo/swapLiability/swap/batchSwap) carry an
///         INCLUSIVE deadline (ts == deadline succeeds; no 0-sentinel — opt-out = type(uint256).max),
///         checked once at entry via `beforeDeadline` (libs untouched; withdraw→withdrawTo delegation
///         is not double-checked). deposit/donate excluded: no minOut, mint at current mark.
contract DeadlineRegressionTest is AuditPoolFixture {
  function _batchArgs() internal view returns (bytes memory inputs, bytes memory outputs) {
    // inputs entry: [token:160][amtB64:64][pad:32]; outputs entry: [token:160][weightBps:16][pad:16][minB64:64]
    inputs = abi.encodePacked(
      bytes32((uint256(uint160(address(s1))) << 96) | (uint256(M.encodeB64(100e18, 18)) << 32))
    );
    outputs = abi.encodePacked(
      bytes32(
        (uint256(uint160(address(s2))) << 96) | (uint256(10_000) << 80)
          | uint256(M.encodeB64(1, 18))
      )
    );
  }

  function test_L10_ExpiredDeadlineReverts() public {
    // Explicit constants: via_ir caches block.timestamp across vm.warp, so never read-then-warp.
    uint256 deadline = 999_999;
    vm.warp(1_000_000); // ts > deadline — modifier reverts before any state read
    (bytes memory inputs, bytes memory outputs) = _batchArgs();

    vm.expectRevert(Err.Expired.selector);
    pool.withdraw(address(base), 1e18, 0, deadline);
    vm.expectRevert(Err.Expired.selector);
    pool.withdrawTo(address(s1), address(base), 1e18, 0, deadline);
    vm.expectRevert(Err.Expired.selector);
    pool.swapLiability(address(s1), address(base), 1e18, 0, deadline);
    vm.expectRevert(Err.Expired.selector);
    pool.swap(address(base), address(s1), 1e18, 0, address(this), deadline);
    vm.expectRevert(Err.Expired.selector);
    pool.batchSwap(inputs, outputs, address(this), deadline);
  }

  function test_L10_DeadlineBoundaryInclusive() public {
    s1.mint(address(this), 1_000e18); // batch input leg funding
    base.mint(address(this), 1_000e18); // swap input leg funding (setUp deposits the full mint)
    // Warp to a deadline-exact ts past the setUp JIT flow cooldown (getBlockTimestamp: via_ir
    // caches a raw block.timestamp read across warps).
    uint256 deadline = vm.getBlockTimestamp() + uint256(C.DEFAULT_FLOW_COOLDOWN) + 1;
    vm.warp(deadline); // inclusive boundary: ts == deadline must succeed
    _refreshMarks();
    // Withdraws first: swapLiability stamps lastDepositTime[this][base] (JIT guard) and would
    // cooldown-block a later base outflow at the same ts.
    assertGt(
      pool.withdraw(address(base), 1_000e18, 0, deadline).amountOut, 0, "withdraw at ts==deadline"
    );
    assertGt(
      pool.withdrawTo(address(s1), address(base), 1_000e18, 0, deadline).amountOut,
      0,
      "withdrawTo at ts==deadline"
    );
    assertGt(
      pool.swapLiability(address(s1), address(base), 1_000e18, 0, deadline),
      0,
      "swapLiability at ts==deadline"
    );
    assertGt(
      pool.swap(address(base), address(s1), 100e18, 0, address(this), deadline),
      0,
      "swap at ts==deadline"
    );
    (bytes memory inputs, bytes memory outputs) = _batchArgs();
    uint256[] memory outs = pool.batchSwap(inputs, outputs, address(this), deadline);
    assertGt(outs[0], 0, "batchSwap at ts==deadline");
  }
}

/// @notice H-2 Tier-1: an armed minFee fence (minFeeHardMin != 0) floors the OWNER setAssetParams
///         path too — sub-fence lowering must go through setRiskFences first (explicit 2-tx
///         intent). Unfenced assets (minFeeHardMin == 0) keep the legacy unbounded owner path.
contract OwnerMinFeeFenceRegressionTest is AuditPoolFixture {
  function _fences(uint16 feeFloor) internal pure returns (IAdmin.RiskFences memory f) {
    f.minFeeHardMin = feeFloor;
    f.minFeeHardMax = 20_000;
    f.maxFeeHardMax = 50_000;
    f.gammaHardMin = 5_000;
    f.gammaHardMax = 40_000;
    f.vegaHardMin = 5_000;
    f.vegaHardMax = 30_000;
    f.haircutHardMax = 10_000;
    f.maxDeltaBps = 2_500;
  }

  function _setParams(address tok, uint16 minFeePbps) internal {
    admin.setAssetParams(address(pool), tok, 0, minFeePbps, 10000, 10000, 10000, 10000, 0, 0);
  }

  function test_owner_setAssetParams_below_fence_reverts() public {
    vm.startPrank(OWNER);
    admin.setRiskFences(address(pool), address(s1), _fences(1000));
    vm.expectRevert(abi.encodeWithSelector(Err.ThresholdViolation.selector, 999, 1000));
    _setParams(address(s1), 999);
    vm.stopPrank();
  }

  function test_owner_setAssetParams_at_fence_passes() public {
    vm.startPrank(OWNER);
    admin.setRiskFences(address(pool), address(s1), _fences(1000));
    _setParams(address(s1), 1000);
    vm.stopPrank();
    assertEq(IPool(address(pool)).getAsset(address(s1)).minFeePbps, 1000, "at-fence write landed");
  }

  function test_owner_setAssetParams_unfenced_unaffected() public {
    // s2 never fenced: minFeeHardMin reads 0 ⇒ check off (backward compat).
    vm.prank(OWNER);
    _setParams(address(s2), C.MIN_FEE_PBPS);
    assertEq(
      IPool(address(pool)).getAsset(address(s2)).minFeePbps, C.MIN_FEE_PBPS, "unfenced write landed"
    );
  }
}
