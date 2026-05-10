// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IDistributor — cumulative Merkle distribution + token-only campaigns
/// @dev Phase 42H.A.2: SBT/POINTS path removed; only direct ERC20 reward campaigns remain.
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

    struct DistributorStorage {
        uint256 nextCampaignId;
        mapping(uint256 => Campaign) campaigns;
        mapping(uint256 => mapping(address => uint256)) campaignClaimed;
        mapping(uint256 => uint256) totalClaimed;
    }

    event CampaignCreated(uint256 indexed campaignId, address indexed rewardToken, address indexed manager);
    event CampaignRootUpdated(uint256 indexed campaignId, bytes32 merkleRoot, uint32 updatedAt, uint256 totalClaimable);
    event CampaignClaimed(uint256 indexed campaignId, address indexed account, uint256 claimable, uint256 totalEarned);
    event CampaignStatusUpdated(uint256 indexed campaignId, CampaignStatus newStatus);

    function createTokenCampaign(address rewardToken, address manager) external returns (uint256 campaignId);

    function updateCampaignRoot(uint256 campaignId, bytes32 merkleRoot, uint32 updatedAt, uint256 totalClaimable) external;

    /// @param account must be msg.sender
    function claimCampaign(
        uint256 campaignId,
        uint256 index,
        address account,
        uint256 totalEarned,
        bytes32[] calldata merkleProof
    ) external;

    function pauseCampaign(uint256 campaignId) external;
    function resumeCampaign(uint256 campaignId) external;
    function finalizeCampaign(uint256 campaignId) external;

    function getCampaign(uint256 campaignId) external view returns (Campaign memory campaign);
    function getCampaignClaimed(uint256 campaignId, address account) external view returns (uint256 claimed);
    function getCampaignClaimable(
        uint256 campaignId,
        uint256 index,
        address account,
        uint256 totalEarned,
        bytes32[] calldata merkleProof
    ) external view returns (uint256 claimable);
}
