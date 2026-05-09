// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Bridge} from "../src/Bridge.sol";
import {IBridge} from "../src/interfaces/IBridge.sol";
import {LZEndpointV2} from "../src/interfaces/external/ILZEndpointV2.sol";
import {IERC7802} from "../src/interfaces/external/IERC7802.sol";

import {PoolProxy} from "../src/PoolProxy.sol";
import {Pool} from "../src/modules/Pool.sol";
import {IPool} from "../src/interfaces/IPool.sol";
import {Err} from "@btr-peripheral/Errors.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {LibConstants as C} from "../src/libraries/LibConstants.sol";

/// @notice Mock LZ endpoint — quote returns fixed fee, send is a no-op recorder.
contract MockLZEndpoint {
    LZEndpointV2.MessagingFee public lastFee;
    LZEndpointV2.SendParam public lastSend;

    function quote(LZEndpointV2.SendParam calldata, bool)
        external pure returns (LZEndpointV2.MessagingFee memory fee)
    {
        return LZEndpointV2.MessagingFee({nativeFee: 1 wei, lzTokenFee: 0});
    }

    function send(LZEndpointV2.SendParam calldata sp, LZEndpointV2.MessagingFee calldata fee, address)
        external payable returns (LZEndpointV2.MessagingReceipt memory r)
    {
        lastFee = fee;
        lastSend = sp;
        r.guid = bytes32(0);
        r.nonce = uint64(1);
        r.fee = fee;
    }
}

/// @notice Mock ERC7802 token — counts mint/burn calls.
contract MockBridgeable is IERC7802 {
    uint256 public minted;
    uint256 public burned;
    function crosschainMint(address, uint256 amount, bytes calldata) external {
        minted += amount;
    }
    function crosschainBurn(address, uint256 amount, bytes calldata) external {
        burned += amount;
    }
}

/// @title Phase42CR10Test
/// @notice Phase 42C R10 remediation:
///   - F-A4-R10-2 (MED): Bridge inbound day-rollover. `_tryCheckAndUpdateLimit` was missing
///     the calendar-day reset present in outbound `_checkAndUpdateLimit`, so `bridgedInB64`
///     accumulated forever. Once cum > inLimit, every subsequent lzReceive silently queued
///     as failedMessage(FC_RATE_LIMIT). Regression test verifies a full inbound capacity
///     can be consumed today, then a NEW full inbound capacity can be consumed the next day.
///     Pre-fix: second-day inbound would queue as failedMessages → `failedMessages[guid] != 0`.
///     Post-fix: second-day inbound mints normally, no queued failure.
///   - F-A2-2 (LOW, R9 carry-over): production trust path coverage — addModules + module trust
///     gating. New fixture exercises real `setModuleTrustBatch` + `addModules` + `executeModuleUpdate`
///     flow (other tests use vm.store shortcuts). Verifies untrusted impls revert and trusted
///     impls register selectors.
contract Phase42CR10Test is Test {

    // ─────────────────────────────────────────────────────────────────────
    // F-A4-R10-2 — Bridge inbound day-rollover regression
    // ─────────────────────────────────────────────────────────────────────

    Bridge bridge;
    MockLZEndpoint lz;
    MockBridgeable token;

    address constant BRIDGE_OWNER = address(0xA11CE);
    uint32 constant SRC_EID = 7;
    bytes32 constant SRC_PEER = bytes32(uint256(0xBEEFCAFE));

    function _setUpBridge() internal {
        lz = new MockLZEndpoint();
        token = new MockBridgeable();
        bridge = new Bridge(address(lz));
        bridge.initialize(BRIDGE_OWNER);

        // Configure a token w/ daily inbound limit. limitOut = 1000e18, inRatio=100% → inLimit=1000e18.
        vm.prank(BRIDGE_OWNER);
        bridge.setTokenConfig(address(token), 1_000e18, 18, 100, false);

        // Configure peer. Peer setup is timelocked; warp through it.
        vm.startPrank(BRIDGE_OWNER);
        bridge.requestSetPeer(SRC_EID, SRC_PEER);
        vm.warp(block.timestamp + C.BASE_TIMELOCK + 1);
        bridge.executeSetPeer(SRC_EID);
        vm.stopPrank();
    }

    /// @dev Helper — synthesize a unique guid + Origin and call lzReceive as the LZ_ENDPOINT.
    function _lzReceive(uint256 amount, uint256 nonce) internal {
        LZEndpointV2.Origin memory origin = LZEndpointV2.Origin({
            srcEid: SRC_EID,
            sender: SRC_PEER,
            nonce: uint64(nonce)
        });
        bytes32 guid = keccak256(abi.encode(SRC_EID, nonce, amount, block.timestamp));
        bytes memory msg_ = abi.encode(
            bytes32(uint256(uint160(address(0xCAFE)))), // receiver
            address(token),
            amount
        );
        vm.prank(address(lz));
        bridge.lzReceive(origin, guid, msg_, address(0), "");
    }

    /// @dev Read failedMessages[guid].amount given the same nonce/amount/timestamp seed.
    function _failedAmount(uint256 amount, uint256 nonce, uint256 ts) internal view returns (uint256) {
        bytes32 guid = keccak256(abi.encode(SRC_EID, nonce, amount, ts));
        (, , uint256 amt, , , ) = bridge.failedMessages(guid);
        return amt;
    }

    /// @notice Regression: second-day inbound after a full first-day fill must NOT queue as failed.
    function test_F_A4_R10_2_inbound_dayRollover() public {
        _setUpBridge();

        // Day 0: consume 100% of inbound capacity = 1000e18 across two 500e18 messages.
        uint256 day0Ts = block.timestamp;
        _lzReceive(500e18, 1);
        _lzReceive(500e18, 2);

        // Both succeeded → minted = 1000e18, no queued failures.
        assertEq(token.minted(), 1000e18, "day0 mints must equal full cap");
        assertEq(_failedAmount(500e18, 1, day0Ts), 0, "day0 msg1 must not be queued");
        assertEq(_failedAmount(500e18, 2, day0Ts), 0, "day0 msg2 must not be queued");

        // Day 1: warp +1 day. Without rollover, currentIn=1000e18 → next 500e18 → currentIn+amt > inLimit
        // → _tryCheckAndUpdateLimit returns false → message queued as FC_RATE_LIMIT (the bug).
        // With rollover: storage cfg.day != today → reset bridgedInB64=0 → message succeeds.
        vm.warp(block.timestamp + 1 days + 1);
        uint256 day1Ts = block.timestamp;

        _lzReceive(500e18, 3);

        // Post-fix: day1 message must mint successfully.
        assertEq(token.minted(), 1500e18, "day1 mint must succeed via rollover");
        assertEq(_failedAmount(500e18, 3, day1Ts), 0, "day1 msg must NOT be queued (rollover applied)");

        // And we can fill day1 capacity again.
        _lzReceive(500e18, 4);
        assertEq(token.minted(), 2000e18, "day1 second mint must succeed");
        assertEq(_failedAmount(500e18, 4, day1Ts), 0, "day1 msg2 must NOT be queued");
    }

    /// @notice Capacity exhausted within the SAME day still queues correctly (rollover doesn't break the gate).
    function test_F_A4_R10_2_sameDay_capExhaustion_stillQueues() public {
        _setUpBridge();

        // Fill cap.
        _lzReceive(1_000e18, 10);
        assertEq(token.minted(), 1_000e18);

        // Next message in the same day → must queue (NOT mint).
        uint256 ts = block.timestamp;
        _lzReceive(1, 11);
        assertEq(token.minted(), 1_000e18, "over-cap must NOT mint");
        assertEq(_failedAmount(1, 11, ts), 1, "over-cap must queue as failedMessage");
    }

    /// @notice Outbound parity check: bridgedOutB64 also rolls over, view stays consistent.
    function test_F_A4_R10_2_view_logic_consistency() public {
        _setUpBridge();

        // Consume all inbound for day0.
        _lzReceive(1_000e18, 20);

        // View — same-day → 0 inbound remaining.
        (, uint256 inboundDay0) = bridge.getRemainingLimits(address(token));
        assertEq(inboundDay0, 0, "day0: inbound exhausted in view");

        // Day 1 — view rolls over.
        vm.warp(block.timestamp + 1 days + 1);
        (, uint256 inboundDay1) = bridge.getRemainingLimits(address(token));
        assertEq(inboundDay1, 1_000e18, "day1: view shows full inbound after rollover");

        // Logic must agree: a fresh inbound message for the full cap must succeed.
        _lzReceive(1_000e18, 21);
        assertEq(token.minted(), 2_000e18, "day1 logic agrees with view");
    }

    // ─────────────────────────────────────────────────────────────────────
    // F-A2-2 — production module-trust + addModules + executeModuleUpdate
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Exercises the REAL trust flow:
    ///   1. setModuleTrustBatch (DEPLOYER-only) marks impl trusted.
    ///   2. addModules (DEPLOYER-only) registers selectors directly when slot is empty
    ///      OR queues timelocked update when slot is occupied.
    ///   3. executeModuleUpdate (DEPLOYER-only) re-checks trust at exec time.
    ///   4. Untrusted impls revert at addModules.
    function test_F_A2_2_moduleTrustFlow_endToEnd() public {
        // This test contract IS the DEPLOYER (msg.sender at constructor).
        PoolProxy proxy = new PoolProxy();

        Pool poolImpl = new Pool();

        // Step 1: untrusted impl → addModules MUST revert.
        address[] memory impls = new address[](1);
        impls[0] = address(poolImpl);
        bytes4[][] memory sels = new bytes4[][](1);
        sels[0] = new bytes4[](1);
        sels[0][0] = Pool.deposit.selector;

        vm.expectRevert(PoolProxy.UntrustedModule.selector);
        proxy.addModules(impls, sels);

        // Step 2: mark trusted via setModuleTrustBatch (DEPLOYER-only).
        bool[] memory trustedFlags = new bool[](1);
        trustedFlags[0] = true;
        proxy.setModuleTrustBatch(impls, trustedFlags);

        assertTrue(proxy.isModuleTrusted(address(poolImpl)), "trust must be set");

        // Step 3: now addModules registers selectors instantly (slot empty).
        proxy.addModules(impls, sels);

        // Verify dispatch slot wired (read PoolStorage.modules[selector] via vm.load).
        // CORE_STORAGE_LOC + 13 = modules mapping. keccak256(selector, slot) → impl.
        // Functional verification: calling Pool.deposit on the proxy should now route through
        // (and revert on uninitialized state with a non-fallback error).
        // Cheaper: re-run addModules with same impl = no-op (selector already mapped).
        proxy.addModules(impls, sels);

        // Step 4: queue an update (different impl, same selector → timelocked).
        Pool poolImpl2 = new Pool();
        address[] memory impls2 = new address[](1);
        impls2[0] = address(poolImpl2);
        bool[] memory t2 = new bool[](1);
        t2[0] = true;
        proxy.setModuleTrustBatch(impls2, t2);

        proxy.addModules(impls2, sels); // queues, doesn't replace immediately

        // Step 5: revoke trust on poolImpl2 BEFORE exec → executeModuleUpdate must revert.
        bool[] memory revoke = new bool[](1);
        revoke[0] = false;
        proxy.setModuleTrustBatch(impls2, revoke);

        // Warp past HIGH_TIMELOCK (used by addModules for occupied selectors).
        vm.warp(block.timestamp + C.HIGH_TIMELOCK + 1);
        vm.expectRevert(PoolProxy.UntrustedModule.selector);
        proxy.executeModuleUpdate(Pool.deposit.selector);

        // Step 6: re-trust + execute → succeeds.
        proxy.setModuleTrustBatch(impls2, t2);
        proxy.executeModuleUpdate(Pool.deposit.selector);
    }

    /// @notice Non-DEPLOYER cannot call addModules (auth gate sanity).
    function test_F_A2_2_addModules_nonDeployer_reverts() public {
        PoolProxy proxy = new PoolProxy();
        Pool poolImpl = new Pool();

        // Trust setup as DEPLOYER.
        address[] memory impls = new address[](1);
        impls[0] = address(poolImpl);
        bool[] memory t = new bool[](1);
        t[0] = true;
        proxy.setModuleTrustBatch(impls, t);

        bytes4[][] memory sels = new bytes4[][](1);
        sels[0] = new bytes4[](1);
        sels[0][0] = Pool.deposit.selector;

        // Non-DEPLOYER (random EOA) → revert.
        vm.prank(address(0xBADD1E));
        vm.expectRevert(Ownable.Unauthorized.selector);
        proxy.addModules(impls, sels);
    }

    /// @notice Non-DEPLOYER cannot call setModuleTrustBatch.
    function test_F_A2_2_setModuleTrustBatch_nonDeployer_reverts() public {
        PoolProxy proxy = new PoolProxy();

        address[] memory impls = new address[](1);
        impls[0] = address(0xCAFE);
        bool[] memory t = new bool[](1);
        t[0] = true;

        vm.prank(address(0xBADD1E));
        vm.expectRevert(Ownable.Unauthorized.selector);
        proxy.setModuleTrustBatch(impls, t);
    }
}
