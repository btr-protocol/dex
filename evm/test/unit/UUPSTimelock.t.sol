// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Treasury} from "@btr-shared/Treasury.sol";
import {Bridge} from "@btr-shared/Bridge.sol";
import {Router} from "../../src/Router.sol";
import {GovToken} from "@btr-shared/tokens/GovToken.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Err} from "@btr-shared/Errors.sol";
import {MockAC} from "../fixtures/BaseTestSetup.sol";

/// @title UUPSTimelockTest
/// @notice Phase 42H.D · Round 4 (G14) + Track-B Phase-1b (UUPS-AC) -generic UUPS-timelock
///         parametrized harness covering Treasury / Bridge / Router (3 × 6 = 18 tests).
abstract contract UUPSTimelockHarness is Test {
    address internal constant OWNER  = address(0xA11CE);
    address internal constant ATTACK = address(0xBADBAD);

    address internal proxy;
    address internal newImpl;

    uint48 internal immutable UPGRADE_TL = SC.UPGRADE_TIMELOCK;

    function _deployProxyAndImpl() internal virtual returns (address, address);
    function _requestUpgrade(address caller, address impl) internal virtual;
    function _executeUpgrade(address caller) internal virtual;
    function _cancelUpgrade(address caller) internal virtual;
    function _hasPendingUpgrade() internal view virtual returns (bool);

    function setUp() public virtual {
        (proxy, newImpl) = _deployProxyAndImpl();
    }

    function test_requestUpgrade_onlyOwner() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        _requestUpgrade(ATTACK, newImpl);
        _requestUpgrade(OWNER, newImpl);
        assertTrue(_hasPendingUpgrade(), "pending should be set");
    }

    function test_executeUpgrade_revertsBeforeDelay() public {
        _requestUpgrade(OWNER, newImpl);
        vm.expectRevert();
        _executeUpgrade(OWNER);
    }

    bytes32 internal constant _ERC1967_IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    function test_executeUpgrade_succeedsAfterDelay() public {
        _requestUpgrade(OWNER, newImpl);
        vm.warp(block.timestamp + UPGRADE_TL + 1);
        _executeUpgrade(OWNER);
        bytes32 raw = vm.load(proxy, _ERC1967_IMPL_SLOT);
        address implAddr = address(uint160(uint256(raw)));
        assertEq(implAddr, newImpl, "impl slot updated to newImpl");
        assertFalse(_hasPendingUpgrade(), "pending cleared post-execute");
    }

    function test_cancelUpgrade_clearsState() public {
        _requestUpgrade(OWNER, newImpl);
        assertTrue(_hasPendingUpgrade(), "pending pre-cancel");
        _cancelUpgrade(OWNER);
        assertFalse(_hasPendingUpgrade(), "pending post-cancel");
        _requestUpgrade(OWNER, newImpl);
        assertTrue(_hasPendingUpgrade(), "post-cancel re-request");
    }

    function test_doubleRequest_reverts() public {
        _requestUpgrade(OWNER, newImpl);
        vm.expectRevert();
        _requestUpgrade(OWNER, newImpl);
    }

    function test_executeUpgrade_nonOwnerReverts() public {
        _requestUpgrade(OWNER, newImpl);
        vm.warp(block.timestamp + UPGRADE_TL + 1);
        vm.expectRevert(Ownable.Unauthorized.selector);
        _executeUpgrade(ATTACK);
    }
}

contract UUPSTimelockTreasuryTest is UUPSTimelockHarness {
    MockAC internal ac;
    function _deployProxyAndImpl() internal override returns (address, address) {
        ac = new MockAC(OWNER);
        Treasury impl = new Treasury(address(ac));
        address p = LibClone.deployERC1967(address(impl));
        GovToken gov = new GovToken(p, "G", "G");
        Treasury(payable(p)).initialize(address(gov));
        Treasury fresh = new Treasury(address(ac));
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

contract UUPSTimelockBridgeTest is UUPSTimelockHarness {
    MockAC internal ac;
    function _deployProxyAndImpl() internal override returns (address, address) {
        ac = new MockAC(OWNER);
        Bridge impl = new Bridge(address(0xDEAD), address(ac));
        address p = LibClone.deployERC1967(address(impl));
        Bridge(payable(p)).initialize();
        Bridge fresh = new Bridge(address(0xDEAD), address(ac));
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

contract UUPSTimelockRouterTest is UUPSTimelockHarness {
    MockAC internal ac;
    function _deployProxyAndImpl() internal override returns (address, address) {
        ac = new MockAC(OWNER);
        Router impl = new Router(address(ac));
        address p = LibClone.deployERC1967(address(impl));
        Router(payable(p)).initialize(address(0xF1));
        Router fresh = new Router(address(ac));
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
