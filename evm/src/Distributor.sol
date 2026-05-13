// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IDistributor} from "./interfaces/IDistributor.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Err} from "@btr-shared/Errors.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";

/// @title Distributor
/// @notice Standalone singleton campaign-based cumulative Merkle distributor (ERC-20 only).
/// @dev Phase 42H.B.3c -Distributor no longer delegatecalls into Pool. It is a fully
///      independent singleton. State is keyed by (pool, ...) so a single deployment serves
///      every pool. The reward-token escrow lives at this contract's address; managers
///      MUST pre-fund it before claims (reverts on shortfall). Owner authority routes
///      through the shared singleton AccessControl.
contract Distributor is IDistributor, ReentrancyGuardTransient {
    using SafeTransferLib for address;

    /// @notice Shared singleton AccessControl -single source of truth for owner.
    address public immutable AC;

    /// @dev Per-pool campaign id counter.
    mapping(address pool => uint256) public nextCampaignId;
    /// @dev (pool, campaignId) → Campaign.
    mapping(address pool => mapping(uint256 => Campaign)) internal _campaigns;
    /// @dev (pool, campaignId, account) → cumulative-claimed totalEarned snapshot.
    mapping(address pool => mapping(uint256 => mapping(address => uint256))) internal _campaignClaimed;
    /// @dev (pool, campaignId) → totalClaimed across all accounts.
    mapping(address pool => mapping(uint256 => uint256)) internal _totalClaimed;

    constructor(address ac_) {
        if (ac_ == address(0)) revert Err.ZeroAddr();
        AC = ac_;
    }

    modifier onlyOwner() {
        if (msg.sender != AccessControl(AC).owner()) revert Ownable.Unauthorized();
        _;
    }

    function _load(address pool, uint256 campaignId) private view returns (Campaign storage c) {
        c = _campaigns[pool][campaignId];
        if (c.id == 0) revert Err.NotConfigured(Err.Resource.CAMPAIGN, address(uint160(campaignId)));
    }

    /// @dev F-A2-R14-3 (MED) fix preserved: lazy-bump nextCampaignId so first id is 1, never 0.
    function _nextId(address pool) private returns (uint256 id) {
        if (nextCampaignId[pool] == 0) nextCampaignId[pool] = 1;
        id = nextCampaignId[pool]++;
    }

    function createTokenCampaign(address pool, address rewardToken, address manager)
        external onlyOwner returns (uint256 campaignId)
    {
        if (rewardToken == address(0) || manager == address(0)) revert Err.ZeroValue();
        campaignId = _nextId(pool);

        Campaign storage c = _campaigns[pool][campaignId];
        c.id = campaignId;
        c.status = CampaignStatus.ACTIVE;
        c.rewardToken = rewardToken;
        c.manager = manager;
        emit CampaignCreated(pool, campaignId, rewardToken, manager);
    }

    function updateCampaignRoot(
        address pool,
        uint256 campaignId,
        bytes32 merkleRoot,
        uint32 updatedAt,
        uint256 totalClaimable
    ) external {
        Campaign storage c = _load(pool, campaignId);
        if (msg.sender != c.manager) revert Ownable.Unauthorized();
        if (c.status != CampaignStatus.ACTIVE && c.status != CampaignStatus.PAUSED) revert Err.InvalidState();
        if (merkleRoot == bytes32(0)) revert Err.InvalidInput();

        // F-A1-R11-2 (INFO) fix preserved: forbid lowering totalAllocated below already-claimed.
        uint256 alreadyClaimed = _totalClaimed[pool][campaignId];
        if (totalClaimable < alreadyClaimed) revert Err.InvalidInput();

        if (totalClaimable > 0) {
            uint256 balance = SafeTransferLib.balanceOf(c.rewardToken, address(this));
            uint256 required = totalClaimable > alreadyClaimed ? totalClaimable - alreadyClaimed : 0;
            if (balance < required) revert Err.InsufficientAmount(balance, required);
        }

        c.merkleRoot = merkleRoot;
        c.lastUpdate = updatedAt;
        c.totalAllocated = totalClaimable;
        emit CampaignRootUpdated(pool, campaignId, merkleRoot, updatedAt, totalClaimable);
    }

    function claimCampaign(
        address pool,
        uint256 campaignId,
        uint256 index,
        address account,
        uint256 totalEarned,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        if (msg.sender != account) revert Ownable.Unauthorized();
        Campaign storage c = _load(pool, campaignId);

        uint256 claimable = _verifyAndGetClaimable(pool, c, campaignId, index, account, totalEarned, merkleProof);
        if (claimable == 0) revert Err.InvalidState();

        _campaignClaimed[pool][campaignId][account] = totalEarned;
        _totalClaimed[pool][campaignId] += claimable;
        // Phase 42D A3-4 cap preserved.
        if (_totalClaimed[pool][campaignId] > c.totalAllocated) revert Err.InvalidState();

        uint256 available = SafeTransferLib.balanceOf(c.rewardToken, address(this));
        if (available < claimable) revert Err.InsufficientAmount(available, claimable);
        c.rewardToken.safeTransfer(account, claimable);
        emit CampaignClaimed(pool, campaignId, account, claimable, totalEarned);
    }

    function pauseCampaign(address pool, uint256 campaignId) external onlyOwner {
        Campaign storage c = _load(pool, campaignId);
        if (c.status != CampaignStatus.ACTIVE) revert Err.InvalidState();
        c.status = CampaignStatus.PAUSED;
        emit CampaignStatusUpdated(pool, campaignId, CampaignStatus.PAUSED);
    }

    function resumeCampaign(address pool, uint256 campaignId) external onlyOwner {
        Campaign storage c = _load(pool, campaignId);
        if (c.status != CampaignStatus.PAUSED) revert Err.InvalidState();
        c.status = CampaignStatus.ACTIVE;
        emit CampaignStatusUpdated(pool, campaignId, CampaignStatus.ACTIVE);
    }

    function finalizeCampaign(address pool, uint256 campaignId) external onlyOwner {
        Campaign storage c = _load(pool, campaignId);
        if (c.status != CampaignStatus.ACTIVE && c.status != CampaignStatus.PAUSED) revert Err.InvalidState();
        c.status = CampaignStatus.FINALIZED;
        emit CampaignStatusUpdated(pool, campaignId, CampaignStatus.FINALIZED);
    }

    // ── views ──

    function getCampaign(address pool, uint256 campaignId) external view returns (Campaign memory) {
        return _campaigns[pool][campaignId];
    }

    function getCampaignClaimed(address pool, uint256 campaignId, address account) external view returns (uint256) {
        return _campaignClaimed[pool][campaignId][account];
    }

    function getCampaignClaimable(
        address pool,
        uint256 campaignId,
        uint256 index,
        address account,
        uint256 totalEarned,
        bytes32[] calldata merkleProof
    ) external view returns (uint256) {
        Campaign storage c = _campaigns[pool][campaignId];
        return _verifyAndGetClaimable(pool, c, campaignId, index, account, totalEarned, merkleProof);
    }

    /// @notice Total claimed across all accounts for a campaign.
    function getTotalClaimed(address pool, uint256 campaignId) external view returns (uint256) {
        return _totalClaimed[pool][campaignId];
    }

    function _verifyAndGetClaimable(
        address pool,
        Campaign storage c,
        uint256 campaignId,
        uint256 index,
        address account,
        uint256 totalEarned,
        bytes32[] calldata merkleProof
    ) internal view returns (uint256) {
        if (c.id == 0 || c.status != CampaignStatus.ACTIVE || c.merkleRoot == bytes32(0) || totalEarned == 0) return 0;
        uint256 claimed = _campaignClaimed[pool][campaignId][account];
        if (totalEarned <= claimed) return 0;

        // F-A2-R14-2 (LOW) fix preserved: include (pool, campaignId) in leaf for domain separation.
        bytes32 leaf = keccak256(abi.encodePacked(pool, campaignId, index, account, totalEarned));
        if (!MerkleProofLib.verify(merkleProof, c.merkleRoot, leaf)) return 0;
        return totalEarned - claimed;
    }
}
