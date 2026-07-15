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
import {Ownable} from "solady/auth/Ownable.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {UpgradeableBeacon} from "solady/utils/UpgradeableBeacon.sol";
import {MockAC} from "./fixtures/BaseTestSetup.sol";

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

    function _create(address baseTok, address other) internal returns (address pool, address[] memory toks) {
        toks = new address[](2);
        toks[0] = baseTok;
        toks[1] = other;
        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 25, flashFeeBps: 100, _pad: pad});
        bytes memory initdata =
            abi.encodeWithSelector(Pool.initialize.selector, baseTok, address(0xCAFE), fp);
        pool = factory.createPool(baseTok, toks, initdata);
    }

    /// @notice A single beacon.upgradeTo swaps the impl for every live pool — proven via the
    ///         impl-baked immutable `flash()` (read through delegatecall) flipping for all pools.
    function test_beacon_upgrade_atomic_all_pools() public {
        (address p1,) = _create(address(base), address(quote));
        (address p2,) = _create(address(quote), address(base));
        assertTrue(p1 != p2, "distinct proxies");
        assertEq(Pool(payable(p1)).flash(), address(flashA), "p1 pre-upgrade impl");
        assertEq(Pool(payable(p2)).flash(), address(flashA), "p2 pre-upgrade impl");

        // New impl carries a different `flash` immutable — observable proof of the swap.
        Pool implB = new Pool(address(ac), address(admin), address(flashB), address(poolAux));

        vm.prank(OWNER);
        factory.requestReferenceUpgrade(address(implB));
        vm.warp(block.timestamp + factory.UPGRADE_TIMELOCK());
        vm.prank(OWNER);
        factory.executeReferenceUpgrade();

        // Fleet-wide, atomic: both pre-existing pools now resolve to implB's immutable.
        assertEq(Pool(payable(p1)).flash(), address(flashB), "p1 post-upgrade impl");
        assertEq(Pool(payable(p2)).flash(), address(flashB), "p2 post-upgrade impl");
        assertEq(factory.referencePool(), address(implB), "referencePool mirror");
        assertEq(UpgradeableBeacon(factory.beacon()).implementation(), address(implB), "beacon impl");
    }

    /// @notice Off-chain predicted address (beacon-proxy init-code-hash) == on-chain deployed.
    function test_predict_matches_deployed() public {
        address[] memory toks = new address[](2);
        toks[0] = address(base);
        toks[1] = address(quote);
        bytes32 salt =
            keccak256(abi.encodePacked(address(this), address(base), keccak256(abi.encode(toks)), block.chainid));
        address predicted =
            LibClone.predictDeterministicAddressERC1967BeaconProxy(factory.beacon(), salt, address(factory));
        (address deployed,) = _create(address(base), address(quote));
        assertEq(deployed, predicted, "predict == deployed");
    }

    /// @notice Reference upgrade is owner-gated (AC.owner()).
    function test_upgrade_gated_owner() public {
        Pool implB = new Pool(address(ac), address(admin), address(flashB), address(poolAux));
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.requestReferenceUpgrade(address(implB)); // caller != AC.owner()
    }

    /// @notice Execution before the 7d timelock elapses reverts.
    function test_upgrade_gated_timelock() public {
        Pool implB = new Pool(address(ac), address(admin), address(flashB), address(poolAux));
        vm.startPrank(OWNER);
        factory.requestReferenceUpgrade(address(implB));
        vm.expectRevert(abi.encodeWithSelector(Err.PendingTimelock.selector, uint48(block.timestamp + factory.UPGRADE_TIMELOCK())));
        factory.executeReferenceUpgrade();
        vm.stopPrank();
    }
}
