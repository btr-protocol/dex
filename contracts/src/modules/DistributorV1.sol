// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseV1} from "./BaseV1.sol";
import {IErrors} from "../interfaces/IErrors.sol";
import {IDistributorV1} from "../interfaces/modules/IDistributorV1.sol";
import {IPoolV1} from "../interfaces/IPoolV1.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";
import {SoulboundToken} from "../tokens/SoulboundToken.sol";

/// @title DistributorV1
/// @notice Campaign-based cumulative Merkle distributor
/// @dev Supports POINTS (SBT) and TOKENS campaigns with per-campaign roots
/// @dev CRITICAL: Manager/treasury MUST pre-fund distributor with sufficient rewardToken (TOKENS)
///      or redeemToken (POINTS) before roots go live or redemption is enabled. Claims/redemptions
///      revert on insufficient balance.
contract DistributorV1 is BaseV1, IDistributorV1 {
    using SafeTransferLib for address;

    // ========== STORAGE ==========

    function _ds() internal pure returns (DistributorStorage storage $) {
        bytes32 slot = C.DISTRIBUTOR_STORAGE_LOC;
        assembly { $.slot := slot }
    }

    // ========== CAMPAIGN MANAGEMENT ==========

    /// @inheritdoc IDistributorV1
    function createPointsCampaign(
        string calldata name,
        string calldata symbol,
        address manager
    ) external onlyOwner returns (uint256 campaignId, address sbtToken) {
        if (manager == address(0)) revert IErrors.ZeroValue();

        DistributorStorage storage ds = _ds();
        campaignId = ds.nextCampaignId++;

        // Deploy SBT token (minter = this distributor, immutable)
        sbtToken = address(new SoulboundToken(name, symbol, address(this)));

        // Create campaign
        Campaign storage campaign = ds.campaigns[campaignId];
        campaign.id = campaignId;
        campaign.campaignType = CampaignType.POINTS;
        campaign.status = CampaignStatus.ACTIVE;
        campaign.rewardToken = sbtToken;
        campaign.manager = manager;

        emit CampaignCreated(campaignId, CampaignType.POINTS, sbtToken, manager);
    }

    /// @inheritdoc IDistributorV1
    function createTokenCampaign(
        address rewardToken,
        address manager
    ) external onlyOwner returns (uint256 campaignId) {
        if (rewardToken == address(0) || manager == address(0)) revert IErrors.ZeroValue();

        DistributorStorage storage ds = _ds();
        campaignId = ds.nextCampaignId++;

        // Create campaign
        Campaign storage campaign = ds.campaigns[campaignId];
        campaign.id = campaignId;
        campaign.campaignType = CampaignType.TOKENS;
        campaign.status = CampaignStatus.ACTIVE;
        campaign.rewardToken = rewardToken;
        campaign.manager = manager;

        emit CampaignCreated(campaignId, CampaignType.TOKENS, rewardToken, manager);
    }

    /// @inheritdoc IDistributorV1
    function updateCampaignRoot(
        uint256 campaignId,
        bytes32 merkleRoot,
        uint32 updatedAt,
        uint256 totalClaimable  // Total amount claimable in new merkle tree
    ) external {
        DistributorStorage storage ds = _ds();
        Campaign storage campaign = ds.campaigns[campaignId];

        if (campaign.id == 0) revert IErrors.NotConfigured(IErrors.Resource.CAMPAIGN, address(uint160(campaignId)));
        if (msg.sender != campaign.manager) revert Unauthorized();
        if (campaign.status != CampaignStatus.ACTIVE && campaign.status != CampaignStatus.PAUSED) {
            revert IErrors.InvalidState();
        }
        if (merkleRoot == bytes32(0)) revert IErrors.InvalidInput();

        // Verify sufficient balance for TOKEN campaigns
        if (campaign.campaignType == CampaignType.TOKENS && totalClaimable > 0) {
            uint256 balance = SafeTransferLib.balanceOf(campaign.rewardToken, address(this));
            // Account for already claimed amounts (stored per campaign)
            uint256 alreadyClaimed = ds.totalClaimed[campaignId];
            uint256 required = totalClaimable > alreadyClaimed ? totalClaimable - alreadyClaimed : 0;

            if (balance < required) {
                revert IErrors.InsufficientAmount(balance, required);
            }
        }

        campaign.merkleRoot = merkleRoot;
        campaign.lastUpdate = updatedAt;
        campaign.totalAllocated = totalClaimable;  // Store for next update

        emit CampaignRootUpdated(campaignId, merkleRoot, updatedAt, totalClaimable);
    }

    /// @inheritdoc IDistributorV1
    function claimCampaign(
        uint256 campaignId,
        uint256 index,
        address account,
        uint256 totalEarned,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        if (msg.sender != account) revert Unauthorized();

        DistributorStorage storage ds = _ds();
        Campaign storage campaign = ds.campaigns[campaignId];

        uint256 claimable = _verifyAndGetClaimable(ds, campaign, campaignId, index, account, totalEarned, merkleProof);
        if (claimable == 0) revert IErrors.InvalidState();

        ds.campaignClaimed[campaignId][account] = totalEarned;
        ds.totalClaimed[campaignId] += claimable;

        if (campaign.campaignType == CampaignType.POINTS) {
            SoulboundToken(campaign.rewardToken).mint(account, claimable);
        } else {
            uint256 available = SafeTransferLib.balanceOf(campaign.rewardToken, address(this));
            if (available < claimable) revert IErrors.InsufficientAmount(available, claimable);
            campaign.rewardToken.safeTransfer(account, claimable);
        }

        emit CampaignClaimed(campaignId, account, claimable, totalEarned);
    }

    /// @inheritdoc IDistributorV1
    function pauseCampaign(uint256 campaignId) external onlyOwner {
        DistributorStorage storage ds = _ds();
        Campaign storage campaign = ds.campaigns[campaignId];

        if (campaign.id == 0) revert IErrors.NotConfigured(IErrors.Resource.CAMPAIGN, address(uint160(campaignId)));
        if (campaign.status != CampaignStatus.ACTIVE) revert IErrors.InvalidState();

        campaign.status = CampaignStatus.PAUSED;
        emit CampaignStatusUpdated(campaignId, CampaignStatus.PAUSED);
    }

    /// @inheritdoc IDistributorV1
    function resumeCampaign(uint256 campaignId) external onlyOwner {
        DistributorStorage storage ds = _ds();
        Campaign storage campaign = ds.campaigns[campaignId];

        if (campaign.id == 0) revert IErrors.NotConfigured(IErrors.Resource.CAMPAIGN, address(uint160(campaignId)));
        if (campaign.status != CampaignStatus.PAUSED) revert IErrors.InvalidState();

        campaign.status = CampaignStatus.ACTIVE;
        emit CampaignStatusUpdated(campaignId, CampaignStatus.ACTIVE);
    }

    /// @inheritdoc IDistributorV1
    function finalizeCampaign(uint256 campaignId) external onlyOwner {
        DistributorStorage storage ds = _ds();
        Campaign storage campaign = ds.campaigns[campaignId];

        if (campaign.id == 0) revert IErrors.NotConfigured(IErrors.Resource.CAMPAIGN, address(uint160(campaignId)));
        if (campaign.campaignType == CampaignType.POINTS) revert IErrors.InvalidInput(); // Use finalizePointsCampaign instead
        if (campaign.status != CampaignStatus.ACTIVE && campaign.status != CampaignStatus.PAUSED) {
            revert IErrors.InvalidState(); // Already finalized
        }

        campaign.status = CampaignStatus.FINALIZED;
        emit CampaignStatusUpdated(campaignId, CampaignStatus.FINALIZED);
    }

    /// @inheritdoc IDistributorV1
    function finalizePointsCampaign(
        uint256 campaignId,
        address redeemToken,
        uint256 redeemRate,
        uint256 maxRedeemable
    ) external {
        DistributorStorage storage ds = _ds();
        Campaign storage campaign = ds.campaigns[campaignId];

        if (campaign.id == 0) revert IErrors.NotConfigured(IErrors.Resource.CAMPAIGN, address(uint160(campaignId)));
        if (campaign.campaignType != CampaignType.POINTS) revert IErrors.InvalidInput();
        if (msg.sender != _s().owner) revert Unauthorized();
        if (campaign.status == CampaignStatus.REDEEMABLE) revert IErrors.InvalidState(); // Already finalized
        if (redeemToken == address(0)) revert IErrors.ZeroValue();
        if (redeemRate == 0) revert IErrors.ZeroValue();

        // Set redemption parameters (immutable once set)
        campaign.redeemToken = redeemToken;
        campaign.redeemRate = redeemRate;
        campaign.maxRedeemable = maxRedeemable;
        campaign.status = CampaignStatus.REDEEMABLE;

        emit PointsCampaignFinalized(campaignId, redeemToken, redeemRate, maxRedeemable);
        emit CampaignStatusUpdated(campaignId, CampaignStatus.REDEEMABLE);
    }

    /// @inheritdoc IDistributorV1
    function redeemPoints(uint256 campaignId, uint256 amount) external nonReentrant {
        if (amount == 0) revert IErrors.ZeroValue();

        DistributorStorage storage ds = _ds();
        Campaign storage campaign = ds.campaigns[campaignId];

        if (campaign.id == 0) revert IErrors.NotConfigured(IErrors.Resource.CAMPAIGN, address(uint160(campaignId)));
        if (campaign.campaignType != CampaignType.POINTS) revert IErrors.InvalidInput();
        if (campaign.status != CampaignStatus.REDEEMABLE) revert IErrors.InvalidState();

        // 1) Calculate tokens to receive
        uint256 tokensOut = (amount * campaign.redeemRate) / 1e18;

        // 2) Check budget cap BEFORE any state changes
        if (campaign.maxRedeemable > 0) {
            uint256 newTotal = campaign.totalRedeemed + tokensOut;
            if (newTotal > campaign.maxRedeemable) {
                revert IErrors.InsufficientAmount(campaign.maxRedeemable - campaign.totalRedeemed, tokensOut);
            }
        }

        // 3) Check distributor has sufficient tokens BEFORE burning
        uint256 available = SafeTransferLib.balanceOf(campaign.redeemToken, address(this));
        if (available < tokensOut) revert IErrors.InsufficientAmount(available, tokensOut);

        // 4) Only after ALL checks pass: burn points, update tracking, and transfer tokens
        SoulboundToken(campaign.rewardToken).burn(msg.sender, amount);

        // Update totalRedeemed AFTER successful burn
        if (campaign.maxRedeemable > 0) {
            campaign.totalRedeemed += tokensOut;
        }

        campaign.redeemToken.safeTransfer(msg.sender, tokensOut);

        emit PointsRedeemed(campaignId, msg.sender, amount, tokensOut);
    }

    // ========== VIEWS ==========

    /// @inheritdoc IDistributorV1
    function getCampaign(uint256 campaignId) external view returns (Campaign memory campaign) {
        return _ds().campaigns[campaignId];
    }

    /// @inheritdoc IDistributorV1
    function getCampaignClaimed(uint256 campaignId, address account) external view returns (uint256) {
        return _ds().campaignClaimed[campaignId][account];
    }

    /// @inheritdoc IDistributorV1
    function getCampaignClaimable(
        uint256 campaignId,
        uint256 index,
        address account,
        uint256 totalEarned,
        bytes32[] calldata merkleProof
    ) external view returns (uint256) {
        DistributorStorage storage ds = _ds();
        Campaign storage campaign = ds.campaigns[campaignId];
        return _verifyAndGetClaimable(ds, campaign, campaignId, index, account, totalEarned, merkleProof);
    }

    // ========== INTERNAL HELPERS ==========

    function _verifyAndGetClaimable(
        DistributorStorage storage ds,
        Campaign storage campaign,
        uint256 campaignId,
        uint256 index,
        address account,
        uint256 totalEarned,
        bytes32[] calldata merkleProof
    ) internal view returns (uint256) {
        if (campaign.id == 0) return 0;
        if (campaign.status != CampaignStatus.ACTIVE) return 0;
        if (campaign.merkleRoot == bytes32(0)) return 0;
        if (totalEarned == 0) return 0;

        uint256 claimed = ds.campaignClaimed[campaignId][account];
        if (totalEarned <= claimed) return 0;

        bytes32 leaf = keccak256(abi.encodePacked(index, account, totalEarned));
        if (!MerkleProofLib.verify(merkleProof, campaign.merkleRoot, leaf)) return 0;

        return totalEarned - claimed;
    }
}
