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
import {Err} from "@btr-shared/Errors.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {UpgradeableBeacon} from "solady/utils/UpgradeableBeacon.sol";
import {MockAC} from "./fixtures/BaseTestSetup.sol";

/// @dev A codeful implementation-shaped shim used to prove the factory independently validates
/// nested PoolAux wiring even if a future implementation omits Pool's constructor checks.
contract MockPoolImplementationWiring {
  address public immutable AC;
  address public immutable admin;
  address public immutable flash;
  address public immutable poolAux;

  constructor(address ac_, address admin_, address flash_, address poolAux_) {
    AC = ac_;
    admin = admin_;
    flash = flash_;
    poolAux = poolAux_;
  }
}

/// @title PoolBeaconUpgradeTest
/// @notice Beacon-fleet upgradeability: every pool is an ERC1967 beacon proxy reading its impl
///         from one Solady UpgradeableBeacon, so the timelocked reference upgrade swaps the impl
///         for ALL live pools atomically. Also pins predict==deployed and the owner+timelock gate.
contract PoolBeaconUpgradeTest is Test {
  PoolFactory factory;
  Pool implA;
  Admin admin;
  Flash flashA;
  Flash flashB;
  PoolAux poolAux;
  MockAC ac;
  MockERC20 base;
  MockERC20 quote;

  address constant OWNER = address(0xA11CE);
  address constant GUARDIAN = address(0x6DA);

  function setUp() public {
    ac = new MockAC(OWNER);
    admin = new Admin(address(ac));
    flashA = new Flash();
    flashB = new Flash();
    poolAux = new PoolAux(address(ac), address(admin), address(flashA));
    implA = new Pool(address(ac), address(admin), address(flashA), address(poolAux));
    factory = new PoolFactory(address(implA), address(this), address(ac));

    base = new MockERC20("Base", "BASE", 18);
    quote = new MockERC20("Quote", "QUOT", 18);
  }

  /// @dev A compat-valid upgrade impl: same AC/admin/flash wiring (fix #2 asserts equality), but a
  ///      FRESH codeful poolAux (fix #2 allows poolAux to change) — the observable proof of the swap.
  function _compatImpl() internal returns (Pool implB, address newAux) {
    newAux = address(new PoolAux(address(ac), address(admin), address(flashA)));
    implB = new Pool(address(ac), address(admin), address(flashA), newAux);
  }

  function _create(address baseTok, address other)
    internal
    returns (address pool, address[] memory toks)
  {
    toks = new address[](2);
    toks[0] = baseTok;
    toks[1] = other;
    IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 25, flashFeePbps: 100});
    bytes memory initdata =
      abi.encodeWithSelector(Pool.initialize.selector, baseTok, address(0xCAFE), fp);
    pool = factory.createPool(baseTok, toks, initdata);
  }

  /// @notice A single beacon.upgradeTo swaps the impl for every live pool — proven via the
  ///         impl-baked immutable `poolAux()` (read through delegatecall) flipping for all pools.
  ///         (poolAux is the immutable fix #2 permits to change; AC/admin/flash must stay equal.)
  function test_beacon_upgrade_atomic_all_pools() public {
    (address p1,) = _create(address(base), address(quote));
    (address p2,) = _create(address(quote), address(base));
    assertTrue(p1 != p2, "distinct proxies");
    assertEq(Pool(payable(p1)).poolAux(), address(poolAux), "p1 pre-upgrade impl");
    assertEq(Pool(payable(p2)).poolAux(), address(poolAux), "p2 pre-upgrade impl");

    // New impl carries a different `poolAux` immutable — observable proof of the swap.
    (Pool implB, address newAux) = _compatImpl();

    vm.prank(OWNER);
    factory.requestReferenceUpgrade(address(implB));
    vm.warp(block.timestamp + factory.UPGRADE_TIMELOCK());
    vm.prank(OWNER);
    factory.executeReferenceUpgrade();

    // Fleet-wide, atomic: both pre-existing pools now resolve to implB's immutable.
    assertEq(Pool(payable(p1)).poolAux(), newAux, "p1 post-upgrade impl");
    assertEq(Pool(payable(p2)).poolAux(), newAux, "p2 post-upgrade impl");
    assertEq(factory.referencePool(), address(implB), "referencePool == beacon impl");
    assertEq(UpgradeableBeacon(factory.beacon()).implementation(), address(implB), "beacon impl");
  }

  /// @notice Off-chain predicted address (beacon-proxy init-code-hash) == on-chain deployed.
  function test_predict_matches_deployed() public {
    address[] memory toks = new address[](2);
    toks[0] = address(base);
    toks[1] = address(quote);
    bytes32 salt = keccak256(
      abi.encodePacked(address(this), address(base), keccak256(abi.encode(toks)), block.chainid)
    );
    address predicted = LibClone.predictDeterministicAddressERC1967BeaconProxy(
      factory.beacon(), salt, address(factory)
    );
    (address deployed,) = _create(address(base), address(quote));
    assertEq(deployed, predicted, "predict == deployed");
  }

  /// @notice Reference upgrade is owner-gated (AC.owner()).
  function test_upgrade_gated_owner() public {
    (Pool implB,) = _compatImpl();
    vm.expectRevert(Err.NotOwner.selector);
    factory.requestReferenceUpgrade(address(implB)); // caller != AC.owner()
  }

  /// @notice Execution before the 7d timelock elapses reverts.
  function test_upgrade_gated_timelock() public {
    (Pool implB,) = _compatImpl();
    vm.startPrank(OWNER);
    factory.requestReferenceUpgrade(address(implB));
    vm.expectRevert(
      abi.encodeWithSelector(
        Err.PendingTimelock.selector, uint48(block.timestamp + factory.UPGRADE_TIMELOCK())
      )
    );
    factory.executeReferenceUpgrade();
    vm.stopPrank();
  }

  /// @notice fix #2: requestReferenceUpgrade rejects an impl whose baked wiring diverges from the live
  ///         fleet — a mismatched AC/admin/flash would brick every pool atomically on the beacon swap.
  function test_upgrade_compat_reverts_on_wiring_mismatch() public {
    // Wrong flash immutable.
    PoolAux badFlashAux = new PoolAux(address(ac), address(admin), address(flashB));
    Pool badFlash = new Pool(address(ac), address(admin), address(flashB), address(badFlashAux));
    vm.prank(OWNER);
    vm.expectRevert(Err.BadConfig.selector);
    factory.requestReferenceUpgrade(address(badFlash));

    // Wrong admin immutable.
    Admin admin2 = new Admin(address(ac));
    PoolAux badAdminAux = new PoolAux(address(ac), address(admin2), address(flashA));
    Pool badAdmin = new Pool(address(ac), address(admin2), address(flashA), address(badAdminAux));
    vm.prank(OWNER);
    vm.expectRevert(Err.BadConfig.selector);
    factory.requestReferenceUpgrade(address(badAdmin));

    // Wrong AC immutable.
    MockAC ac2 = new MockAC(OWNER);
    Admin admin3 = new Admin(address(ac2));
    PoolAux aux3 = new PoolAux(address(ac2), address(admin3), address(flashA));
    Pool badAC = new Pool(address(ac2), address(admin3), address(flashA), address(aux3));
    vm.prank(OWNER);
    vm.expectRevert(Err.BadConfig.selector);
    factory.requestReferenceUpgrade(address(badAC));
  }

  /// @notice Pool rejects a codeless dispatcher before it can become an implementation.
  function test_upgrade_compat_reverts_on_codeless_poolaux() public {
    address eoaAux = address(0xE0A);
    vm.expectRevert(Err.NotCode.selector);
    new Pool(address(ac), address(admin), address(flashA), eoaAux);
  }

  /// @notice Defense in depth: the factory rejects a candidate whose direct wiring matches but
  /// whose nested dispatcher points at a different flash authority.
  function test_upgrade_compat_reverts_on_nested_poolaux_mismatch() public {
    PoolAux badNestedAux = new PoolAux(address(ac), address(admin), address(flashB));
    MockPoolImplementationWiring candidate = new MockPoolImplementationWiring(
      address(ac), address(admin), address(flashA), address(badNestedAux)
    );
    vm.prank(OWNER);
    vm.expectRevert(Err.BadConfig.selector);
    factory.requestReferenceUpgrade(address(candidate));
  }

  /// @notice Deployment wiring cannot turn an EOA into the flash/admin authority, and Admin must
  /// be governed by the same AccessControl singleton as the Pool fleet.
  function test_constructors_reject_codeless_and_cross_ac_authorities() public {
    address eoa = address(0xE0A);
    vm.expectRevert(Err.NotCode.selector);
    new PoolAux(address(ac), address(admin), eoa);

    MockPoolImplementationWiring eoaFlashAux =
      new MockPoolImplementationWiring(address(ac), address(admin), eoa, address(1));
    vm.expectRevert(Err.NotCode.selector);
    new Pool(address(ac), address(admin), eoa, address(eoaFlashAux));

    MockAC otherAC = new MockAC(OWNER);
    Admin crossAcAdmin = new Admin(address(otherAC));
    vm.expectRevert(Err.BadConfig.selector);
    new PoolAux(address(ac), address(crossAcAdmin), address(flashA));

    MockPoolImplementationWiring crossAcAux = new MockPoolImplementationWiring(
      address(ac), address(crossAcAdmin), address(flashA), address(1)
    );
    vm.expectRevert(Err.BadConfig.selector);
    new Pool(address(ac), address(crossAcAdmin), address(flashA), address(crossAcAux));
  }

  /// @notice Factory validation repeats the authority checks for arbitrary future implementations.
  function test_upgrade_rejects_codeless_flash_and_cross_ac_admin() public {
    address eoa = address(0xE0A);
    MockPoolImplementationWiring eoaAux =
      new MockPoolImplementationWiring(address(ac), address(admin), eoa, address(1));
    MockPoolImplementationWiring eoaFlashCandidate =
      new MockPoolImplementationWiring(address(ac), address(admin), eoa, address(eoaAux));
    vm.prank(OWNER);
    vm.expectRevert(Err.BadConfig.selector);
    factory.requestReferenceUpgrade(address(eoaFlashCandidate));

    MockAC otherAC = new MockAC(OWNER);
    Admin crossAcAdmin = new Admin(address(otherAC));
    MockPoolImplementationWiring crossAcAux = new MockPoolImplementationWiring(
      address(ac), address(crossAcAdmin), address(flashA), address(1)
    );
    MockPoolImplementationWiring crossAcCandidate = new MockPoolImplementationWiring(
      address(ac), address(crossAcAdmin), address(flashA), address(crossAcAux)
    );
    vm.prank(OWNER);
    vm.expectRevert(Err.BadConfig.selector);
    factory.requestReferenceUpgrade(address(crossAcCandidate));
  }

  /// @notice fix #1: a guardian (AC.isGuardian) can veto a pending fleet upgrade during the timelock,
  ///         even though request/cancel are otherwise the same (owner) authority.
  function test_guardian_cancel_upgrade() public {
    ac.setGuardian(GUARDIAN, true);
    (Pool implB,) = _compatImpl();
    vm.prank(OWNER);
    factory.requestReferenceUpgrade(address(implB));
    assertEq(factory.pendingReferencePool(), address(implB), "pending set");

    // Non-guardian cannot cancel.
    vm.expectRevert(Err.NotAuth.selector);
    factory.cancelReferenceUpgrade();

    vm.prank(GUARDIAN);
    factory.cancelReferenceUpgrade();
    assertEq(factory.pendingReferencePool(), address(0), "pending cleared");
    assertEq(factory.upgradeTimelock(), 0, "timelock cleared");
  }

  /// @notice fix #3 (LOW-11): a matured pending upgrade expires SC.GRACE_PERIOD (7d) after its eta and
  ///         can no longer be executed — it must be re-requested. Inside the window it still executes.
  function test_upgrade_expires_after_grace() public {
    (Pool implB,) = _compatImpl();
    vm.prank(OWNER);
    factory.requestReferenceUpgrade(address(implB));
    vm.warp(block.timestamp + factory.UPGRADE_TIMELOCK() + 7 days + 1); // past eta + grace
    vm.prank(OWNER);
    vm.expectRevert(Err.Expired.selector);
    factory.executeReferenceUpgrade();

    // Still executable INSIDE the grace window.
    vm.prank(OWNER);
    factory.cancelReferenceUpgrade();
    vm.prank(OWNER);
    factory.requestReferenceUpgrade(address(implB));
    vm.warp(block.timestamp + factory.UPGRADE_TIMELOCK() + 7 days - 1);
    vm.prank(OWNER);
    factory.executeReferenceUpgrade();
    assertEq(factory.referencePool(), address(implB), "executed within grace");
  }
}
