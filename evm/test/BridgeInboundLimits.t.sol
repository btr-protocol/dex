// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test} from "forge-std/Test.sol";
import {Bridge} from "@btr-shared/Bridge.sol";
import {IBridge} from "@btr-shared/interfaces/IBridge.sol";
import {Maths as M} from "../src/libraries/Maths.sol";
import {MockAC} from "./fixtures/BaseTestSetup.sol";

/// @title BridgeInboundLimitsTest
/// @notice Inbound day rollover (shared helper) + inbound bucket decimals coherent w/ outbound
///         logic + view. Tested through the public storage view + setTokenConfig +
///         getRemainingLimits surface (no LZ mock needed).
contract BridgeInboundLimitsTest is Test {
    Bridge bridge;
    MockAC ac;

    function setUp() public {
        ac = new MockAC(address(this));
        bridge = new Bridge(address(0xDEAD), address(ac));
        bridge.initialize();
    }

    /// @notice R11: getRemainingLimits decodes inbound bucket via b64Decimals(limitOutB64).
    ///         At non-18 decimals, inbound view must equal `(limit * inRatio / 100) - bridgedIn`.
    function test_R11_inbound_view_decimals_coherent_at_6_decimals() public {
        address token = address(0x1111);
        uint256 limit = 1_000_000_000;     // raw, 6-decimal token (1e9)
        uint8   decimals = 6;
        uint8   inRatio = 50;              // 50% of out
        bridge.setTokenConfig(token, limit, decimals, inRatio, false);

        (uint256 out, uint256 inb) = bridge.getRemainingLimits(token);
        assertEq(out, limit, "outbound = full limit");
        assertEq(inb, (limit * inRatio) / 100, "inbound = 50% of limit at 6dp");
    }

    /// @notice R11 / unlimited flag: getRemainingLimits returns max for unlimited tokens.
    function test_R11_unlimited_token_view() public {
        address token = address(0x3333);
        bridge.setTokenConfig(token, 0, 0, 0, true);
        (uint256 out, uint256 inb) = bridge.getRemainingLimits(token);
        assertEq(out, type(uint256).max, "unlimited out");
        assertEq(inb, type(uint256).max, "unlimited in");
    }

    /// @notice R11: isBridgeable view reflects supported + paused flags.
    function test_R11_isBridgeable_paused_flag() public {
        address token = address(0x5555);
        bridge.setTokenConfig(token, 1_000e18, 18, 100, false);
        assertTrue(bridge.isBridgeable(token), "supported & not paused");
        bridge.pauseToken(token, true);
        assertFalse(bridge.isBridgeable(token), "paused");
        bridge.pauseToken(token, false);
        assertTrue(bridge.isBridgeable(token), "unpaused");
    }

    /// @notice R11: setTokenConfig duplicate revert.
    function test_R11_duplicate_setTokenConfig_reverts() public {
        address token = address(0x4444);
        bridge.setTokenConfig(token, 1_000e18, 18, 100, false);
        vm.expectRevert();
        bridge.setTokenConfig(token, 2_000e18, 18, 100, false);
    }

    /// @notice R10/R11: After day rollover, both inbound + outbound remaining-limits return to fresh.
    ///         (View-side virtualization; logic-side rollover is exercised by inbound LZ flow which
    ///         requires an LZ_ENDPOINT mock -covered separately upstream.)
    function test_R10_view_rollover_resets_buckets() public {
        address token = address(0x2222);
        bridge.setTokenConfig(token, 1_000e18, 18, 100, false);

        // Pre-rollover: full limit available.
        (uint256 out0, uint256 in0) = bridge.getRemainingLimits(token);
        assertEq(out0, 1_000e18, "out fresh");
        assertEq(in0, 1_000e18, "in fresh");

        // Force-write bridgedInB64 to a non-zero value at "today" → simulates partial use.
        // TokenConfig packed slot: limitOutB64 (64) | bridgedOutB64 (64) | bridgedInB64 (64) |
        // day (16) | inRatio (8) | flags (8). Single 32-byte slot.
        // Track-B Phase-1b: Bridge storage = `_initialized` (slot 0) + `tokenConfigs` (slot 1).
        // mapping(address => TokenConfig) at slot 1. Access via keccak256.
        bytes32 slot = keccak256(abi.encode(token, uint256(1)));
        bytes32 cur = vm.load(address(bridge), slot);
        // Encode bridgedInB64 = encodeB64(500e18, 18) and inject; preserve other fields.
        uint64 bIn = M.encodeB64(500e18, 18);
        // Mask out old bridgedInB64 (bits 128..192) and set new value.
        uint256 mask = ~(uint256(type(uint64).max) << 128);
        uint256 newPacked = (uint256(cur) & mask) | (uint256(bIn) << 128);
        vm.store(address(bridge), slot, bytes32(newPacked));

        // Sanity: view sees half-used inbound on same day.
        (, uint256 inUsed) = bridge.getRemainingLimits(token);
        assertEq(inUsed, 500e18, "in half consumed today");

        // Warp past midnight → view virtualizes rollover to fresh.
        vm.warp(block.timestamp + 1 days + 1);
        (, uint256 inFresh) = bridge.getRemainingLimits(token);
        assertEq(inFresh, 1_000e18, "in restored after rollover");
    }
}
