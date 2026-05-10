// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IStaking} from "./interfaces/IStaking.sol";
import {IPool} from "./interfaces/IPool.sol";
import {IMintable} from "./interfaces/IMintable.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Timelock as TL} from "@btr-shared/Timelock.sol";
import {StakedLP} from "./tokens/StakedLP.sol";

/// @title Staking
/// @notice Standalone singleton staking contract. Replaces the former Staking Diamond module.
/// @dev Phase 42H.B.3b — Staking no longer delegatecalls into Pool. It calls Pool's
///      restricted setters via standard external calls. Each public function takes
///      `address pool` as the first arg. State is keyed (pool, ...) for cross-pool support.
///      Owner check goes through the shared singleton AccessControl.
contract Staking is IStaking {
    using SafeTransferLib for address;

    /// @notice Risk flag mirror — STAKEABLE_BIT (kept here to avoid pulling dex-internal Constants).
    uint16 internal constant STAKEABLE_BIT = 1 << 6;

    /// @notice Shared singleton AccessControl — single source of truth for owner.
    address public immutable AC;

    /// @dev Per-pool config.
    struct PoolStakingConfig {
        uint48 stakeLockDuration;
        bool paused;
    }

    // ── per-pool config ──
    mapping(address pool => PoolStakingConfig) public poolConfig;
    mapping(address pool => address) public govTokenOf;
    mapping(address pool => address) public sGovTokenOf;

    // ── governance staking ──
    mapping(address pool => mapping(address user => uint256)) public govStaked;
    mapping(address pool => uint256) public totalGovStaked;
    mapping(address pool => mapping(address user => uint48)) public govUnlockTime;

    // ── LP staking ──
    mapping(address pool => mapping(address lpToken => address sLP)) public sLPTokens;
    mapping(address pool => mapping(address user => mapping(address lpToken => uint256))) public lpStaked;
    mapping(address pool => mapping(address lpToken => uint256)) public totalLPStakedByPool;
    mapping(address pool => mapping(address user => mapping(address lpToken => uint48))) public lpUnlockTime;
    mapping(address pool => address[]) internal _lpTokens;

    // ── delegation (off-chain advisory; F-A2-R16-1) ──
    mapping(address pool => mapping(address owner => address)) public delegateOfBy;

    // ── flow cooldown tracking (per-pool) ──
    mapping(address pool => uint16) public flowCooldownSeconds;
    mapping(address pool => mapping(address user => uint32)) public lastGovStakeTime;
    mapping(address pool => mapping(address user => mapping(address lpToken => uint32))) public lastLPStakeTime;

    // ── timelock (per-pool) ──
    bytes32 private constant OP_LOCK_DURATION = keccak256("LOCK_DURATION");
    mapping(bytes32 => uint96) public pendingOps;
    mapping(bytes32 => bytes) public pendingData;

    // ── reentrancy guard (transient) ──
    bytes32 private constant REENTRANCY_GUARD_SLOT =
        0xe22c27e8d25bc3725093027126bd674994df6625365bae10cf4b95c8b45f98b6;

    constructor(address ac_) {
        if (ac_ == address(0)) revert Err.ZeroAddr();
        AC = ac_;
    }

    modifier nonReentrant() {
        assembly {
            if tload(REENTRANCY_GUARD_SLOT) {
                mstore(0x00, 0x92f0d5b4)
                revert(0x00, 0x04)
            }
            tstore(REENTRANCY_GUARD_SLOT, 1)
        }
        _;
        assembly { tstore(REENTRANCY_GUARD_SLOT, 0) }
    }

    modifier onlyOwner() {
        if (msg.sender != AccessControl(AC).owner()) revert Ownable.Unauthorized();
        _;
    }

    function _whenNotPaused(address pool) internal view {
        if (poolConfig[pool].paused) revert Err.InvalidState();
    }

    function _key(address pool, bytes32 opId) internal pure returns (bytes32) {
        return keccak256(abi.encode(pool, opId));
    }

    function _checkCooldown(address pool, uint32 lastTs) internal view {
        uint16 cd = flowCooldownSeconds[pool];
        if (cd == 0 || lastTs == 0) return;
        unchecked {
            if (block.timestamp < lastTs + cd) {
                revert Err.CooldownActive(lastTs + cd - uint32(block.timestamp));
            }
        }
    }

    // ─── governance staking ───

    function stakeGov(address pool, uint256 amount) external nonReentrant {
        if (amount == 0) revert Err.ZeroValue();
        _whenNotPaused(pool);

        address gov = govTokenOf[pool];
        address sGov = sGovTokenOf[pool];
        if (gov == address(0) || sGov == address(0)) {
            revert Err.NotConfigured(Err.Resource.STAKING, address(0));
        }

        gov.safeTransferFrom(msg.sender, address(this), amount);
        IMintable(sGov).mint(msg.sender, amount);

        govStaked[pool][msg.sender] += amount;
        totalGovStaked[pool] += amount;

        uint48 newUnlock = uint48(block.timestamp) + poolConfig[pool].stakeLockDuration;
        if (newUnlock > govUnlockTime[pool][msg.sender]) govUnlockTime[pool][msg.sender] = newUnlock;

        lastGovStakeTime[pool][msg.sender] = uint32(block.timestamp);
        emit GovStaked(pool, msg.sender, amount, govUnlockTime[pool][msg.sender]);
    }

    function unstakeGov(address pool, uint256 amount) external nonReentrant {
        if (amount == 0) revert Err.ZeroValue();
        _whenNotPaused(pool);

        _checkCooldown(pool, lastGovStakeTime[pool][msg.sender]);
        if (block.timestamp < govUnlockTime[pool][msg.sender]) revert Err.InvalidState();

        govStaked[pool][msg.sender] -= amount;
        totalGovStaked[pool] -= amount;

        address sGov = sGovTokenOf[pool];
        address gov  = govTokenOf[pool];
        IMintable(sGov).burn(msg.sender, amount);
        gov.safeTransfer(msg.sender, amount);

        emit GovUnstaked(pool, msg.sender, amount);
    }

    // ─── LP staking ───

    /// @notice One-shot per pool — owner registers gov + sGov refs (mirrors prior Pool.adminSetGov*).
    function configurePool(address pool, address gov, address sGov, uint16 cooldownSeconds) external onlyOwner {
        if (gov == address(0) || sGov == address(0)) revert Err.ZeroValue();
        if (govTokenOf[pool] != address(0)) revert Err.AlreadyConfigured(Err.Resource.STAKING, govTokenOf[pool]);
        if (sGovTokenOf[pool] != address(0)) revert Err.AlreadyConfigured(Err.Resource.STAKING, sGovTokenOf[pool]);
        govTokenOf[pool] = gov;
        sGovTokenOf[pool] = sGov;
        flowCooldownSeconds[pool] = cooldownSeconds;
        emit PoolConfigured(pool, gov, sGov, cooldownSeconds);
    }

    function setFlowCooldown(address pool, uint16 cooldownSeconds) external onlyOwner {
        flowCooldownSeconds[pool] = cooldownSeconds;
    }

    function updateStakingConfig(address pool, address lpToken, bytes32 salt) external onlyOwner {
        if (sLPTokens[pool][lpToken] != address(0)) revert Err.AlreadyConfigured(Err.Resource.STAKING, lpToken);

        // Validate asset is registered + STAKEABLE on the pool.
        IPool.Asset memory a = IPool(pool).getAsset(lpToken);
        if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, lpToken);
        if ((IPool(pool).getRiskFlags(lpToken) & STAKEABLE_BIT) == 0) revert Err.InvalidInput();

        bytes32 detSalt = keccak256(abi.encodePacked("StakedLP", pool, lpToken, block.chainid, salt));
        bytes memory creationCode = abi.encodePacked(
            type(StakedLP).creationCode,
            abi.encode(address(this), lpToken, pool)
        );
        address sLP = CREATE3.deployDeterministic(creationCode, detSalt);
        if (sLP.code.length == 0) revert Err.DeploymentFailed();

        sLPTokens[pool][lpToken] = sLP;
        _lpTokens[pool].push(lpToken);
        emit StakingConfigured(pool, lpToken, sLP, detSalt);
    }

    function stakeLP(address pool, address lpToken, uint256 amount) external nonReentrant {
        if (amount == 0) revert Err.ZeroValue();
        _whenNotPaused(pool);

        address sLP = sLPTokens[pool][lpToken];
        if (sLP == address(0)) revert Err.NotConfigured(Err.Resource.STAKING, lpToken);
        if ((IPool(pool).getRiskFlags(lpToken) & STAKEABLE_BIT) == 0) revert Err.InvalidInput();

        // Debit Pool's lpBalances → singleton sLP-minted (conservation invariant — F-A1-R16-1).
        uint256 available = IPool(pool).getLPBalance(msg.sender, lpToken);
        if (available < amount) revert Err.InsufficientAmount(available, amount);
        IPool(pool).stakingAdjustLpBalance(msg.sender, lpToken, -int256(amount));

        IMintable(sLP).mint(msg.sender, amount);
        lpStaked[pool][msg.sender][lpToken] += amount;
        totalLPStakedByPool[pool][lpToken] += amount;

        uint48 newUnlock = uint48(block.timestamp) + poolConfig[pool].stakeLockDuration;
        if (newUnlock > lpUnlockTime[pool][msg.sender][lpToken]) lpUnlockTime[pool][msg.sender][lpToken] = newUnlock;

        lastLPStakeTime[pool][msg.sender][lpToken] = uint32(block.timestamp);
        emit LPStaked(pool, msg.sender, lpToken, amount, lpUnlockTime[pool][msg.sender][lpToken]);
    }

    function unstakeLP(address pool, address lpToken, uint256 amount) external nonReentrant {
        if (amount == 0) revert Err.ZeroValue();
        _whenNotPaused(pool);

        address sLP = sLPTokens[pool][lpToken];
        if (sLP == address(0)) revert Err.NotConfigured(Err.Resource.STAKING, lpToken);

        _checkCooldown(pool, lastLPStakeTime[pool][msg.sender][lpToken]);
        if (block.timestamp < lpUnlockTime[pool][msg.sender][lpToken]) revert Err.InvalidState();

        uint256 available = lpStaked[pool][msg.sender][lpToken];
        if (available < amount) revert Err.InsufficientAmount(available, amount);

        IMintable(sLP).burn(msg.sender, amount);
        lpStaked[pool][msg.sender][lpToken] -= amount;
        totalLPStakedByPool[pool][lpToken] -= amount;

        // Restore Pool's lpBalances (symmetric to stakeLP debit).
        IPool(pool).stakingAdjustLpBalance(msg.sender, lpToken, int256(amount));

        emit LPUnstaked(pool, msg.sender, lpToken, amount);
    }

    // ─── delegation (advisory) ───

    function delegateVoting(address pool, address to) external {
        if (to == msg.sender) to = address(0);
        address prev = delegateOfBy[pool][msg.sender];
        delegateOfBy[pool][msg.sender] = to;
        emit DelegateSet(pool, msg.sender, prev, to);
    }

    // ─── pause + lock duration ───

    function pause(address pool) external onlyOwner {
        if (poolConfig[pool].paused) revert Err.InvalidState();
        poolConfig[pool].paused = true;
        emit StakingPaused(pool, msg.sender);
    }

    function unpause(address pool) external onlyOwner {
        if (!poolConfig[pool].paused) revert Err.InvalidState();
        poolConfig[pool].paused = false;
        emit StakingUnpaused(pool, msg.sender);
    }

    function requestStakeLockDurationUpdate(address pool, uint48 newLockDuration) external onlyOwner {
        if (newLockDuration > 365 days) revert Err.InvalidInput();
        bytes32 key = _key(pool, OP_LOCK_DURATION);
        if (pendingOps[key] != 0) revert Err.PendingTimelock(uint48(block.timestamp));
        pendingOps[key] = TL.pack(SC.BASE_TIMELOCK, SC.GRACE_PERIOD);
        pendingData[key] = abi.encode(newLockDuration);
        emit StakingConfigUpdateRequested(pool, newLockDuration, uint48(block.timestamp) + SC.BASE_TIMELOCK);
    }

    function executeStakeLockDurationUpdate(address pool) external onlyOwner {
        bytes32 key = _key(pool, OP_LOCK_DURATION);
        TL.validate(pendingOps[key]);
        uint48 newLockDuration = abi.decode(pendingData[key], (uint48));
        poolConfig[pool].stakeLockDuration = newLockDuration;
        delete pendingOps[key];
        delete pendingData[key];
        emit StakingConfigUpdated(pool, newLockDuration);
    }

    // ─── views ───

    function getStakedGov(address pool, address user) external view returns (uint256) { return govStaked[pool][user]; }

    function getStakedLP(address pool, address user, address lpToken) external view returns (uint256) {
        address sLP = sLPTokens[pool][lpToken];
        return sLP == address(0) ? 0 : SafeTransferLib.balanceOf(sLP, user);
    }

    function getUnlockTime(address pool, address user, address lpToken) external view returns (uint48) {
        return lpToken == address(0) ? govUnlockTime[pool][user] : lpUnlockTime[pool][user][lpToken];
    }

    function getSLPToken(address pool, address lpToken) external view returns (address) { return sLPTokens[pool][lpToken]; }
    function getTotalLPStaked(address pool, address lpToken) external view returns (uint256) { return totalLPStakedByPool[pool][lpToken]; }

    /// @notice For sToken.balanceOf — caller MUST be a sToken bound to (pool, underlying).
    /// @dev underlying = govToken → returns gov stake; else → returns LP stake.
    function getStakedBalance(address pool, address user, address underlying) external view returns (uint256) {
        if (underlying == govTokenOf[pool]) return govStaked[pool][user];
        return lpStaked[pool][user][underlying];
    }

    function getTotalStaked(address pool, address underlying) external view returns (uint256) {
        if (underlying == govTokenOf[pool]) return totalGovStaked[pool];
        return totalLPStakedByPool[pool][underlying];
    }

    function getDelegateOf(address pool, address owner_) external view returns (address) { return delegateOfBy[pool][owner_]; }

    function getStakeLockDuration(address pool) external view returns (uint48) { return poolConfig[pool].stakeLockDuration; }
    function isStakingPaused(address pool) external view returns (bool) { return poolConfig[pool].paused; }
    function getLPTokens(address pool) external view returns (address[] memory) { return _lpTokens[pool]; }
}
