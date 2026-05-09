// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ITreasury} from "./interfaces/ITreasury.sol";
import {IMintable} from "./interfaces/IMintable.sol";
import {IPool} from "./interfaces/IPool.sol";
import {IAdmin} from "./interfaces/modules/IAdmin.sol";
import {IBridge} from "./interfaces/IBridge.sol";
import {Err} from "@btr-peripheral/Errors.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {LibTimelock as TL} from "./libraries/LibTimelock.sol";
import {LibRescue} from "./libraries/LibRescue.sol";
import {LibConstants as C} from "./libraries/LibConstants.sol";

/// @title Treasury
/// @notice Standalone treasury for gov token, TGE, vesting, and protocol fee collection.
contract Treasury is Ownable, ReentrancyGuard, UUPSUpgradeable, ITreasury {
    // Vesting params: 5yr linear, 6mo cliff, 15% at cliff.
    uint48 constant CLIFF_DURATION = 180 days;
    uint48 constant VESTING_DURATION = 5 * 365 days;
    uint16 constant CLIFF_PERCENT = 1500;

    address public immutable govToken;

    uint48 public tgeTimestamp;
    uint256 public maxSupply;
    uint256 public totalVestingAllocation;

    mapping(address => VestingSchedule) public vestingSchedules;
    VestingSchedule public emissionsSchedule;
    address public distributor;
    address public bridge;
    mapping(uint32 => address) public authorizedRemoteDistributor;

    uint96 public pendingEmissionsCapOp;
    uint256 public pendingEmissionsCap;

    uint96 public pendingOwnershipOp;
    address public pendingOwner;

    uint96 public pendingUpgradeOp;
    bytes32 public pendingUpgrade;
    address public pendingImplementation;

    constructor(address _govToken) {
        if (_govToken == address(0)) revert Err.ZeroValue();
        govToken = _govToken;
    }

    function initialize(address newOwner) external {
        if (newOwner == address(0)) revert Err.ZeroValue();
        if (owner() != address(0)) revert Err.InvalidState();
        _initializeOwner(newOwner);
    }

    function initializeEmissions(uint256 _emissionsCap) external onlyOwner {
        if (_emissionsCap == 0) revert Err.ZeroValue();
        if (emissionsSchedule.totalAllocation != 0) revert Err.InvalidState();
        emissionsSchedule = VestingSchedule({
            totalAllocation: _emissionsCap,
            claimed: 0,
            cliffTime: 0,
            endTime: 0,
            cliffAmount: 0,
            suppressor: 10000
        });
        emit EmissionsInitialized(_emissionsCap);
    }

    function _enforceMaxSupply(uint256 amount) internal view {
        if (IMintable(govToken).totalSupply() + amount > maxSupply) revert Err.ExceedsMaxSupply();
    }

    function _mintAndTrack(address to, uint256 amount) internal {
        _enforceMaxSupply(amount);
        IMintable(govToken).mint(to, amount);
    }

    function _checkAndUpdateEmissions(uint256 amount) internal {
        VestingSchedule storage es = emissionsSchedule;
        uint256 newClaimed = es.claimed + amount;
        if (newClaimed > es.totalAllocation) revert Err.ExceedsMaxSupply();
        es.claimed = newClaimed;
    }

    // ─── mint/burn ───

    function mintGovToken(address to, uint256 amount) external override onlyOwner {
        if (to == address(0) || amount == 0) revert Err.ZeroValue();
        _mintAndTrack(to, amount);
        emit GovTokenMinted(to, amount);
    }

    function mintEmissionsToDistributor(uint256 amount) external override onlyOwner {
        if (amount == 0 || distributor == address(0)) revert Err.ZeroValue();
        _checkAndUpdateEmissions(amount);
        _mintAndTrack(distributor, amount);
        emit EmissionsMinted(distributor, amount);
    }

    /// @notice Disabled: single-chain only; kept for future multi-chain.
    function bridgeEmissions(uint32, uint256, bytes calldata)
        external payable override onlyOwner
    {
        revert Err.FeatureDisabled(Err.Resource.BRIDGE);
    }

    function burnGovToken(uint256 amount) external override {
        if (amount == 0) revert Err.ZeroValue();
        IMintable(govToken).burn(msg.sender, amount);
        emit GovTokenBurned(msg.sender, amount);
    }

    // ─── TGE & vesting ───

    function initializeTGE(
        uint256 treasuryAmount,
        uint256 seedingAmount,
        address[] calldata beneficiaries,
        uint256[] calldata allocations
    ) external override onlyOwner {
        if (tgeTimestamp != 0) revert Err.InvalidState();
        if (beneficiaries.length != allocations.length) revert Err.InvalidInput();

        tgeTimestamp = uint48(block.timestamp);

        uint256 vestingTotal;
        for (uint256 i = 0; i < allocations.length; i++) vestingTotal += allocations[i];
        totalVestingAllocation = vestingTotal;

        uint256 initialMint = treasuryAmount + seedingAmount;
        maxSupply = initialMint + vestingTotal + emissionsSchedule.totalAllocation;

        if (treasuryAmount > 0) {
            _enforceMaxSupply(treasuryAmount);
            IMintable(govToken).mint(owner(), treasuryAmount);
        }
        if (seedingAmount > 0) {
            _enforceMaxSupply(seedingAmount);
            IMintable(govToken).mint(owner(), seedingAmount);
        }

        for (uint256 i = 0; i < beneficiaries.length; i++) {
            address beneficiary = beneficiaries[i];
            uint256 allocation = allocations[i];
            if (beneficiary == address(0)) revert Err.ZeroValue();
            if (allocation == 0) continue;
            vestingSchedules[beneficiary] = VestingSchedule({
                totalAllocation: allocation,
                claimed: 0,
                cliffTime: tgeTimestamp + CLIFF_DURATION,
                endTime: tgeTimestamp + VESTING_DURATION,
                cliffAmount: uint128((allocation * CLIFF_PERCENT) / 10000),
                suppressor: 10000
            });
        }

        emit TGEInitialized(govToken, treasuryAmount, seedingAmount, tgeTimestamp);
    }

    function claimVested() external override nonReentrant {
        VestingSchedule storage schedule = vestingSchedules[msg.sender];
        if (schedule.totalAllocation == 0) revert Err.InvalidState();
        uint256 claimable = getClaimableVested(msg.sender);
        if (claimable == 0) revert Err.InvalidState();
        schedule.claimed += claimable;
        _enforceMaxSupply(claimable);
        IMintable(govToken).mint(msg.sender, claimable);
        emit VestingClaimed(msg.sender, claimable);
    }

    function getClaimableVested(address beneficiary) public view override returns (uint256) {
        VestingSchedule memory s = vestingSchedules[beneficiary];
        if (s.totalAllocation == 0 || block.timestamp < s.cliffTime) return 0;

        uint256 vested;
        if (block.timestamp < s.endTime) {
            uint256 postCliffTotal = s.totalAllocation - s.cliffAmount;
            uint256 postCliffVested = (postCliffTotal * (uint48(block.timestamp) - s.cliffTime)) / (s.endTime - s.cliffTime);
            vested = s.cliffAmount + postCliffVested;
        } else {
            vested = s.totalAllocation;
        }
        return vested > s.claimed ? vested - s.claimed : 0;
    }

    // ─── protocol fees ───

    function collectProtocolFees(address pool, address token) external override nonReentrant {
        if (pool == address(0) || token == address(0)) revert Err.ZeroValue();
        IAdmin(pool).collectProtocolFees(token, address(this));
        emit ProtocolFeesCollected(pool, token, 0);
    }

    // ─── ownership timelock ───

    function requestOwnershipTransfer(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert Err.ZeroValue();
        if (pendingOwnershipOp != 0) revert Err.PendingTimelock(uint48(block.timestamp));
        pendingOwnershipOp = TL.pack(C.CRITICAL_TIMELOCK, C.GRACE_PERIOD);
        pendingOwner = newOwner;
    }

    function executeOwnershipTransfer() external override {
        TL.validate(pendingOwnershipOp);
        address oldOwner = owner();
        address newOwner = pendingOwner;
        _setOwner(newOwner);
        delete pendingOwnershipOp;
        delete pendingOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function cancelOwnershipTransfer() external override onlyOwner {
        if (pendingOwnershipOp == 0) revert Err.InvalidState();
        delete pendingOwnershipOp;
        delete pendingOwner;
    }

    // ─── config ───

    function setDistributor(address _distributor) external override onlyOwner {
        if (_distributor == address(0)) revert Err.ZeroValue();
        distributor = _distributor;
        emit DistributorSet(_distributor);
    }

    function setBridge(address _bridge) external override onlyOwner {
        if (_bridge == address(0)) revert Err.ZeroValue();
        bridge = _bridge;
        emit BridgeSet(_bridge);
    }

    function authorizeRemoteDistributor(uint32 dstEid, address remoteDistributor) external override onlyOwner {
        if (remoteDistributor == address(0)) revert Err.ZeroValue();
        authorizedRemoteDistributor[dstEid] = remoteDistributor;
        emit RemoteDistributorAuthorized(dstEid, remoteDistributor);
    }

    // ─── emissions cap timelock ───

    function requestEmissionsCapChange(uint256 newCap) external override onlyOwner {
        if (newCap < emissionsSchedule.claimed) revert Err.InvalidInput();
        if (pendingEmissionsCapOp != 0) revert Err.PendingTimelock(uint48(block.timestamp));
        pendingEmissionsCapOp = TL.pack(C.CRITICAL_TIMELOCK, C.GRACE_PERIOD);
        pendingEmissionsCap = newCap;
    }

    function executeEmissionsCapChange() external override {
        TL.validate(pendingEmissionsCapOp);
        VestingSchedule storage es = emissionsSchedule;
        uint256 oldCap = es.totalAllocation;
        uint256 newCap = pendingEmissionsCap;
        es.totalAllocation = newCap;
        maxSupply = (maxSupply - oldCap) + newCap;
        delete pendingEmissionsCapOp;
        delete pendingEmissionsCap;
        emit EmissionsCapChanged(oldCap, newCap);
    }

    function cancelEmissionsCapChange() external override onlyOwner {
        if (pendingEmissionsCapOp == 0) revert Err.InvalidState();
        delete pendingEmissionsCapOp;
        delete pendingEmissionsCap;
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        LibRescue.rescueToken(token, to, amount);
    }

    // ─── upgrades ───

    function requestUpgrade(address newImplementation) external onlyOwner {
        if (newImplementation == address(0)) revert Err.ZeroValue();
        if (pendingUpgrade != bytes32(0)) revert Err.PendingTimelock(uint48(block.timestamp));
        pendingUpgrade = keccak256(abi.encode(newImplementation, block.timestamp));
        pendingImplementation = newImplementation;
        uint96 timelock = TL.pack(C.UPGRADE_TIMELOCK, C.GRACE_PERIOD);
        pendingUpgradeOp = timelock;
        emit UpgradeAuthorized(pendingUpgrade, newImplementation, uint48(timelock >> 48));
    }

    function executeUpgrade() external onlyOwner {
        if (pendingUpgrade == bytes32(0)) revert Err.InvalidState();
        TL.validate(pendingUpgradeOp);
        address newImpl = pendingImplementation;
        delete pendingUpgrade;
        delete pendingImplementation;
        delete pendingUpgradeOp;
        this.upgradeToAndCall(newImpl, "");
    }

    function cancelUpgrade() external onlyOwner {
        if (pendingUpgrade == bytes32(0)) revert Err.InvalidState();
        bytes32 upgradeId = pendingUpgrade;
        delete pendingUpgrade;
        delete pendingImplementation;
        delete pendingUpgradeOp;
        emit UpgradeCancelled(upgradeId);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ─── views ───

    function getTotalSupply() external view override returns (uint256) {
        return IMintable(govToken).totalSupply();
    }

    function getMaxSupply() external view override returns (uint256) { return maxSupply; }

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

    function getTGETimestamp() external view override returns (uint48) { return tgeTimestamp; }

    function getVestingSchedule(address beneficiary) external view override returns (VestingSchedule memory) {
        return vestingSchedules[beneficiary];
    }

    receive() external payable {}
}
