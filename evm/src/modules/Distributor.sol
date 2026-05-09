// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Base} from "./Base.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Err} from "@btr-peripheral/Errors.sol";
import {IDistributor} from "../interfaces/modules/IDistributor.sol";
import {IPool} from "../interfaces/IPool.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";
import {SoulboundToken} from "../tokens/SoulboundToken.sol";

/// @title Distributor — campaign-based cumulative Merkle distributor (POINTS=SBT, TOKENS=ERC20)
/// @dev Manager/treasury MUST pre-fund w/ rewardToken before claims; reverts on shortfall.
contract Distributor is Base, IDistributor {
    using SafeTransferLib for address;

    function _ds() internal pure returns (DistributorStorage storage $) {
        bytes32 slot = C.DISTRIBUTOR_STORAGE_LOC;
        assembly { $.slot := slot }
    }

    function _campaign(uint256 campaignId) private view returns (DistributorStorage storage ds, Campaign storage c) {
        ds = _ds();
        c = ds.campaigns[campaignId];
        if (c.id == 0) revert Err.NotConfigured(Err.Resource.CAMPAIGN, address(uint160(campaignId)));
    }

    /// @dev F-A2-R14-3 (MED) fix: nextCampaignId defaults to 0 in fresh storage. Without this
    ///      lazy bump, the first `create*Campaign` call would assign `c.id = 0`, then `_campaign()`
    ///      would reject every mutating op for it (DoS + orphaned SBT). We always emit ids ≥ 1.
    function _nextId(DistributorStorage storage ds) private returns (uint256 id) {
        if (ds.nextCampaignId == 0) ds.nextCampaignId = 1;
        id = ds.nextCampaignId++;
    }

    function createPointsCampaign(
        string calldata name,
        string calldata symbol,
        address manager
    ) external onlyOwner returns (uint256 campaignId, address sbtToken) {
        if (manager == address(0)) revert Err.ZeroValue();
        DistributorStorage storage ds = _ds();
        campaignId = _nextId(ds);
        sbtToken = address(new SoulboundToken(name, symbol, address(this)));

        Campaign storage c = ds.campaigns[campaignId];
        c.id = campaignId;
        c.campaignType = CampaignType.POINTS;
        c.status = CampaignStatus.ACTIVE;
        c.rewardToken = sbtToken;
        c.manager = manager;
        emit CampaignCreated(campaignId, CampaignType.POINTS, sbtToken, manager);
    }

    function createTokenCampaign(address rewardToken, address manager) external onlyOwner returns (uint256 campaignId) {
        if (rewardToken == address(0) || manager == address(0)) revert Err.ZeroValue();
        DistributorStorage storage ds = _ds();
        campaignId = _nextId(ds);

        Campaign storage c = ds.campaigns[campaignId];
        c.id = campaignId;
        c.campaignType = CampaignType.TOKENS;
        c.status = CampaignStatus.ACTIVE;
        c.rewardToken = rewardToken;
        c.manager = manager;
        emit CampaignCreated(campaignId, CampaignType.TOKENS, rewardToken, manager);
    }

    function updateCampaignRoot(
        uint256 campaignId,
        bytes32 merkleRoot,
        uint32 updatedAt,
        uint256 totalClaimable
    ) external {
        (DistributorStorage storage ds, Campaign storage c) = _campaign(campaignId);
        if (msg.sender != c.manager) revert Ownable.Unauthorized();
        if (c.status != CampaignStatus.ACTIVE && c.status != CampaignStatus.PAUSED) revert Err.InvalidState();
        if (merkleRoot == bytes32(0)) revert Err.InvalidInput();

        // F-A1-R11-2 (INFO) fix: forbid lowering totalAllocated below already-claimed.
        // Otherwise `claimCampaign` line `ds.totalClaimed[campaignId] > c.totalAllocated`
        // (Phase 42D A3-4 guard) would revert for ALL future claimants until next root update.
        if (totalClaimable < ds.totalClaimed[campaignId]) revert Err.InvalidInput();

        if (c.campaignType == CampaignType.TOKENS && totalClaimable > 0) {
            uint256 balance = SafeTransferLib.balanceOf(c.rewardToken, address(this));
            uint256 alreadyClaimed = ds.totalClaimed[campaignId];
            uint256 required = totalClaimable > alreadyClaimed ? totalClaimable - alreadyClaimed : 0;
            if (balance < required) revert Err.InsufficientAmount(balance, required);
        }

        c.merkleRoot = merkleRoot;
        c.lastUpdate = updatedAt;
        c.totalAllocated = totalClaimable;
        emit CampaignRootUpdated(campaignId, merkleRoot, updatedAt, totalClaimable);
    }

    function claimCampaign(
        uint256 campaignId,
        uint256 index,
        address account,
        uint256 totalEarned,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        if (msg.sender != account) revert Ownable.Unauthorized();
        (DistributorStorage storage ds, Campaign storage c) = _campaign(campaignId);

        uint256 claimable = _verifyAndGetClaimable(ds, c, campaignId, index, account, totalEarned, merkleProof);
        if (claimable == 0) revert Err.InvalidState();

        ds.campaignClaimed[campaignId][account] = totalEarned;
        ds.totalClaimed[campaignId] += claimable;
        // Phase 42D A3-4: enforce totalClaimed cap; prevents over-spend if off-chain root signer
        // mistakenly publishes a tree summing > totalAllocated.
        if (ds.totalClaimed[campaignId] > c.totalAllocated) revert Err.InvalidState();

        if (c.campaignType == CampaignType.POINTS) {
            SoulboundToken(c.rewardToken).mint(account, claimable);
        } else {
            uint256 available = SafeTransferLib.balanceOf(c.rewardToken, address(this));
            if (available < claimable) revert Err.InsufficientAmount(available, claimable);
            c.rewardToken.safeTransfer(account, claimable);
        }
        emit CampaignClaimed(campaignId, account, claimable, totalEarned);
    }

    function pauseCampaign(uint256 campaignId) external onlyOwner {
        (, Campaign storage c) = _campaign(campaignId);
        if (c.status != CampaignStatus.ACTIVE) revert Err.InvalidState();
        c.status = CampaignStatus.PAUSED;
        emit CampaignStatusUpdated(campaignId, CampaignStatus.PAUSED);
    }

    function resumeCampaign(uint256 campaignId) external onlyOwner {
        (, Campaign storage c) = _campaign(campaignId);
        if (c.status != CampaignStatus.PAUSED) revert Err.InvalidState();
        c.status = CampaignStatus.ACTIVE;
        emit CampaignStatusUpdated(campaignId, CampaignStatus.ACTIVE);
    }

    function finalizeCampaign(uint256 campaignId) external onlyOwner {
        (, Campaign storage c) = _campaign(campaignId);
        if (c.campaignType == CampaignType.POINTS) revert Err.InvalidInput(); // use finalizePointsCampaign
        if (c.status != CampaignStatus.ACTIVE && c.status != CampaignStatus.PAUSED) revert Err.InvalidState();
        c.status = CampaignStatus.FINALIZED;
        emit CampaignStatusUpdated(campaignId, CampaignStatus.FINALIZED);
    }

    function finalizePointsCampaign(
        uint256 campaignId,
        address redeemToken,
        uint256 redeemRate,
        uint256 maxRedeemable
    ) external {
        (, Campaign storage c) = _campaign(campaignId);
        if (c.campaignType != CampaignType.POINTS) revert Err.InvalidInput();
        if (msg.sender != _owner()) revert Ownable.Unauthorized();
        if (c.status == CampaignStatus.REDEEMABLE) revert Err.InvalidState();
        if (redeemToken == address(0) || redeemRate == 0) revert Err.ZeroValue();

        c.redeemToken = redeemToken;
        c.redeemRate = redeemRate;
        c.maxRedeemable = maxRedeemable;
        c.status = CampaignStatus.REDEEMABLE;

        emit PointsCampaignFinalized(campaignId, redeemToken, redeemRate, maxRedeemable);
        emit CampaignStatusUpdated(campaignId, CampaignStatus.REDEEMABLE);
    }

    function redeemPoints(uint256 campaignId, uint256 amount) external nonReentrant {
        if (amount == 0) revert Err.ZeroValue();
        (, Campaign storage c) = _campaign(campaignId);
        if (c.campaignType != CampaignType.POINTS) revert Err.InvalidInput();
        if (c.status != CampaignStatus.REDEEMABLE) revert Err.InvalidState();

        // F-A4-R15-1 (INFO): `amount * c.redeemRate` is unchecked-arith. Realistic bound analysis:
        // `amount` is bounded by the redeemer's SBT balance, itself bounded by `c.totalAllocated`
        // (Phase 42D A3-4 guard caps `totalClaimed <= totalAllocated`). `c.redeemRate` is operator-set
        // at finalize time (typically ≤ 1e18 for ≤ 1:1 redemption). Headroom: 2^256 / 1e18 ≈ 1.16e59.
        // For overflow, `amount * redeemRate > 2^256` ⇒ requires e.g. amount > 1e58 with redeemRate=1e18,
        // far exceeding any realistic SBT supply. INFO-level theoretical surface; not reachable.
        uint256 tokensOut = (amount * c.redeemRate) / 1e18;

        // budget cap check BEFORE state changes
        if (c.maxRedeemable > 0) {
            uint256 newTotal = c.totalRedeemed + tokensOut;
            if (newTotal > c.maxRedeemable) {
                revert Err.InsufficientAmount(c.maxRedeemable - c.totalRedeemed, tokensOut);
            }
        }

        // funding check BEFORE burn
        uint256 available = SafeTransferLib.balanceOf(c.redeemToken, address(this));
        if (available < tokensOut) revert Err.InsufficientAmount(available, tokensOut);

        SoulboundToken(c.rewardToken).burn(msg.sender, amount);
        // F-A2-R15-2 (INFO) fix: accumulate `totalRedeemed` unconditionally (was gated on
        // `maxRedeemable > 0`). Off-chain dashboards rely on this counter for unbounded campaigns
        // too. No on-chain logic depends on the gating; safe & non-breaking sweep.
        c.totalRedeemed += tokensOut;
        c.redeemToken.safeTransfer(msg.sender, tokensOut);

        emit PointsRedeemed(campaignId, msg.sender, amount, tokensOut);
    }


    function getCampaign(uint256 campaignId) external view returns (Campaign memory) {
        return _ds().campaigns[campaignId];
    }

    function getCampaignClaimed(uint256 campaignId, address account) external view returns (uint256) {
        return _ds().campaignClaimed[campaignId][account];
    }

    function getCampaignClaimable(
        uint256 campaignId,
        uint256 index,
        address account,
        uint256 totalEarned,
        bytes32[] calldata merkleProof
    ) external view returns (uint256) {
        DistributorStorage storage ds = _ds();
        Campaign storage c = ds.campaigns[campaignId];
        return _verifyAndGetClaimable(ds, c, campaignId, index, account, totalEarned, merkleProof);
    }

    function _verifyAndGetClaimable(
        DistributorStorage storage ds,
        Campaign storage c,
        uint256 campaignId,
        uint256 index,
        address account,
        uint256 totalEarned,
        bytes32[] calldata merkleProof
    ) internal view returns (uint256) {
        if (c.id == 0 || c.status != CampaignStatus.ACTIVE || c.merkleRoot == bytes32(0) || totalEarned == 0) return 0;
        uint256 claimed = ds.campaignClaimed[campaignId][account];
        if (totalEarned <= claimed) return 0;

        // F-A2-R14-2 (LOW) fix: include campaignId in leaf for domain separation.
        // Pre-fix: managers reusing the same root across campaigns enabled cross-campaign proof replay.
        bytes32 leaf = keccak256(abi.encodePacked(campaignId, index, account, totalEarned));
        if (!MerkleProofLib.verify(merkleProof, c.merkleRoot, leaf)) return 0;
        return totalEarned - claimed;
    }
}
