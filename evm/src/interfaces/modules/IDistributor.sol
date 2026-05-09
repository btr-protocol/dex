// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IDistributor — cumulative Merkle distribution + campaigns
interface IDistributor {
    /// @dev POINTS=non-transferable SBT (later redeemable). TOKENS=direct ERC20.
    enum CampaignType { POINTS, TOKENS }

    /// @dev POINTS: ACTIVE→PAUSED→REDEEMABLE(terminal). TOKENS: ACTIVE→PAUSED→FINALIZED(terminal).
    enum CampaignStatus { ACTIVE, PAUSED, FINALIZED, REDEEMABLE }

    struct Campaign {
        uint256 id;
        CampaignType campaignType;
        CampaignStatus status;
        address rewardToken;
        address manager;
        bytes32 merkleRoot;
        uint32 lastUpdate;
        uint256 totalAllocated;
        address redeemToken;
        uint256 redeemRate;
        uint256 maxRedeemable;
        uint256 totalRedeemed;
    }

    struct DistributorStorage {
        uint256 nextCampaignId;
        mapping(uint256 => Campaign) campaigns;
        mapping(uint256 => mapping(address => uint256)) campaignClaimed;
        mapping(uint256 => uint256) totalClaimed;
    }

    event CampaignCreated(uint256 indexed campaignId, CampaignType campaignType, address indexed rewardToken, address indexed manager);
    event CampaignRootUpdated(uint256 indexed campaignId, bytes32 merkleRoot, uint32 updatedAt, uint256 totalClaimable);
    event CampaignClaimed(uint256 indexed campaignId, address indexed account, uint256 claimable, uint256 totalEarned);
    event CampaignStatusUpdated(uint256 indexed campaignId, CampaignStatus newStatus);
    event PointsCampaignFinalized(uint256 indexed campaignId, address indexed redeemToken, uint256 redeemRate, uint256 maxRedeemable);
    event PointsRedeemed(uint256 indexed campaignId, address indexed account, uint256 pointsBurned, uint256 tokensReceived);

    /// @notice Create POINTS campaign (deploys SBT)
    function createPointsCampaign(string calldata name, string calldata symbol, address manager)
        external returns (uint256 campaignId, address sbtToken);

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

    /// @notice One-shot finalize POINTS + enable redemption (owner|manager). redeemRate: 1e18=1:1.
    function finalizePointsCampaign(uint256 campaignId, address redeemToken, uint256 redeemRate, uint256 maxRedeemable) external;

    function redeemPoints(uint256 campaignId, uint256 amount) external;

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
