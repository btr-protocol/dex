// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Bridge} from "../../src/Bridge.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @title BridgePeerTimelockTest
/// @notice Phase 42H.D · Round 5 (G19 + G20) -coverage for `requestSetPeer` /
///         `executeSetPeer` / typed cancels (`cancelSetPeer`, `cancelConfigChange`).
contract BridgePeerTimelockTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant ATTACK = address(0xBADBAD);
    uint32 internal constant DST_EID = 1;
    bytes32 internal constant PEER = bytes32(uint256(0xBEEF));

    Bridge internal bridge;

    function setUp() public {
        Bridge impl = new Bridge(address(0xDEAD));
        address p = LibClone.deployERC1967(address(impl));
        Bridge(payable(p)).initialize(OWNER);
        bridge = Bridge(payable(p));
    }

    // ─── G19: requestSetPeer / executeSetPeer ───

    function test_requestSetPeer_onlyOwner() public {
        vm.prank(ATTACK);
        vm.expectRevert(Ownable.Unauthorized.selector);
        bridge.requestSetPeer(DST_EID, PEER);
    }

    function test_executeSetPeer_revertsBeforeDelay() public {
        vm.prank(OWNER);
        bridge.requestSetPeer(DST_EID, PEER);
        vm.prank(OWNER);
        vm.expectRevert();
        bridge.executeSetPeer(DST_EID);
    }

    function test_executeSetPeer_succeedsAfterDelay() public {
        vm.prank(OWNER);
        bridge.requestSetPeer(DST_EID, PEER);
        vm.warp(block.timestamp + SC.BASE_TIMELOCK + 1);
        vm.prank(OWNER);
        bridge.executeSetPeer(DST_EID);
        assertEq(bridge.peers(DST_EID), PEER, "peer set");
        bytes32 id = keccak256(abi.encode(IBridge.OpType.PeerUpdate, DST_EID));
        assertEq(bridge.pendingOps(id), 0, "pending cleared");
    }

    function test_doubleRequestSetPeer_reverts() public {
        vm.prank(OWNER);
        bridge.requestSetPeer(DST_EID, PEER);
        vm.prank(OWNER);
        vm.expectRevert();
        bridge.requestSetPeer(DST_EID, PEER);
    }

    // ─── G20: typed cancels ───

    function test_cancelSetPeer_clearsState() public {
        vm.prank(OWNER);
        bridge.requestSetPeer(DST_EID, PEER);
        bytes32 id = keccak256(abi.encode(IBridge.OpType.PeerUpdate, DST_EID));
        assertTrue(bridge.pendingOps(id) != 0, "pending pre-cancel");
        vm.prank(OWNER);
        bridge.cancelSetPeer(DST_EID);
        assertEq(bridge.pendingOps(id), 0, "pending post-cancel");
        // Re-request must succeed.
        vm.prank(OWNER);
        bridge.requestSetPeer(DST_EID, PEER);
        assertTrue(bridge.pendingOps(id) != 0, "re-request ok");
    }

    function test_cancelSetPeer_onlyOwner() public {
        vm.prank(OWNER);
        bridge.requestSetPeer(DST_EID, PEER);
        vm.prank(ATTACK);
        vm.expectRevert(Ownable.Unauthorized.selector);
        bridge.cancelSetPeer(DST_EID);
    }

    function test_cancelSetPeer_noPending_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(Err.InvalidState.selector);
        bridge.cancelSetPeer(DST_EID);
    }

    function test_cancelConfigChange_noPending_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(Err.InvalidState.selector);
        bridge.cancelConfigChange(address(0xC0FFEE));
    }

    /// @dev G20: typed cancels prevent crossing op families. `cancelSetPeer` for an eid
    ///      whose hash collides with no actual PeerUpdate op simply reverts InvalidState
    ///      -caller cannot hand-craft a `bytes32 id` from a different OpType to silently
    ///      delete it (cancelOperation(bytes32) is gone).
    function test_cancelSetPeer_doesNotAffectConfigChange() public {
        // request a config change on token T
        address token = address(0xC0FFEE);
        vm.prank(OWNER);
        bridge.requestConfigChange(token, 1e18, 18, 50, true, true);
        bytes32 cfgId = keccak256(abi.encode(IBridge.OpType.ConfigUpdate, token));
        assertTrue(bridge.pendingOps(cfgId) != 0, "cfg pending pre");
        // cancelSetPeer for a different eid must revert (no peer pending) and not touch cfg.
        vm.prank(OWNER);
        vm.expectRevert(Err.InvalidState.selector);
        bridge.cancelSetPeer(DST_EID);
        assertTrue(bridge.pendingOps(cfgId) != 0, "cfg pending intact");
    }
}
