// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title ITreasury — BTR token, vesting, emissions, protocol fees
interface ITreasury {
    struct VestingSchedule {
        uint256 totalAllocation;
        uint256 claimed;
        uint48 cliffTime;
        uint48 endTime;
        uint128 cliffAmount;
        uint16 suppressor;
    }

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
    event Salvaged(address indexed token, address indexed to, uint256 amount);

    function mintGovToken(address to, uint256 amount) external;
    function mintEmissionsToDistributor(uint256 amount) external;
    function bridgeEmissions(uint32 dstEid, uint256 amount, bytes calldata options) external payable;
    function burnGovToken(uint256 amount) external;

    /// @notice TGE: maxSupply = treasuryAmount + seedingAmount + Σ allocations + emissionsCap (immutable)
    function initializeTGE(
        uint256 treasuryAmount,
        uint256 seedingAmount,
        address[] calldata beneficiaries,
        uint256[] calldata allocations
    ) external;

    function claimVested() external;
    function getClaimableVested(address beneficiary) external view returns (uint256 claimable);
    function collectProtocolFees(address pool, address token) external;

    function requestOwnershipTransfer(address newOwner) external;
    function executeOwnershipTransfer() external;
    function cancelOwnershipTransfer() external;
    function setDistributor(address distributor) external;
    function setBridge(address bridge) external;
    function authorizeRemoteDistributor(uint32 dstEid, address remoteDistributor) external;
    function requestEmissionsCapChange(uint256 newCap) external;
    function executeEmissionsCapChange() external;
    function cancelEmissionsCapChange() external;
    function requestUpgrade(address newImplementation) external;
    function executeUpgrade() external;
    function cancelUpgrade() external;

    function getTotalSupply() external view returns (uint256);
    function getMaxSupply() external view returns (uint256);
    function getRemainingMintable() external view returns (uint256);
    function getTGETimestamp() external view returns (uint48);
    function getVestingSchedule(address beneficiary) external view returns (VestingSchedule memory schedule);
    function govToken() external view returns (address);
    function distributor() external view returns (address);
    function bridge() external view returns (address);
    function emissionsCap() external view returns (uint256);
    function emissionsMinted() external view returns (uint256);
    function authorizedRemoteDistributor(uint32 dstEid) external view returns (address);
}
