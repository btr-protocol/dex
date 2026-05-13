// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title IDistributor -singleton cumulative Merkle distributor (TOKEN ERC20 only)
/// @notice Phase 42H.B.3c -promoted out of the Diamond into a standalone singleton.
/// @dev Per-pool keyed: every campaign id is namespaced by the (pool, id) pair and
///      mutating ops carry the pool address as the first arg. SBT/POINTS path remains
///      removed (Phase 42H.A.2). Owner authority routes through the shared singleton
///      AccessControl exposed via `AC`.
interface IDistributor {
    enum CampaignStatus { ACTIVE, PAUSED, FINALIZED }

    struct Campaign {
        uint256 id;
        CampaignStatus status;
        address rewardToken;
        address manager;
        bytes32 merkleRoot;
        uint32 lastUpdate;
        uint256 totalAllocated;
    }

    event CampaignCreated(address indexed pool, uint256 indexed campaignId, address indexed rewardToken, address manager);
    event CampaignRootUpdated(address indexed pool, uint256 indexed campaignId, bytes32 merkleRoot, uint32 updatedAt, uint256 totalClaimable);
    event CampaignClaimed(address indexed pool, uint256 indexed campaignId, address indexed account, uint256 claimable, uint256 totalEarned);
    event CampaignStatusUpdated(address indexed pool, uint256 indexed campaignId, CampaignStatus newStatus);

    function createTokenCampaign(address pool, address rewardToken, address manager) external returns (uint256 campaignId);

    function updateCampaignRoot(address pool, uint256 campaignId, bytes32 merkleRoot, uint32 updatedAt, uint256 totalClaimable) external;

    /// @param account must be msg.sender
    function claimCampaign(
        address pool,
        uint256 campaignId,
        uint256 index,
        address account,
        uint256 totalEarned,
        bytes32[] calldata merkleProof
    ) external;

    function pauseCampaign(address pool, uint256 campaignId) external;
    function resumeCampaign(address pool, uint256 campaignId) external;
    function finalizeCampaign(address pool, uint256 campaignId) external;

    function getCampaign(address pool, uint256 campaignId) external view returns (Campaign memory campaign);
    function getCampaignClaimed(address pool, uint256 campaignId, address account) external view returns (uint256 claimed);
    function getCampaignClaimable(
        address pool,
        uint256 campaignId,
        uint256 index,
        address account,
        uint256 totalEarned,
        bytes32[] calldata merkleProof
    ) external view returns (uint256 claimable);
}
