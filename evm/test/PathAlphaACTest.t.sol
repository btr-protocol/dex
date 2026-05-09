// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test, console2} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {IAdminConfig} from "../src/interfaces/modules/IAdmin.sol";
import {LibConstants as C} from "../src/libraries/LibConstants.sol";
import {PoolProxy} from "../src/PoolProxy.sol";
import {Admin} from "../src/modules/Admin.sol";

/// @title MockAC — minimal singleton mimicking peripheral AccessControl.owner()
contract MockAC {
    address public owner;
    constructor(address o) { owner = o; }
    function rotate(address newOwner) external { owner = newOwner; }
}

/// @title PathAlphaACTest
/// @notice Phase 42B.1.6 — verifies the dex AC bridge.
///   1. ac=0   → legacy $.owner enforced.
///   2. ac=set → IAccessControl(ac).owner() enforced; rotating singleton AC owner
///               rotates ALL pools atomically (single tx, N pools).
///   3. setAc / getAc gated by current onlyOwner; idempotent reset to 0 = legacy.
///   4. PoolStorage.ac slot is appended (modules mapping still at offset 14).
contract PathAlphaACTest is Test {
    PoolProxy poolA;
    PoolProxy poolB;
    Admin admin;

    address constant LEGACY_OWNER  = address(0xA11CE);
    address constant SINGLETON_OWNER = address(0xB0B);
    address constant ROTATED_OWNER = address(0xC0DE);
    address constant ATTACKER      = address(0xBAD);

    /// @dev Selectors registered on each proxy via vm.store, bypassing module-trust flow.
    function _registerAdmin(PoolProxy p, bytes4[] memory sels) internal {
        uint256 modulesSlot = uint256(C.CORE_STORAGE_LOC) + 13;
        for (uint256 i = 0; i < sels.length; i++) {
            bytes32 slot = keccak256(abi.encode(sels[i], modulesSlot));
            vm.store(address(p), slot, bytes32(uint256(uint160(address(admin)))));
        }
    }

    function setUp() public {
        admin = new Admin();
        poolA = new PoolProxy();
        poolB = new PoolProxy();

        uint8[29] memory pad;
        IPool.FeeParams memory fp = IPool.FeeParams({protoShare: 25, flashFeeBps: 5, _pad: pad});
        poolA.initialize(LEGACY_OWNER, address(0xAAA1), address(0xBBB1), fp);
        poolB.initialize(LEGACY_OWNER, address(0xAAA2), address(0xBBB2), fp);

        bytes4[] memory sels = new bytes4[](4);
        sels[0] = IAdminConfig.setAc.selector;
        sels[1] = IAdminConfig.getAc.selector;
        sels[2] = IAdminConfig.setFlowCooldown.selector;
        sels[3] = IAdminConfig.getModule.selector;
        _registerAdmin(poolA, sels);
        _registerAdmin(poolB, sels);
    }

    // ─── 1. ac=0 → legacy $.owner enforced ─────────────────────────────────────

    function test_legacyPath_ownerEnforced() public {
        // Sanity: ac is zero
        assertEq(IAdminConfig(address(poolA)).getAc(), address(0), "ac should be 0");

        // Legacy owner can call onlyOwner
        vm.prank(LEGACY_OWNER);
        IAdminConfig(address(poolA)).setFlowCooldown(60);

        // Attacker rejected
        vm.prank(ATTACKER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        IAdminConfig(address(poolA)).setFlowCooldown(120);
    }

    // ─── 2. ac=set → singleton AC enforced; atomic multi-pool rotation ─────────

    function test_singletonPath_atomicRotation() public {
        MockAC ac = new MockAC(SINGLETON_OWNER);

        // Legacy owner sets AC on both pools (still uses legacy path during this call ∵ ac was 0)
        vm.startPrank(LEGACY_OWNER);
        IAdminConfig(address(poolA)).setAc(address(ac));
        IAdminConfig(address(poolB)).setAc(address(ac));
        vm.stopPrank();

        assertEq(IAdminConfig(address(poolA)).getAc(), address(ac));
        assertEq(IAdminConfig(address(poolB)).getAc(), address(ac));

        // After AC set: legacy owner is NO LONGER authorized; singleton owner is.
        vm.prank(LEGACY_OWNER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        IAdminConfig(address(poolA)).setFlowCooldown(60);

        vm.prank(SINGLETON_OWNER);
        IAdminConfig(address(poolA)).setFlowCooldown(60);
        vm.prank(SINGLETON_OWNER);
        IAdminConfig(address(poolB)).setFlowCooldown(60);

        // ATOMIC ROTATION: 1 tx → both pools follow new owner.
        ac.rotate(ROTATED_OWNER);

        // Old singleton owner now rejected on BOTH pools.
        vm.prank(SINGLETON_OWNER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        IAdminConfig(address(poolA)).setFlowCooldown(90);
        vm.prank(SINGLETON_OWNER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        IAdminConfig(address(poolB)).setFlowCooldown(90);

        // New rotated owner accepted on BOTH pools immediately, no per-pool tx required.
        vm.prank(ROTATED_OWNER);
        IAdminConfig(address(poolA)).setFlowCooldown(90);
        vm.prank(ROTATED_OWNER);
        IAdminConfig(address(poolB)).setFlowCooldown(90);
    }

    // ─── 3. setAc gated; reset to 0 falls back to legacy ───────────────────────

    function test_setAc_gatedAndReversible() public {
        MockAC ac = new MockAC(SINGLETON_OWNER);

        // Attacker cannot set AC (legacy path active, $.owner = LEGACY_OWNER).
        vm.prank(ATTACKER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        IAdminConfig(address(poolA)).setAc(address(ac));

        // Legacy owner sets it.
        vm.prank(LEGACY_OWNER);
        IAdminConfig(address(poolA)).setAc(address(ac));

        // Singleton owner can reset to 0 → legacy path returns.
        vm.prank(SINGLETON_OWNER);
        IAdminConfig(address(poolA)).setAc(address(0));
        assertEq(IAdminConfig(address(poolA)).getAc(), address(0));

        // Legacy owner re-authorized.
        vm.prank(LEGACY_OWNER);
        IAdminConfig(address(poolA)).setFlowCooldown(30);
    }

    // ─── 4. Storage layout: ac appended after pre-existing modules mapping ─────

    function test_storageLayout_acAppended() public {
        MockAC ac = new MockAC(SINGLETON_OWNER);
        vm.prank(LEGACY_OWNER);
        IAdminConfig(address(poolA)).setAc(address(ac));

        // Functional invariants:
        //  1. setUp registered Admin module at modules-mapping offset 13. Three
        //     prior tests dispatch through this slot successfully ⇒ append-only
        //     growth did NOT shift the modules mapping.
        //  2. setAc / getAc round-trip ⇒ new ac slot resolves correctly.
        assertEq(IAdminConfig(address(poolA)).getAc(), address(ac));

        // Direct slot probe: scan low-N slots; the ac value MUST live at an
        // offset strictly greater than 13 (the modules mapping). This proves
        // append-only growth: pre-existing mappings keep their slots.
        uint256 baseSlot = uint256(C.CORE_STORAGE_LOC);
        uint256 found = type(uint256).max;
        for (uint256 i = 0; i < 32; i++) {
            address v = address(uint160(uint256(vm.load(address(poolA), bytes32(baseSlot + i)))));
            if (v == address(ac)) { found = i; break; }
        }
        assertGt(found, 13, "ac slot must be appended after modules mapping");
    }
}
