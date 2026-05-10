// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {Distributor} from "../src/Distributor.sol";
import {IDistributor} from "../src/interfaces/IDistributor.sol";
import {BTRToken} from "./fixtures/BTRToken.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {MockAC} from "./fixtures/BaseTestSetup.sol";

/// @title Phase42CR14Test
/// @notice Phase 42C R14 remediations preserved on the Phase 42H.B.3c singleton topology:
///   - F-A2-R14-3 (MED): first-campaign DoS — `nextCampaignId=0` ⇒ id=0 unreachable.
///   - F-A2-R14-2 (LOW): merkle leaf cross-campaign domain separation (now keyed
///     by (pool, campaignId, ...) for additional cross-pool separation).
contract Phase42CR14Test is Test {
    Distributor internal dist;
    address internal distAddr;
    address internal manager = address(0xA8A6E7);
    address internal pool = address(0xB001);

    function setUp() public {
        // MockAC.owner = address(this) → onlyOwner gate passes for createTokenCampaign.
        dist = new Distributor(address(new MockAC(address(this))));
        distAddr = address(dist);
    }

    // ─────────────────────────────────────────────────────────────────────
    // F-A2-R14-3 — first-campaign reachability
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Pre-fix: first createTokenCampaign returned id=0; every mutating op reverted.
    function test_F_A2_R14_3_firstTokenCampaign_idIsOne_andMutating_works() public {
        BTRToken reward = new BTRToken("RWD", "RWD", 18);
        uint256 id = dist.createTokenCampaign(pool, address(reward), manager);
        assertEq(id, 1, "first id must be 1, never 0");

        // Mutating ops must succeed on the first campaign.
        reward.mint(distAddr, 1_000e18);
        vm.prank(manager);
        dist.updateCampaignRoot(pool, id, bytes32(uint256(0xABC)), uint32(block.timestamp), 1_000e18);

        dist.pauseCampaign(pool, id);
        dist.resumeCampaign(pool, id);
        dist.finalizeCampaign(pool, id);

        // ids increment correctly post-bump.
        BTRToken reward2 = new BTRToken("RW2", "RW2", 18);
        uint256 id2 = dist.createTokenCampaign(pool, address(reward2), manager);
        assertEq(id2, 2, "second id must be 2");
    }

    /// @notice Negative regression: query of campaign id 0 still reverts NotConfigured (sentinel preserved).
    function test_F_A2_R14_3_id0_stillRejected() public {
        vm.expectRevert();
        dist.pauseCampaign(pool, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // F-A2-R14-2 — merkle leaf domain separation
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Build a single-leaf tree (root == leaf), with (pool, campaignId, idx, account, totalEarned).
    function _leaf(address p, uint256 cid, uint256 idx, address acct, uint256 earned) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(p, cid, idx, acct, earned));
    }

    /// @notice A proof for campaign A must NOT validate against campaign B's root if managers
    ///         (mistakenly OR maliciously) reuse identical (idx, account, totalEarned) inputs.
    function test_F_A2_R14_2_crossCampaign_proofReplay_blocked() public {
        BTRToken rewardA = new BTRToken("RA", "RA", 18);
        BTRToken rewardB = new BTRToken("RB", "RB", 18);

        uint256 cidA = dist.createTokenCampaign(pool, address(rewardA), manager);
        uint256 cidB = dist.createTokenCampaign(pool, address(rewardB), manager);

        address user = address(0xBEEF);
        uint256 earned = 100e18;

        bytes32 rootA = _leaf(pool, cidA, 0, user, earned);
        bytes32 rootB = _leaf(pool, cidB, 0, user, earned);
        assertTrue(rootA != rootB, "leaf domain separation by campaignId must yield distinct roots");

        rewardA.mint(distAddr, earned);
        rewardB.mint(distAddr, earned);

        vm.prank(manager);
        dist.updateCampaignRoot(pool, cidA, rootA, uint32(block.timestamp), earned);
        vm.prank(manager);
        dist.updateCampaignRoot(pool, cidB, rootB, uint32(block.timestamp), earned);

        bytes32[] memory proof = new bytes32[](0);

        // Claim on A succeeds.
        vm.prank(user);
        dist.claimCampaign(pool, cidA, 0, user, earned, proof);
        assertEq(rewardA.balanceOf(user), earned);

        // Manager mis-publishes A's root onto B; with domain separation the leaf computed
        // for B (keyed by cidB) differs from cidA's root → claimable on B = 0.
        vm.prank(manager);
        dist.updateCampaignRoot(pool, cidB, rootA, uint32(block.timestamp), earned);
        uint256 claimableOnB = dist.getCampaignClaimable(pool, cidB, 0, user, earned, proof);
        assertEq(claimableOnB, 0, "cross-campaign proof replay must yield zero claimable");

        vm.prank(user);
        vm.expectRevert(Err.InvalidState.selector);
        dist.claimCampaign(pool, cidB, 0, user, earned, proof);
    }

    /// @notice Direct claim on B with B's own properly-domain-separated root succeeds — sanity.
    function test_F_A2_R14_2_directCampaignClaim_succeeds() public {
        BTRToken rewardA = new BTRToken("RA", "RA", 18);
        BTRToken rewardB = new BTRToken("RB", "RB", 18);
        dist.createTokenCampaign(pool, address(rewardA), manager);
        uint256 cidB = dist.createTokenCampaign(pool, address(rewardB), manager);
        address user = address(0xCAFE);
        uint256 earned = 50e18;
        bytes32 rootB = _leaf(pool, cidB, 7, user, earned);
        rewardB.mint(distAddr, earned);
        vm.prank(manager);
        dist.updateCampaignRoot(pool, cidB, rootB, uint32(block.timestamp), earned);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(user);
        dist.claimCampaign(pool, cidB, 7, user, earned, proof);
        assertEq(rewardB.balanceOf(user), earned);
    }

    /// @notice Cross-pool domain separation: same (campaignId, idx, account, totalEarned) on
    ///         different pools must produce distinct roots.
    function test_R14_3c_crossPool_domainSeparation() public {
        address poolA = address(0xB001);
        address poolB = address(0xB002);
        BTRToken reward = new BTRToken("RWD", "RWD", 18);
        uint256 cidA = dist.createTokenCampaign(poolA, address(reward), manager);
        uint256 cidB = dist.createTokenCampaign(poolB, address(reward), manager);
        // ids may collide (1, 1) since per-pool counters are independent.
        assertEq(cidA, 1);
        assertEq(cidB, 1);

        address user = address(0xD1D1);
        uint256 earned = 10e18;
        bytes32 rootA = _leaf(poolA, cidA, 0, user, earned);
        bytes32 rootB = _leaf(poolB, cidB, 0, user, earned);
        assertTrue(rootA != rootB, "different pools must yield different roots");
    }
}
