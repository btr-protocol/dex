// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Treasury} from "../../src/Treasury.sol";
import {Bridge} from "../../src/Bridge.sol";
import {Router} from "../../src/Router.sol";
import {GovToken} from "../../src/tokens/GovToken.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @title UUPSTimelockTest
/// @notice Phase 42H.D · Round 4 (G14) -generic UUPS-timelock parametrized harness.
///         Covers Treasury / Bridge / Router (3 × 6 = 18 tests) for: owner-gating on request,
///         pre-delay execute revert, post-delay execute success, cancel clears state,
///         double-request revert, non-owner execute revert.
abstract contract UUPSTimelockHarness is Test {
    address internal constant OWNER  = address(0xA11CE);
    address internal constant ATTACK = address(0xBADBAD);

    address internal proxy;
    address internal newImpl;

    uint48 internal immutable UPGRADE_TL = SC.UPGRADE_TIMELOCK;

    /// @notice Subclasses deploy a UUPS proxy + return (proxyAddr, freshNewImplAddr).
    function _deployProxyAndImpl() internal virtual returns (address, address);

    /// @notice Subclasses dispatch the 3 upgrade entrypoints to the right contract type.
    function _requestUpgrade(address caller, address impl) internal virtual;
    function _executeUpgrade(address caller) internal virtual;
    function _cancelUpgrade(address caller) internal virtual;
    function _hasPendingUpgrade() internal view virtual returns (bool);

    function setUp() public virtual {
        (proxy, newImpl) = _deployProxyAndImpl();
    }

    // ─── 1. requestUpgrade gates onlyOwner ───
    function test_requestUpgrade_onlyOwner() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        _requestUpgrade(ATTACK, newImpl);
        // owner path succeeds
        _requestUpgrade(OWNER, newImpl);
        assertTrue(_hasPendingUpgrade(), "pending should be set");
    }

    // ─── 2. executeUpgrade reverts before delay ───
    function test_executeUpgrade_revertsBeforeDelay() public {
        _requestUpgrade(OWNER, newImpl);
        // ETA in future → TL.validate must revert.
        vm.expectRevert();
        _executeUpgrade(OWNER);
    }

    // ─── 3. executeUpgrade actually swaps the implementation post-delay ───
    /// @dev G18 (Round 5) fix verification: `executeUpgrade` arms a transient auth flag,
    ///      `this.upgradeToAndCall` self-calls into the proxy, `_authorizeUpgrade` reads
    ///      the flag, and the ERC1967 implementation slot is updated to `newImpl`.
    ///      This test asserts the impl slot reflects the new impl, that pending state
    ///      clears, and the upgrade is genuinely live (not just timelock-validated).
    bytes32 internal constant _ERC1967_IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    function test_executeUpgrade_succeedsAfterDelay() public {
        _requestUpgrade(OWNER, newImpl);
        vm.warp(block.timestamp + UPGRADE_TL + 1);
        _executeUpgrade(OWNER);
        // Impl slot must be the freshly deployed `newImpl`.
        bytes32 raw = vm.load(proxy, _ERC1967_IMPL_SLOT);
        address implAddr = address(uint160(uint256(raw)));
        assertEq(implAddr, newImpl, "impl slot updated to newImpl");
        // Pending state cleared by executeUpgrade pre-self-call.
        assertFalse(_hasPendingUpgrade(), "pending cleared post-execute");
    }

    // ─── 4. cancelUpgrade clears state ───
    function test_cancelUpgrade_clearsState() public {
        _requestUpgrade(OWNER, newImpl);
        assertTrue(_hasPendingUpgrade(), "pending pre-cancel");
        _cancelUpgrade(OWNER);
        assertFalse(_hasPendingUpgrade(), "pending post-cancel");
        // After cancel, fresh request must work.
        _requestUpgrade(OWNER, newImpl);
        assertTrue(_hasPendingUpgrade(), "post-cancel re-request");
    }

    // ─── 5. double-request reverts ───
    function test_doubleRequest_reverts() public {
        _requestUpgrade(OWNER, newImpl);
        vm.expectRevert();
        _requestUpgrade(OWNER, newImpl);
    }

    // ─── 6. non-owner cannot execute ───
    function test_executeUpgrade_nonOwnerReverts() public {
        _requestUpgrade(OWNER, newImpl);
        vm.warp(block.timestamp + UPGRADE_TL + 1);
        vm.expectRevert(Ownable.Unauthorized.selector);
        _executeUpgrade(ATTACK);
    }
}

// ─────────────────────────────────────────────────────────────────────
// Treasury concrete harness
// ─────────────────────────────────────────────────────────────────────
contract UUPSTimelockTreasuryTest is UUPSTimelockHarness {
    function _deployProxyAndImpl() internal override returns (address, address) {
        GovToken gov = new GovToken(address(this), "G", "G");
        Treasury impl = new Treasury(address(gov));
        address p = LibClone.deployERC1967(address(impl));
        Treasury(payable(p)).initialize(OWNER);
        Treasury fresh = new Treasury(address(gov));
        return (p, address(fresh));
    }
    function _requestUpgrade(address caller, address impl) internal override {
        vm.prank(caller);
        Treasury(payable(proxy)).requestUpgrade(impl);
    }
    function _executeUpgrade(address caller) internal override {
        vm.prank(caller);
        Treasury(payable(proxy)).executeUpgrade();
    }
    function _cancelUpgrade(address caller) internal override {
        vm.prank(caller);
        Treasury(payable(proxy)).cancelUpgrade();
    }
    function _hasPendingUpgrade() internal view override returns (bool) {
        return Treasury(payable(proxy)).pendingUpgrade() != bytes32(0);
    }
}

// ─────────────────────────────────────────────────────────────────────
// Bridge concrete harness
// ─────────────────────────────────────────────────────────────────────
contract UUPSTimelockBridgeTest is UUPSTimelockHarness {
    function _deployProxyAndImpl() internal override returns (address, address) {
        Bridge impl = new Bridge(address(0xDEAD));
        address p = LibClone.deployERC1967(address(impl));
        Bridge(payable(p)).initialize(OWNER);
        Bridge fresh = new Bridge(address(0xDEAD));
        return (p, address(fresh));
    }
    function _requestUpgrade(address caller, address impl) internal override {
        vm.prank(caller);
        Bridge(payable(proxy)).requestUpgrade(impl);
    }
    function _executeUpgrade(address caller) internal override {
        vm.prank(caller);
        Bridge(payable(proxy)).executeUpgrade();
    }
    function _cancelUpgrade(address caller) internal override {
        vm.prank(caller);
        Bridge(payable(proxy)).cancelUpgrade();
    }
    function _hasPendingUpgrade() internal view override returns (bool) {
        return Bridge(payable(proxy)).pendingUpgrade() != bytes32(0);
    }
}

// ─────────────────────────────────────────────────────────────────────
// Router concrete harness
// ─────────────────────────────────────────────────────────────────────
contract UUPSTimelockRouterTest is UUPSTimelockHarness {
    function _deployProxyAndImpl() internal override returns (address, address) {
        Router impl = new Router();
        address p = LibClone.deployERC1967(address(impl));
        Router(payable(p)).initialize(OWNER, address(0xF1));
        Router fresh = new Router();
        return (p, address(fresh));
    }
    function _requestUpgrade(address caller, address impl) internal override {
        vm.prank(caller);
        Router(payable(proxy)).requestUpgrade(impl);
    }
    function _executeUpgrade(address caller) internal override {
        vm.prank(caller);
        Router(payable(proxy)).executeUpgrade();
    }
    function _cancelUpgrade(address caller) internal override {
        vm.prank(caller);
        Router(payable(proxy)).cancelUpgrade();
    }
    function _hasPendingUpgrade() internal view override returns (bool) {
        return Router(payable(proxy)).pendingUpgradeOp() != 0;
    }
}
