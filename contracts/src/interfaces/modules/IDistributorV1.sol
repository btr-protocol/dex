// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IErrors} from "../IErrors.sol";

/// @title IDistributor
/// @notice Cumulative Merkle-based reward distribution with campaign management
interface IDistributorV1 is IErrors {
    // ═══════════════════════════════════════════════════════════════════════════
    // ENUMS
    // ═══════════════════════════════════════════════════════════════════════════

    enum CampaignType {
        POINTS,  // Non-transferable points (SBT), later convertible to tokens
        TOKENS   // Direct token rewards (e.g., sBTR after launch)
    }

    /// @notice Campaign lifecycle status
    /// @dev For POINTS campaigns:
    ///      - ACTIVE: Merkle claims allowed, pauseCampaign/resumeCampaign available
    ///      - PAUSED: Merkle claims blocked, resumeCampaign to return to ACTIVE
    ///      - REDEEMABLE: Merkle claims blocked, points redemption enabled (terminal state)
    /// @dev For TOKENS campaigns:
    ///      - ACTIVE: Merkle claims allowed
    ///      - PAUSED: Merkle claims blocked
    ///      - FINALIZED: Merkle claims blocked (terminal state)
    enum CampaignStatus {
        ACTIVE,      // Accepting Merkle claims
        PAUSED,      // Temporarily paused (can resume to ACTIVE)
        FINALIZED,   // Ended, no more claims (TOKENS only)
        REDEEMABLE   // POINTS only: claims disabled, redemption enabled (terminal state)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE STRUCT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Campaign configuration
    struct Campaign {
        uint256 id;
        CampaignType campaignType;
        CampaignStatus status;
        address rewardToken;      // SBT address for POINTS, ERC20 address for TOKENS
        address manager;          // Address that can update roots
        bytes32 merkleRoot;       // Current cumulative root
        uint32 lastUpdate;        // Last root update timestamp
        uint256 totalAllocated;   // Total amount in current merkle tree (for TOKEN campaigns)

        // Redemption config (POINTS campaigns only, set via finalizePointsCampaign)
        address redeemToken;      // Token to receive when redeeming points
        uint256 redeemRate;       // Points-to-token rate (1e18 = 1:1)
        uint256 maxRedeemable;    // Max tokens that can be redeemed (budget cap, 0 = unlimited)
        uint256 totalRedeemed;    // Total tokens redeemed so far
    }

    /// @notice Distributor storage (campaign-based cumulative model)
    struct DistributorStorage {
        uint256 nextCampaignId;
        mapping(uint256 => Campaign) campaigns;
        mapping(uint256 => mapping(address => uint256)) campaignClaimed;  // campaignId => account => claimed
        mapping(uint256 => uint256) totalClaimed;  // campaignId => total claimed across all users
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════
    event CampaignCreated(
        uint256 indexed campaignId,
        CampaignType campaignType,
        address indexed rewardToken,
        address indexed manager
    );

    event CampaignRootUpdated(
        uint256 indexed campaignId,
        bytes32 merkleRoot,
        uint32 updatedAt,
        uint256 totalClaimable
    );

    event CampaignClaimed(
        uint256 indexed campaignId,
        address indexed account,
        uint256 claimable,
        uint256 totalEarned
    );

    event CampaignStatusUpdated(
        uint256 indexed campaignId,
        CampaignStatus newStatus
    );

    event PointsCampaignFinalized(
        uint256 indexed campaignId,
        address indexed redeemToken,
        uint256 redeemRate,
        uint256 maxRedeemable
    );

    event PointsRedeemed(
        uint256 indexed campaignId,
        address indexed account,
        uint256 pointsBurned,
        uint256 tokensReceived
    );

    // ═══════════════════════════════════════════════════════════════════════════
    // CAMPAIGN MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Create points campaign (owner only)
    /// @dev Deploys SBT token for non-transferable points
    /// @param name Points token name (e.g., "Pre-BTR Points")
    /// @param symbol Points token symbol (e.g., "pBTR")
    /// @param manager Address that can update roots
    /// @return campaignId Campaign ID
    /// @return sbtToken Deployed SBT address
    function createPointsCampaign(
        string calldata name,
        string calldata symbol,
        address manager
    ) external returns (uint256 campaignId, address sbtToken);

    /// @notice Create token campaign (owner only)
    /// @dev Direct token rewards (e.g., sBTR after launch). Can run indefinitely with root updates.
    /// @param rewardToken Token address to distribute
    /// @param manager Address that can update roots
    /// @return campaignId Campaign ID
    function createTokenCampaign(
        address rewardToken,
        address manager
    ) external returns (uint256 campaignId);

    /// @notice Update campaign Merkle root (manager only)
    /// @param campaignId Campaign ID
    /// @param merkleRoot New cumulative Merkle root
    /// @param updatedAt Update timestamp
    /// @param totalClaimable Total amount claimable in new merkle tree
    function updateCampaignRoot(
        uint256 campaignId,
        bytes32 merkleRoot,
        uint32 updatedAt,
        uint256 totalClaimable
    ) external;

    /// @notice Claim rewards from campaign
    /// @param campaignId Campaign ID
    /// @param index Leaf index
    /// @param account Recipient (must be msg.sender)
    /// @param totalEarned Cumulative total earned
    /// @param merkleProof Merkle proof
    function claimCampaign(
        uint256 campaignId,
        uint256 index,
        address account,
        uint256 totalEarned,
        bytes32[] calldata merkleProof
    ) external;

    /// @notice Pause campaign (owner only)
    /// @param campaignId Campaign ID
    function pauseCampaign(uint256 campaignId) external;

    /// @notice Resume campaign (owner only)
    /// @param campaignId Campaign ID
    function resumeCampaign(uint256 campaignId) external;

    /// @notice Finalize TOKENS campaign (owner only)
    /// @dev Prevents further claims. For POINTS campaigns, use finalizePointsCampaign instead.
    /// @param campaignId Campaign ID
    function finalizeCampaign(uint256 campaignId) external;

    /// @notice Finalize POINTS campaign and enable redemption (owner or manager)
    /// @dev Sets redemption parameters and enables user redemption. Can only be called once.
    /// @param campaignId Points campaign ID
    /// @param redeemToken Token users will receive (e.g., BTR)
    /// @param redeemRate Points-to-token conversion rate (1e18 = 1:1)
    /// @param maxRedeemable Maximum tokens that can be redeemed (budget cap)
    function finalizePointsCampaign(
        uint256 campaignId,
        address redeemToken,
        uint256 redeemRate,
        uint256 maxRedeemable
    ) external;

    /// @notice Redeem points for tokens (user-callable, POINTS campaigns only)
    /// @dev Burns SBT points from caller, transfers tokens at campaign's fixed rate
    /// @param campaignId Points campaign ID
    /// @param amount Amount of points to redeem
    function redeemPoints(uint256 campaignId, uint256 amount) external;

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEWS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Get campaign details
    /// @param campaignId Campaign ID
    /// @return campaign Campaign struct
    function getCampaign(uint256 campaignId) external view returns (Campaign memory campaign);

    /// @notice Get claimed amount for campaign
    /// @param campaignId Campaign ID
    /// @param account User address
    /// @return claimed Total claimed amount
    function getCampaignClaimed(uint256 campaignId, address account) external view returns (uint256 claimed);

    /// @notice Get claimable amount for campaign (requires proof)
    /// @param campaignId Campaign ID
    /// @param index Leaf index
    /// @param account User address
    /// @param totalEarned Total earned from current root
    /// @param merkleProof Merkle proof
    /// @return claimable Amount claimable now
    function getCampaignClaimable(
        uint256 campaignId,
        uint256 index,
        address account,
        uint256 totalEarned,
        bytes32[] calldata merkleProof
    ) external view returns (uint256 claimable);
}
