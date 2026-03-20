// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ITreasuryV1} from "./interfaces/ITreasuryV1.sol";
import {IMintable} from "./interfaces/IMintable.sol";
import {IPoolV1} from "./interfaces/IPoolV1.sol";
import {IAdminV1} from "./interfaces/modules/IAdminV1.sol";
import {IBridgeV1} from "./interfaces/IBridgeV1.sol";
import {IErrors} from "./interfaces/IErrors.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {LibTimelock as TL} from "./libraries/LibTimelock.sol";
import {LibRescue} from "./libraries/LibRescue.sol";
import {LibConstants as C} from "./libraries/LibConstants.sol";

/// @title TreasuryV1
/// @notice Standalone treasury for governance token management, TGE, vesting, and protocol fee collection
/// @dev UUPS upgradeable, not tied to any specific pool - operates as protocol-wide treasury
contract TreasuryV1 is Ownable, ReentrancyGuard, UUPSUpgradeable, ITreasuryV1 {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    // Timelock constants from LibConstants: C.CRITICAL_TIMELOCK, C.GRACE_PERIOD, C.UPGRADE_TIMELOCK

    // Vesting parameters (5yr linear, 6mo cliff, 15% at cliff)
    // Treasury-specific: kept local as vesting is Treasury-specific logic
    uint48 constant CLIFF_DURATION = 180 days;
    uint48 constant VESTING_DURATION = 5 * 365 days;
    uint16 constant CLIFF_PERCENT = 1500; // 15% in basis points

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    address public immutable govToken;

    // TGE
    uint48 public tgeTimestamp;

    // Supply caps
    uint256 public maxSupply;              // Immutable max supply (set at TGE)
    uint256 public totalVestingAllocation; // Sum of all beneficiary allocations

    // Vesting
    mapping(address => VestingSchedule) public vestingSchedules;

    // Emissions (treated as a vesting schedule)
    VestingSchedule public emissionsSchedule;
    address public distributor;
    address public bridge;
    mapping(uint32 => address) public authorizedRemoteDistributor;

    // Timelock for emissions cap changes
    uint96 public pendingEmissionsCapOp;
    uint256 public pendingEmissionsCap;

    // Timelock for ownership transfer
    uint96 public pendingOwnershipOp;
    address public pendingOwner;

    // Upgrade mechanism (separate timelock)
    uint96 public pendingUpgradeOp;
    bytes32 public pendingUpgrade;
    address public pendingImplementation;

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address _govToken) {
        if (_govToken == address(0)) revert IErrors.ZeroValue();
        govToken = _govToken;
    }

    /// @notice Initialize treasury (one-time, called via proxy)
    function initialize(address newOwner) external {
        if (newOwner == address(0)) revert IErrors.ZeroValue();
        // Ensure initialize is only called once
        if (owner() != address(0)) revert IErrors.InvalidState();
        _initializeOwner(newOwner);
    }

    /// @notice Initialize emissions schedule (one-time, owner only)
    /// @dev Should be called after token is deployed with treasury as owner
    function initializeEmissions(uint256 _emissionsCap) external onlyOwner {
        if (_emissionsCap == 0) revert IErrors.ZeroValue();
        if (emissionsSchedule.totalAllocation != 0) revert IErrors.InvalidState();

        // Initialize emissions schedule (off-chain curve determines timing, this only caps total)
        emissionsSchedule = VestingSchedule({
            totalAllocation: _emissionsCap,
            claimed: 0,
            cliffTime: 0,        // No cliff for emissions
            endTime: 0,          // Unused (off-chain determines timing)
            cliffAmount: 0,      // No cliff amount
            suppressor: 10000      // 100% available (curve handled off-chain)
        });

        emit EmissionsInitialized(_emissionsCap);
    }

    /// @notice Enforce global max supply before any mint
    function _enforceMaxSupply(uint256 amount) internal view {
        uint256 ts = IMintable(govToken).totalSupply();
        if (ts + amount > maxSupply) revert IErrors.ExceedsMaxSupply();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MINT / BURN
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Mint governance tokens for non-emissions uses (owner only, treasury/seeding/grants)
    function mintGovToken(address to, uint256 amount) external override onlyOwner {
        if (to == address(0)) revert IErrors.ZeroValue();
        if (amount == 0) revert IErrors.ZeroValue();
        _mintAndTrack(to, amount);
        emit GovTokenMinted(to, amount);
    }

    /// @notice Mint emissions to distributor (owner only, enforces emissions cap)
    function mintEmissionsToDistributor(uint256 amount) external override onlyOwner {
        if (amount == 0) revert IErrors.ZeroValue();
        if (distributor == address(0)) revert IErrors.ZeroValue();

        _checkAndUpdateEmissions(amount);
        _mintAndTrack(distributor, amount);
        emit EmissionsMinted(distributor, amount);
    }

    /// @notice Bridge emissions to remote chain distributor (owner only)
    /// @dev NB: Currently single-chain only - all user claim rights encoded in main chain merkle tree
    /// @dev Users can claim rewards from all chains on the main chain via unified merkle proofs
    /// @dev This function is included for future multi-chain support but should not be used yet
    function bridgeEmissions(uint32 dstEid, uint256 amount, bytes calldata options)
        external
        payable
        override
        onlyOwner
    {
        revert IErrors.FeatureDisabled(IErrors.Resource.BRIDGE);

        if (amount == 0) revert IErrors.ZeroValue();
        if (bridge == address(0)) revert IErrors.ZeroValue();
        address remoteDistributor = authorizedRemoteDistributor[dstEid];
        if (remoteDistributor == address(0)) revert IErrors.ZeroValue();

        _checkAndUpdateEmissions(amount);
        _mintAndTrack(address(this), amount);

        IBridgeV1(bridge).bridgeViaLayerZero{value: msg.value}(
            govToken, dstEid, bytes32(uint256(uint160(remoteDistributor))), amount, options
        );

        emit EmissionsBridged(dstEid, remoteDistributor, amount);
    }

    /// @notice Burn governance tokens (permissionless)
    function burnGovToken(uint256 amount) external override {
        if (amount == 0) revert IErrors.ZeroValue();
        IMintable(govToken).burn(msg.sender, amount);
        emit GovTokenBurned(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TGE & VESTING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Initialize Token Generation Event (one-time, owner only)
    function initializeTGE(
        uint256 treasuryAmount,
        uint256 seedingAmount,
        address[] calldata beneficiaries,
        uint256[] calldata allocations
    ) external override onlyOwner {
        if (tgeTimestamp != 0) revert IErrors.InvalidState();
        if (beneficiaries.length != allocations.length) revert IErrors.InvalidInput();

        tgeTimestamp = uint48(block.timestamp);

        // Calculate total vesting allocation
        uint256 vestingTotal;
        for (uint256 i = 0; i < allocations.length; i++) {
            vestingTotal += allocations[i];
        }
        totalVestingAllocation = vestingTotal;

        // Calculate and set immutable maxSupply
        // maxSupply = initialMint + totalVesting + emissions
        uint256 initialMint = treasuryAmount + seedingAmount;
        maxSupply = initialMint + vestingTotal + emissionsSchedule.totalAllocation;

        // Mint treasury and seeding allocations
        if (treasuryAmount > 0) {
            _enforceMaxSupply(treasuryAmount);
            IMintable(govToken).mint(owner(), treasuryAmount);
        }
        if (seedingAmount > 0) {
            _enforceMaxSupply(seedingAmount);
            IMintable(govToken).mint(owner(), seedingAmount);
        }

        // Setup vesting schedules (5yr linear, 6mo cliff, 15% at cliff)
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            address beneficiary = beneficiaries[i];
            uint256 allocation = allocations[i];

            if (beneficiary == address(0)) revert IErrors.ZeroValue();
            if (allocation == 0) continue;

            uint48 cliffTime = tgeTimestamp + CLIFF_DURATION;
            uint48 endTime = tgeTimestamp + VESTING_DURATION;
            uint128 cliffAmount = uint128((allocation * CLIFF_PERCENT) / 10000);

            vestingSchedules[beneficiary] = VestingSchedule({
                totalAllocation: allocation,
                claimed: 0,
                cliffTime: cliffTime,
                endTime: endTime,
                cliffAmount: cliffAmount,
                suppressor: 10000 // Linear vesting (100%)
            });
        }

        emit TGEInitialized(govToken, treasuryAmount, seedingAmount, tgeTimestamp);
    }

    /// @notice Claim vested tokens
    function claimVested() external override nonReentrant {
        VestingSchedule storage schedule = vestingSchedules[msg.sender];
        if (schedule.totalAllocation == 0) revert IErrors.InvalidState();

        uint256 claimable = getClaimableVested(msg.sender);
        if (claimable == 0) revert IErrors.InvalidState();

        schedule.claimed += claimable;
        _enforceMaxSupply(claimable);
        IMintable(govToken).mint(msg.sender, claimable);
        emit VestingClaimed(msg.sender, claimable);
    }

    /// @notice Get claimable vested amount
    function getClaimableVested(address beneficiary) public view override returns (uint256 claimable) {
        VestingSchedule memory schedule = vestingSchedules[beneficiary];
        if (schedule.totalAllocation == 0) return 0;

        // Before cliff
        if (block.timestamp < schedule.cliffTime) return 0;

        uint256 vested;

        // Linear vesting from cliff to end
        if (block.timestamp < schedule.endTime) {
            uint256 postCliffDuration = uint48(block.timestamp) - schedule.cliffTime;
            uint256 postCliffTotal = schedule.totalAllocation - schedule.cliffAmount;
            uint256 vestingDuration = schedule.endTime - schedule.cliffTime;
            uint256 postCliffVested = (postCliffTotal * postCliffDuration) / vestingDuration;
            vested = schedule.cliffAmount + postCliffVested;
        } else {
            // Fully vested
            vested = schedule.totalAllocation;
        }

        claimable = vested > schedule.claimed ? vested - schedule.claimed : 0;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL FEE COLLECTION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Collect protocol fees from a pool
    /// @dev Anyone can call this - fees are sent to treasury (this contract)
    function collectProtocolFees(address pool, address token) external override nonReentrant {
        if (pool == address(0) || token == address(0)) revert IErrors.ZeroValue();
        IAdminV1(pool).collectProtocolFees(token, address(this));
        emit ProtocolFeesCollected(pool, token, 0); // Amount logged in pool's event
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Request ownership transfer (timelocked)
    function requestOwnershipTransfer(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert IErrors.ZeroValue();
        if (pendingOwnershipOp != 0) revert IErrors.PendingTimelock(uint48(block.timestamp));

        pendingOwnershipOp = TL.pack(C.CRITICAL_TIMELOCK, C.GRACE_PERIOD);
        pendingOwner = newOwner;
    }

    /// @notice Execute ownership transfer
    function executeOwnershipTransfer() external override {
        TL.validate(pendingOwnershipOp);

        address oldOwner = owner();
        address newOwner = pendingOwner;

        _setOwner(newOwner);

        delete pendingOwnershipOp;
        delete pendingOwner;

        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /// @notice Cancel pending ownership transfer
    function cancelOwnershipTransfer() external override onlyOwner {
        if (pendingOwnershipOp == 0) revert IErrors.InvalidState();
        delete pendingOwnershipOp;
        delete pendingOwner;
    }

    /// @notice Set the distributor contract address (owner only)
    function setDistributor(address _distributor) external override onlyOwner {
        if (_distributor == address(0)) revert IErrors.ZeroValue();
        distributor = _distributor;
        emit DistributorSet(_distributor);
    }

    /// @notice Set the bridge contract address (owner only)
    function setBridge(address _bridge) external override onlyOwner {
        if (_bridge == address(0)) revert IErrors.ZeroValue();
        bridge = _bridge;
        emit BridgeSet(_bridge);
    }

    /// @notice Authorize a remote distributor for a destination chain (owner only)
    function authorizeRemoteDistributor(uint32 dstEid, address remoteDistributor) external override onlyOwner {
        if (remoteDistributor == address(0)) revert IErrors.ZeroValue();
        authorizedRemoteDistributor[dstEid] = remoteDistributor;
        emit RemoteDistributorAuthorized(dstEid, remoteDistributor);
    }

    /// @notice Request emissions cap change (timelocked)
    function requestEmissionsCapChange(uint256 newCap) external override onlyOwner {
        VestingSchedule storage es = emissionsSchedule;
        if (newCap < es.claimed) revert IErrors.InvalidInput();
        if (pendingEmissionsCapOp != 0) revert IErrors.PendingTimelock(uint48(block.timestamp));

        pendingEmissionsCapOp = TL.pack(C.CRITICAL_TIMELOCK, C.GRACE_PERIOD);
        pendingEmissionsCap = newCap;
    }

    /// @notice Execute emissions cap change
    function executeEmissionsCapChange() external override {
        TL.validate(pendingEmissionsCapOp);

        VestingSchedule storage es = emissionsSchedule;
        uint256 oldCap = es.totalAllocation;
        uint256 newCap = pendingEmissionsCap;

        // Update emissions schedule
        es.totalAllocation = newCap;

        // Update maxSupply: maxSupply = initialMint + totalVesting + emissions
        maxSupply = (maxSupply - oldCap) + newCap;

        delete pendingEmissionsCapOp;
        delete pendingEmissionsCap;

        emit EmissionsCapChanged(oldCap, newCap);
    }

    /// @notice Cancel pending emissions cap change
    function cancelEmissionsCapChange() external override onlyOwner {
        if (pendingEmissionsCapOp == 0) revert IErrors.InvalidState();
        delete pendingEmissionsCapOp;
        delete pendingEmissionsCap;
    }

    /// @notice Emergency rescue tokens (owner only)
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        LibRescue.rescueToken(token, to, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UPGRADES (UUPS with timelock)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Request contract upgrade (timelocked)
    function requestUpgrade(address newImplementation) external onlyOwner {
        if (newImplementation == address(0)) revert IErrors.ZeroValue();
        if (pendingUpgrade != bytes32(0)) revert IErrors.PendingTimelock(uint48(block.timestamp));

        pendingUpgrade = keccak256(abi.encode(newImplementation, block.timestamp));
        pendingImplementation = newImplementation;

        uint96 timelock = TL.pack(C.UPGRADE_TIMELOCK, C.GRACE_PERIOD);
        pendingUpgradeOp = timelock;

        emit UpgradeAuthorized(pendingUpgrade, newImplementation, uint48(timelock >> 48));
    }

    /// @notice Execute contract upgrade after timelock
    function executeUpgrade() external onlyOwner {
        if (pendingUpgrade == bytes32(0)) revert IErrors.InvalidState();
        TL.validate(pendingUpgradeOp);

        address newImpl = pendingImplementation;
        bytes32 upgradeId = pendingUpgrade;

        delete pendingUpgrade;
        delete pendingImplementation;
        delete pendingUpgradeOp;

        this.upgradeToAndCall(newImpl, "");
    }

    /// @notice Cancel pending upgrade request
    function cancelUpgrade() external onlyOwner {
        if (pendingUpgrade == bytes32(0)) revert IErrors.InvalidState();

        bytes32 upgradeId = pendingUpgrade;
        delete pendingUpgrade;
        delete pendingImplementation;
        delete pendingUpgradeOp;

        emit UpgradeCancelled(upgradeId);
    }

    /// @notice UUPS upgrade authorization (required by UUPSUpgradeable)
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEWS
    // ═══════════════════════════════════════════════════════════════════════════

    function getTotalSupply() external view override returns (uint256) {
        return IMintable(govToken).totalSupply();
    }

    function getMaxSupply() external view override returns (uint256) {
        return maxSupply;
    }

    function getRemainingMintable() external view override returns (uint256) {
        uint256 ts = IMintable(govToken).totalSupply();
        return maxSupply > ts ? maxSupply - ts : 0;
    }

    function emissionsCap() external view override returns (uint256) {
        return emissionsSchedule.totalAllocation;
    }

    function emissionsMinted() external view override returns (uint256) {
        return emissionsSchedule.claimed;
    }

    function getTGETimestamp() external view override returns (uint48) {
        return tgeTimestamp;
    }

    function getVestingSchedule(address beneficiary) external view override returns (VestingSchedule memory schedule) {
        return vestingSchedules[beneficiary];
    }

    // ========== INTERNAL HELPERS ==========

    function _mintAndTrack(address to, uint256 amount) internal {
        _enforceMaxSupply(amount);
        IMintable(govToken).mint(to, amount);
    }

    function _checkAndUpdateEmissions(uint256 amount) internal {
        VestingSchedule storage es = emissionsSchedule;
        uint256 newClaimed = es.claimed + amount;
        if (newClaimed > es.totalAllocation) revert IErrors.ExceedsMaxSupply();
        es.claimed = newClaimed;
    }

    receive() external payable {}
}
