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
import {Maths as M} from "../src/libraries/Maths.sol";
import {MockAC, MockOracle} from "./fixtures/BaseTestSetup.sol";
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
    IPool.FeeParams memory fees = IPool.FeeParams({protoShare: 25, flashFeeBps: 100});
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

/// @notice Regression coverage for profile positivity and canonical base-oracle governance.
contract PoolConfigurationRegressionTest is Test {
  uint256 private constant ORACLE_CONFIGS_SLOT = 5;

  address internal constant OWNER = address(0xA11CE);
  address internal constant USER = address(0xBEEF);

  Pool internal pool;
  Admin internal admin;
  MockERC20 internal base;
  MockERC20 internal quote;
  MockAC internal ac;
  MockOracle internal oracle;

  function _profile() internal pure returns (IPool.LiquidityProfile memory p) {
    p.weights[0] = 50;
    p.weights[1] = 50;
    p.weights[2] = 50;
    p.weights[3] = 50;
    p.knots[0] = -50;
    p.knots[1] = -25;
    p.knots[2] = 0;
    p.knots[3] = 25;
    p.knots[4] = 50;
  }

  function _zeroMidpointProfile() internal pure returns (IPool.LiquidityProfile memory p) {
    p.weights[0] = 100;
    p.weights[1] = 100;
    p.knots[0] = -128;
    p.knots[1] = -78;
    p.knots[2] = -28;
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

  function setUp() public {
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
    IPool.FeeParams memory fees = IPool.FeeParams({protoShare: 25, flashFeeBps: 100});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, address(base), address(base), fees);
    pool = Pool(payable(factory.createPool(address(base), tokens, initdata)));

    oracle = new MockOracle();
    oracle.setMark(address(base), M.encodeB64(1e18, 18));
    oracle.setMark(address(quote), M.encodeB64(1e18, 18));
    vm.startPrank(OWNER);
    admin.addAsset(
      address(pool),
      address(base),
      _oracleCfg(oracle, address(base)),
      _risk(),
      _profile(),
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
      _profile(),
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

  function test_nonpositive_profile_rejected_at_asset_init() public {
    MockERC20 other = new MockERC20("Other", "OTHER", 18);
    oracle.setMark(address(other), M.encodeB64(1e18, 18));
    vm.prank(OWNER);
    vm.expectRevert(Err.BadConfig.selector);
    admin.addAsset(
      address(pool),
      address(other),
      _oracleCfg(oracle, address(other)),
      _risk(),
      _zeroMidpointProfile(),
      1000,
      18,
      1000,
      1_282_052,
      10000,
      10000
    );
  }

  function test_nonpositive_profile_rejected_at_timelocked_update() public {
    vm.startPrank(OWNER);
    admin.requestUpdateProfile(
      address(pool), address(quote), _zeroMidpointProfile(), 1000, 1_282_052
    );
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
