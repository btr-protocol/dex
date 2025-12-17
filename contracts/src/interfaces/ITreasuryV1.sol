// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IErrors} from "./IErrors.sol";

/// @title ITreasuryV1
/// @notice Standalone treasury contract for BTR token management and protocol fee collection
interface ITreasuryV1 is IErrors {
    // ═══════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Vesting beneficiary information
    struct VestingSchedule {
        uint256 totalAllocation;     // Total vested amount
        uint256 claimed;             // Amount already claimed
        uint48 cliffTime;            // Timestamp when cliff ends
        uint48 endTime;              // Timestamp when vesting ends
        uint128 cliffAmount;         // Amount unlocked at cliff
        uint16 suppressor;           // Vesting curve shape (10000 = linear, default)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event GovTokenMinted(address indexed to, uint256 amount);
    event GovTokenBurned(address indexed from, uint256 amount);
    event TGEInitialized(address indexed govToken, uint256 treasuryAmount, uint256 seedingAmount, uint48 timestamp);
    event VestingClaimed(address indexed beneficiary, uint256 amount);
    event ProtocolFeesCollected(address indexed pool, address indexed token, uint256 amount);
    event UpgradeAuthorized(bytes32 indexed upgradeId, address newImplementation, uint48 executableAt);
    event UpgradeCancelled(bytes32 indexed upgradeId);
    event EmissionsInitialized(uint256 emissionsCap);
    event EmissionsMinted(address indexed distributor, uint256 amount);
    event EmissionsBridged(uint32 indexed dstEid, address indexed remoteDistributor, uint256 amount);
    event DistributorSet(address indexed distributor);
    event BridgeSet(address indexed bridge);
    event RemoteDistributorAuthorized(uint32 indexed dstEid, address indexed remoteDistributor);
    event EmissionsCapChanged(uint256 oldCap, uint256 newCap);

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════
    // All errors inherited from IErrors - see IErrors.sol for details

    // ═══════════════════════════════════════════════════════════════════════════
    // MINT / BURN
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Mint governance tokens for non-emissions uses (owner only, treasury/seeding/grants)
    /// @param to Recipient address
    /// @param amount Amount to mint
    function mintGovToken(address to, uint256 amount) external;

    /// @notice Mint emissions to distributor (owner only, enforces emissions cap)
    /// @param amount Amount to mint to distributor
    function mintEmissionsToDistributor(uint256 amount) external;

    /// @notice Bridge emissions to remote chain distributor (owner only)
    /// @dev NOTE: Currently single-chain only - all user claim rights encoded in main chain merkle tree
    /// @dev Users can claim rewards from all chains on the main chain via unified merkle proofs
    /// @param dstEid Destination endpoint ID
    /// @param amount Amount to bridge
    /// @param options LayerZero message options
    function bridgeEmissions(uint32 dstEid, uint256 amount, bytes calldata options) external payable;

    /// @notice Burn governance tokens (permissionless, anyone can burn their own)
    /// @param amount Amount to burn
    function burnGovToken(uint256 amount) external;

    // ═══════════════════════════════════════════════════════════════════════════
    // TGE & VESTING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Initialize Token Generation Event (one-time, owner only)
    /// @dev Sets maxSupply = initialMint + totalVesting + emissionsCap (immutable after TGE)
    /// @param treasuryAmount Amount to mint to treasury owner
    /// @param seedingAmount Amount to mint for initial liquidity seeding (LBP, airdrop, or other distribution)
    /// @param beneficiaries Array of vesting beneficiaries
    /// @param allocations Array of vesting allocations (matched to beneficiaries)
    function initializeTGE(
        uint256 treasuryAmount,
        uint256 seedingAmount,
        address[] calldata beneficiaries,
        uint256[] calldata allocations
    ) external;

    /// @notice Claim vested tokens (5yr linear, 6mo cliff, 15% at cliff)
    function claimVested() external;

    /// @notice Get claimable vested amount for a beneficiary
    /// @param beneficiary Address to check
    /// @return claimable Amount that can be claimed now
    function getClaimableVested(address beneficiary) external view returns (uint256 claimable);

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL FEE COLLECTION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Collect protocol fees from a pool (anyone can call, fees sent to treasury)
    /// @param pool Pool address to collect from
    /// @param token Token to collect
    function collectProtocolFees(address pool, address token) external;

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Request ownership transfer (timelocked)
    /// @param newOwner New owner address
    function requestOwnershipTransfer(address newOwner) external;

    /// @notice Execute ownership transfer after timelock
    function executeOwnershipTransfer() external;

    /// @notice Cancel pending ownership transfer
    function cancelOwnershipTransfer() external;

    /// @notice Set the distributor contract address (owner only, timelocked)
    /// @param distributor Distributor address
    function setDistributor(address distributor) external;

    /// @notice Set the bridge contract address (owner only, timelocked)
    /// @param bridge Bridge address
    function setBridge(address bridge) external;

    /// @notice Authorize a remote distributor for a destination chain (owner only, timelocked)
    /// @param dstEid Destination endpoint ID
    /// @param remoteDistributor Remote distributor address
    function authorizeRemoteDistributor(uint32 dstEid, address remoteDistributor) external;

    /// @notice Request emissions cap change (timelocked)
    /// @param newCap New emissions cap
    function requestEmissionsCapChange(uint256 newCap) external;

    /// @notice Execute emissions cap change after timelock
    function executeEmissionsCapChange() external;

    /// @notice Cancel pending emissions cap change
    function cancelEmissionsCapChange() external;

    // ═══════════════════════════════════════════════════════════════════════════
    // UPGRADES (UUPS with timelock)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Request contract upgrade (timelocked)
    /// @param newImplementation New implementation address
    function requestUpgrade(address newImplementation) external;

    /// @notice Execute contract upgrade after timelock
    function executeUpgrade() external;

    /// @notice Cancel pending upgrade request
    function cancelUpgrade() external;

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEWS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Get current BTR total supply
    /// @return Total supply
    function getTotalSupply() external view returns (uint256);

    /// @notice Get maximum BTR supply
    /// @return Maximum supply
    function getMaxSupply() external view returns (uint256);

    /// @notice Get remaining mintable BTR
    /// @return Remaining mintable amount
    function getRemainingMintable() external view returns (uint256);

    /// @notice Get TGE timestamp
    /// @return TGE timestamp (0 if not initialized)
    function getTGETimestamp() external view returns (uint48);

    /// @notice Get vesting schedule for a beneficiary
    /// @param beneficiary Address to check
    /// @return schedule Vesting schedule data
    function getVestingSchedule(address beneficiary) external view returns (VestingSchedule memory schedule);

    /// @notice Get governance token address
    /// @return Governance token address
    function govToken() external view returns (address);

    /// @notice Get distributor address
    /// @return Distributor address
    function distributor() external view returns (address);

    /// @notice Get bridge address
    /// @return Bridge address
    function bridge() external view returns (address);

    /// @notice Get emissions cap
    /// @return Emissions cap
    function emissionsCap() external view returns (uint256);

    /// @notice Get total emissions minted
    /// @return Total emissions minted
    function emissionsMinted() external view returns (uint256);

    /// @notice Get authorized remote distributor for a destination chain
    /// @param dstEid Destination endpoint ID
    /// @return Remote distributor address
    function authorizedRemoteDistributor(uint32 dstEid) external view returns (address);
}
