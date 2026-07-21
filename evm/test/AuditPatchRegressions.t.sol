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
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {BaseTestSetup, MockAC, MockOracle} from "./fixtures/BaseTestSetup.sol";
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

  function _oracleCfg(MockOracle source, address token)
    internal
    pure
    returns (IPool.OracleConfig memory o)
  {
    o.primary = address(source);
    o.feedId = bytes32(uint256(uint160(token)));
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
    admin.setCurve(
      address(pool), DEFAULT_PRESET, defaultCurveInterior(), defaultCurveWQ(), 1000, 0
    );
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
    // Arm quote's absolute reservation band so INTERNAL mode is eligible, then set it INTERNAL.
    admin.setAssetParams(
      address(pool), address(quote), 0, 1000, 10000, 10000, 10000, 10000, uint64(9e17), 0
    );
    IPool.OracleConfig memory internalCfg = _oracleCfg(oracle, address(quote));
    internalCfg.mode = C.ORACLE_MODE_INTERNAL;
    admin.requestOracleUpdate(address(pool), address(quote), internalCfg);
    vm.warp(block.timestamp + 3 days);
    admin.executeOracleUpdate(address(pool), address(quote));
    // Migrate base -> quote: must revert (base must be EXTERNAL).
    admin.requestBaseMigration(address(pool), address(quote));
    vm.warp(block.timestamp + 7 days);
    vm.expectRevert(Err.BadConfig.selector);
    admin.executeBaseMigration(address(pool));
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
    pool.swap(address(base), address(quote), 100e18, 0, USER);
  }

  function _storedPrimary(bytes32 configRoot) internal view returns (address) {
    uint256 packed = uint256(vm.load(address(pool), bytes32(uint256(configRoot) + 2)));
    return address(uint160(packed));
  }
}
