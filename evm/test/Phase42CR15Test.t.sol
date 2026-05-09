// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Treasury} from "../src/Treasury.sol";
import {GovToken} from "../src/tokens/GovToken.sol";
import {BridgeableERC20} from "../src/tokens/BridgeableERC20.sol";
import {Distributor} from "../src/modules/Distributor.sol";
import {IDistributor} from "../src/interfaces/modules/IDistributor.sol";
import {SoulboundToken} from "../src/tokens/SoulboundToken.sol";
import {BTRToken} from "./fixtures/BTRToken.sol";
import {Err} from "@btr-peripheral/Errors.sol";
import {LibConstants as C} from "../src/libraries/LibConstants.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title Phase42CR15Test
/// @notice Phase 42C R15 remediation:
///   - F-A2-R15-1 (HIGH): GovToken bridge selector mismatch — Treasury now exposes getBridge().
///   - F-A1-R15-1 (LOW): executeEmissionsCapChange re-validates `pendingCap >= claimed` at exec.
///   - F-A2-R15-2 (INFO): redeemPoints accumulates totalRedeemed regardless of maxRedeemable.
///   - F-A4-R15-1 (INFO): redeemPoints unchecked-arith bound — documented in source.
contract Phase42CR15Test is Test {
    // ───────────────────────────────────────────── F-A2-R15-1 ──
    // Real GovToken crosschain mint/burn auth gate via Treasury.getBridge().

    GovToken internal gov;
    Treasury internal treasury;
    address internal owner = address(0xA11CE);
    address internal mockBridge = address(0xB81D);
    address internal user = address(0xBEEF);

    function setUp() public {
        // Deploy Treasury w/ a placeholder gov token first to satisfy ctor; then redeploy
        // a real GovToken whose owner = treasury. Treasury never calls govToken in these tests.
        BTRToken placeholder = new BTRToken("PG", "PG", 18);
        treasury = new Treasury(address(placeholder));
        treasury.initialize(owner);
        gov = new GovToken(address(treasury), "BTR", "BTR");

        // Wire bridge in Treasury (owner-gated).
        vm.prank(owner);
        treasury.setBridge(mockBridge);
    }

    // ───────────────────────────────────────────── F-A2-R15-1 ──
    // Direct selector check: getBridge() exists on Treasury and returns the wired bridge.
    function test_F_A2_R15_1_treasury_exposes_getBridge_selector() public {
        // Direct interface call to exercise the IBridgeProvider selector path used by GovToken.
        (bool ok, bytes memory data) = address(treasury).staticcall(abi.encodeWithSignature("getBridge()"));
        assertTrue(ok, "getBridge() selector must exist on Treasury (HIGH fix)");
        assertEq(abi.decode(data, (address)), mockBridge, "getBridge must return wired bridge");
        assertEq(treasury.bridge(), mockBridge, "bridge() auto-getter still functional");
    }

    /// @notice GovToken._getBridge() must resolve through Treasury.getBridge(), enabling
    ///         BridgeableERC20.onlyBridge for the wired bridge. Pre-fix: getBridge() did NOT
    ///         exist on Treasury → try/catch swallowed → returned address(0) → all calls reverted.
    function test_F_A2_R15_1_crosschainMint_succeeds_when_bridge_calls() public {
        vm.prank(mockBridge);
        gov.crosschainMint(user, 100e18, "");
        assertEq(gov.balanceOf(user), 100e18, "crosschainMint must credit user when bridge calls");
        assertEq(gov.totalSupply(), 100e18);
    }

    function test_F_A2_R15_1_crosschainBurn_succeeds_when_bridge_calls() public {
        // Seed user balance via crosschainMint first.
        vm.prank(mockBridge);
        gov.crosschainMint(user, 100e18, "");

        vm.prank(mockBridge);
        gov.crosschainBurn(user, 40e18, "");
        assertEq(gov.balanceOf(user), 60e18, "crosschainBurn must debit user when bridge calls");
        assertEq(gov.totalSupply(), 60e18);
    }

    function test_F_A2_R15_1_crosschainMint_reverts_when_nonBridge_calls() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(BridgeableERC20.UnauthorizedBridge.selector);
        gov.crosschainMint(user, 100e18, "");
    }

    function test_F_A2_R15_1_crosschainBurn_reverts_when_nonBridge_calls() public {
        vm.prank(mockBridge);
        gov.crosschainMint(user, 100e18, "");

        vm.prank(address(0xDEAD));
        vm.expectRevert(BridgeableERC20.UnauthorizedBridge.selector);
        gov.crosschainBurn(user, 1, "");
    }

    /// @notice Regression sentinel: if Treasury.getBridge() were removed (or renamed), the
    ///         try/catch in GovToken._getBridge would catch and return address(0), breaking
    ///         `onlyBridge` for ALL non-zero senders. We assert the wiring round-trip here.
    function test_F_A2_R15_1_regression_bridge_wiring_roundtrip() public {
        // Rotate the bridge and verify GovToken picks up the new value via Treasury.getBridge().
        address newBridge = address(0xB12);
        vm.prank(owner);
        treasury.setBridge(newBridge);
        (bool ok, bytes memory data) = address(treasury).staticcall(abi.encodeWithSignature("getBridge()"));
        assertTrue(ok);
        assertEq(abi.decode(data, (address)), newBridge);

        // Old bridge no longer authorized.
        vm.prank(mockBridge);
        vm.expectRevert(BridgeableERC20.UnauthorizedBridge.selector);
        gov.crosschainMint(user, 1, "");

        // New bridge authorized.
        vm.prank(newBridge);
        gov.crosschainMint(user, 7, "");
        assertEq(gov.balanceOf(user), 7);
    }

    // ───────────────────────────────────────────── F-A1-R15-1 ──
    // executeEmissionsCapChange must revert if claimed grew above pendingCap during timelock.

    function test_F_A1_R15_1_executeEmissionsCapChange_revertsIfClaimedExceedsNewCap() public {
        // Fresh treasury w/ a real (test-controllable) gov surface. We use a TestMintable shim
        // to let Treasury.mintEmissionsToDistributor succeed without GovToken-only constraints.
        TestMintable tg = new TestMintable();
        Treasury t = new Treasury(address(tg));
        t.initialize(owner);

        vm.prank(owner);
        t.initializeEmissions(1_000e18);

        vm.prank(owner);
        t.setDistributor(address(0xD15));

        // initializeTGE sets maxSupply = treasury+seed+vesting+emissionsAlloc.
        address[] memory bens = new address[](0);
        uint256[] memory allocs = new uint256[](0);
        vm.prank(owner);
        t.initializeTGE(0, 0, bens, allocs);

        // Mint 600 emissions ⇒ claimed = 600.
        vm.prank(owner);
        t.mintEmissionsToDistributor(600e18);
        (, uint256 claimedBefore,,,, ) = t.emissionsSchedule();
        assertEq(claimedBefore, 600e18);

        // Owner requests cap reduction to 700 (still > claimed=600 at request time → passes floor).
        vm.prank(owner);
        t.requestEmissionsCapChange(700e18);

        // Mint another 200 during the timelock window ⇒ claimed = 800 > pendingCap 700.
        vm.prank(owner);
        t.mintEmissionsToDistributor(200e18);
        (, uint256 claimedMid,,,, ) = t.emissionsSchedule();
        assertEq(claimedMid, 800e18);

        // Warp past timelock.
        vm.warp(block.timestamp + C.CRITICAL_TIMELOCK + 1);

        // Pre-fix: execute would silently set totalAllocation=700 with claimed=800 ⇒ wedged.
        // Post-fix: execute reverts InvalidState.
        vm.prank(owner);
        vm.expectRevert(Err.InvalidState.selector);
        t.executeEmissionsCapChange();
    }

    /// @notice Sanity: when claimed has not grown past pendingCap, execute still works.
    function test_F_A1_R15_1_executeEmissionsCapChange_succeeds_when_invariantHolds() public {
        TestMintable tg = new TestMintable();
        Treasury t = new Treasury(address(tg));
        t.initialize(owner);

        vm.prank(owner);
        t.initializeEmissions(1_000e18);
        vm.prank(owner);
        t.setDistributor(address(0xD15));
        address[] memory bens = new address[](0);
        uint256[] memory allocs = new uint256[](0);
        vm.prank(owner);
        t.initializeTGE(0, 0, bens, allocs);

        vm.prank(owner);
        t.mintEmissionsToDistributor(300e18);

        vm.prank(owner);
        t.requestEmissionsCapChange(2_000e18);

        vm.warp(block.timestamp + C.CRITICAL_TIMELOCK + 1);
        vm.prank(owner);
        t.executeEmissionsCapChange();
        assertEq(t.emissionsCap(), 2_000e18);
    }

    // ───────────────────────────────────────────── F-A2-R15-2 ──
    // redeemPoints accumulates totalRedeemed even when maxRedeemable == 0 (unbounded campaign).

    function test_F_A2_R15_2_redeemPoints_accumulates_totalRedeemed_when_unbounded() public {
        Distributor dist = new Distributor();
        // Take ownership of distributor (CORE_STORAGE_LOC slot 0 = owner).
        bytes32 slot = bytes32(uint256(C.CORE_STORAGE_LOC) + 0);
        bytes32 cur = vm.load(address(dist), slot);
        uint256 cleared = uint256(cur) & ~uint256(type(uint160).max);
        vm.store(address(dist), slot, bytes32(cleared | uint256(uint160(address(this)))));

        address mgr = address(0xA8A6E7);
        (uint256 cid, address sbt) = dist.createPointsCampaign("Pts", "PTS", mgr);

        // Single-leaf merkle so user can claim SBT.
        uint256 earned = 1_000e18;
        bytes32 root = keccak256(abi.encodePacked(cid, uint256(0), user, earned));
        vm.prank(mgr);
        dist.updateCampaignRoot(cid, root, uint32(block.timestamp), earned);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(user);
        dist.claimCampaign(cid, 0, user, earned, proof);
        assertEq(SoulboundToken(sbt).balanceOf(user), earned);

        // Finalize as REDEEMABLE w/ maxRedeemable = 0 (unbounded).
        BTRToken redeemTok = new BTRToken("RDM", "RDM", 18);
        redeemTok.mint(address(dist), 10_000e18);
        dist.finalizePointsCampaign(cid, address(redeemTok), 1e18, 0); // 1:1 rate, unbounded

        // First redeem: 100 SBT → 100 redeemTok. totalRedeemed must increment from 0 → 100.
        vm.prank(user);
        dist.redeemPoints(cid, 100e18);
        IDistributor.Campaign memory c1 = dist.getCampaign(cid);
        assertEq(c1.totalRedeemed, 100e18, "totalRedeemed must accumulate even when maxRedeemable=0");

        // Second redeem: another 250 SBT → totalRedeemed must reach 350.
        vm.prank(user);
        dist.redeemPoints(cid, 250e18);
        IDistributor.Campaign memory c2 = dist.getCampaign(cid);
        assertEq(c2.totalRedeemed, 350e18, "second unbounded redeem accumulates correctly");

        // Bounded campaign sanity: still tracked.
        assertEq(redeemTok.balanceOf(user), 350e18);
    }

    /// @notice Bounded campaign regression: cap enforcement still works post-fix.
    function test_F_A2_R15_2_redeemPoints_bounded_capStillEnforced() public {
        Distributor dist = new Distributor();
        bytes32 slot = bytes32(uint256(C.CORE_STORAGE_LOC) + 0);
        bytes32 cur = vm.load(address(dist), slot);
        uint256 cleared = uint256(cur) & ~uint256(type(uint160).max);
        vm.store(address(dist), slot, bytes32(cleared | uint256(uint160(address(this)))));

        address mgr = address(0xA8A6E7);
        (uint256 cid, address sbt) = dist.createPointsCampaign("Pts", "PTS", mgr);
        uint256 earned = 500e18;
        bytes32 root = keccak256(abi.encodePacked(cid, uint256(0), user, earned));
        vm.prank(mgr);
        dist.updateCampaignRoot(cid, root, uint32(block.timestamp), earned);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(user);
        dist.claimCampaign(cid, 0, user, earned, proof);

        BTRToken redeemTok = new BTRToken("RDM", "RDM", 18);
        redeemTok.mint(address(dist), 10_000e18);
        dist.finalizePointsCampaign(cid, address(redeemTok), 1e18, 200e18); // bounded cap=200

        vm.prank(user);
        dist.redeemPoints(cid, 150e18);
        assertEq(dist.getCampaign(cid).totalRedeemed, 150e18);

        // Exceeding the cap reverts.
        vm.prank(user);
        vm.expectRevert();
        dist.redeemPoints(cid, 100e18); // would push to 250 > 200
        // Sanity: the SBT not consumed by reverted call
        assertEq(SoulboundToken(sbt).balanceOf(user), earned - 150e18);
    }
}

// ─────────────────────────────────────────────────────────────
// Test-only mintable shim — implements IMintable surface used by Treasury without
// the bridge auth constraints of GovToken (irrelevant to emissions cap tests).
contract TestMintable {
    uint256 public totalSupply;
    uint256 public maxSupply;
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}
