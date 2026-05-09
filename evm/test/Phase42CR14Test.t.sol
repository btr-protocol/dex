// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Distributor} from "../src/modules/Distributor.sol";
import {IDistributor} from "../src/interfaces/modules/IDistributor.sol";
import {SoulboundToken} from "../src/tokens/SoulboundToken.sol";
import {BTRToken} from "./fixtures/BTRToken.sol";
import {Err} from "@btr-peripheral/Errors.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {LibConstants as C} from "../src/libraries/LibConstants.sol";

/// @title Phase42CR14Test
/// @notice Phase 42C R14 remediation:
///   - F-A2-R14-3 (MED): Distributor first-campaign DoS — `nextCampaignId=0` ⇒ id=0 unreachable.
///   - F-A2-R14-2 (LOW): Distributor merkle leaf cross-campaign domain separation.
contract Phase42CR14Test is Test {
    Distributor internal dist;
    address internal distAddr;
    address internal manager = address(0xA8A6E7);

    function setUp() public {
        dist = new Distributor();
        distAddr = address(dist);
        // CORE_STORAGE_LOC slot 0 = owner.
        bytes32 slot = bytes32(uint256(C.CORE_STORAGE_LOC) + 0);
        bytes32 cur = vm.load(distAddr, slot);
        uint256 cleared = uint256(cur) & ~uint256(type(uint160).max);
        vm.store(distAddr, slot, bytes32(cleared | uint256(uint160(address(this)))));
    }

    // ─────────────────────────────────────────────────────────────────────
    // F-A2-R14-3 — first-campaign reachability
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Pre-fix: first createTokenCampaign returned id=0; every mutating op reverted.
    function test_F_A2_R14_3_firstTokenCampaign_idIsOne_andMutating_works() public {
        BTRToken reward = new BTRToken("RWD", "RWD", 18);
        uint256 id = dist.createTokenCampaign(address(reward), manager);
        assertEq(id, 1, "first id must be 1, never 0");

        // Mutating ops must succeed on the first campaign.
        reward.mint(distAddr, 1_000e18);
        vm.prank(manager);
        dist.updateCampaignRoot(id, bytes32(uint256(0xABC)), uint32(block.timestamp), 1_000e18);

        dist.pauseCampaign(id);
        dist.resumeCampaign(id);
        dist.finalizeCampaign(id);

        // ids increment correctly post-bump.
        BTRToken reward2 = new BTRToken("RW2", "RW2", 18);
        uint256 id2 = dist.createTokenCampaign(address(reward2), manager);
        assertEq(id2, 2, "second id must be 2");
    }

    /// @notice First POINTS campaign also reachable; SBT not orphaned.
    function test_F_A2_R14_3_firstPointsCampaign_idIsOne_andSBT_live() public {
        (uint256 id, address sbt) = dist.createPointsCampaign("Pts", "PTS", manager);
        assertEq(id, 1);
        assertTrue(sbt != address(0));

        // Finalize-points path must work for the first campaign.
        BTRToken redeem = new BTRToken("RDM", "RDM", 18);
        dist.finalizePointsCampaign(id, address(redeem), 1e18, 0);
        IDistributor.Campaign memory c = dist.getCampaign(id);
        assertEq(uint256(c.status), uint256(IDistributor.CampaignStatus.REDEEMABLE));
        assertEq(c.redeemToken, address(redeem));
    }

    /// @notice Negative regression: query of campaign id 0 still reverts NotConfigured (sentinel preserved).
    function test_F_A2_R14_3_id0_stillRejected() public {
        // No campaign created yet; any mutating op on id=0 must revert.
        vm.expectRevert();
        dist.pauseCampaign(0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // F-A2-R14-2 — merkle leaf domain separation across campaigns
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Build a single-leaf tree (root == leaf).
    function _leaf(uint256 cid, uint256 idx, address acct, uint256 earned) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(cid, idx, acct, earned));
    }

    /// @notice A proof for campaign A must NOT validate against campaign B's root if managers
    ///         (mistakenly OR maliciously) reuse identical (idx, account, totalEarned) inputs.
    function test_F_A2_R14_2_crossCampaign_proofReplay_blocked() public {
        BTRToken rewardA = new BTRToken("RA", "RA", 18);
        BTRToken rewardB = new BTRToken("RB", "RB", 18);

        uint256 cidA = dist.createTokenCampaign(address(rewardA), manager);
        uint256 cidB = dist.createTokenCampaign(address(rewardB), manager);

        address user = address(0xBEEF);
        uint256 earned = 100e18;

        // Single-leaf trees ⇒ root == leaf, proof is empty array.
        bytes32 rootA = _leaf(cidA, 0, user, earned);
        bytes32 rootB = _leaf(cidB, 0, user, earned);
        // Same (idx, account, totalEarned) but different campaignId ⇒ different roots.
        assertTrue(rootA != rootB, "leaf domain separation by campaignId must yield distinct roots");

        rewardA.mint(distAddr, earned);
        rewardB.mint(distAddr, earned);

        vm.prank(manager);
        dist.updateCampaignRoot(cidA, rootA, uint32(block.timestamp), earned);
        vm.prank(manager);
        dist.updateCampaignRoot(cidB, rootB, uint32(block.timestamp), earned);

        bytes32[] memory proof = new bytes32[](0);

        // Claim on A succeeds.
        vm.prank(user);
        dist.claimCampaign(cidA, 0, user, earned, proof);
        assertEq(rewardA.balanceOf(user), earned);

        // The same (idx, account, totalEarned) tuple — i.e. a proof crafted for A's leaf —
        // would only validate on B if leaves omitted campaignId. With domain separation,
        // the leaf computed inside `claimCampaign(cidA-style proof, cidB)` is `keccak(cidB,...)`
        // which differs from rootB only if the off-chain root signer also keyed by campaignId.
        // To exercise the replay surface, simulate a manager that publishes A's root onto B
        // (the worst-case off-chain hygiene failure). With the fix, claiming on B yields zero
        // (proof verifies against A's root layout, but rootB equals A's-style leaf for cidB,
        // not cidA) ⇒ getCampaignClaimable returns 0.
        vm.prank(manager);
        dist.updateCampaignRoot(cidB, rootA, uint32(block.timestamp), earned); // intentionally publish A's root on B
        uint256 claimableOnB = dist.getCampaignClaimable(cidB, 0, user, earned, proof);
        assertEq(claimableOnB, 0, "cross-campaign proof replay must yield zero claimable");

        vm.prank(user);
        vm.expectRevert(Err.InvalidState.selector);
        dist.claimCampaign(cidB, 0, user, earned, proof);
    }

    /// @notice Direct claim on B with B's own properly-domain-separated root succeeds — sanity.
    function test_F_A2_R14_2_directCampaignClaim_succeeds() public {
        BTRToken rewardA = new BTRToken("RA", "RA", 18);
        BTRToken rewardB = new BTRToken("RB", "RB", 18);
        // Two campaigns to keep ids non-trivial.
        dist.createTokenCampaign(address(rewardA), manager);
        uint256 cidB = dist.createTokenCampaign(address(rewardB), manager);
        address user = address(0xCAFE);
        uint256 earned = 50e18;
        bytes32 rootB = _leaf(cidB, 7, user, earned);
        rewardB.mint(distAddr, earned);
        vm.prank(manager);
        dist.updateCampaignRoot(cidB, rootB, uint32(block.timestamp), earned);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(user);
        dist.claimCampaign(cidB, 7, user, earned, proof);
        assertEq(rewardB.balanceOf(user), earned);
    }
}

// dummy import-keeper for SBT type usage
contract _R14SBTRef {
    function _ref(SoulboundToken t) external pure returns (SoulboundToken) { return t; }
}
