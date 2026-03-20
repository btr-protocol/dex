// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseV1} from "./BaseV1.sol";
import {IErrors} from "../interfaces/IErrors.sol";
import {IMintable} from "../interfaces/IMintable.sol";
import {IStakingV1} from "../interfaces/modules/IStakingV1.sol";
import {IPoolV1} from "../interfaces/IPoolV1.sol";
import {IERC20} from "../interfaces/external/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {StakedLP} from "../tokens/StakedLP.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";
import {LibTimelock as TL} from "../libraries/LibTimelock.sol";

/// @title StakingV1
/// @notice Ultra-lean staking for governance tokens and LP tokens
/// @dev Unified stake/unstake logic, CREATE3 sLP deployment
///      Storage location: LibConstants.STAKING_STORAGE_LOC
contract StakingV1 is BaseV1, IStakingV1 {
    using SafeTransferLib for address;

    // ========== STORAGE ==========
    /// @dev ERC-7201 storage location: LibConstants.STAKING_STORAGE_LOC

    function _ss() internal pure returns (StakingStorage storage $) {
        bytes32 slot = C.STAKING_STORAGE_LOC;
        assembly { $.slot := slot }
    }

    modifier whenNotPaused() {
        if (_s().stakingConfig.stakingPaused) revert IErrors.InvalidState();
        _;
    }

    // ========== GOVERNANCE TOKEN STAKING ==========

    /// @inheritdoc IStakingV1
    function stakeGov(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert IErrors.ZeroValue();

        IPoolV1.PoolStorage storage $ = _s();
        StakingStorage storage ss = _ss();

        $.govToken.safeTransferFrom(msg.sender, address(this), amount);
        IMintable($.sGovToken).mint(msg.sender, amount);

        ss.govStaked[msg.sender] += amount;
        ss.totalGovStaked += amount;

        uint48 newUnlock = uint48(block.timestamp) + $.stakingConfig.stakeLockDuration;
        if (newUnlock > ss.govUnlockTime[msg.sender]) {
            ss.govUnlockTime[msg.sender] = newUnlock;
        }

        _recordGovStake(msg.sender);

        emit GovStaked(msg.sender, amount, ss.govUnlockTime[msg.sender]);
    }

    /// @inheritdoc IStakingV1
    function unstakeGov(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert IErrors.ZeroValue();

        IPoolV1.PoolStorage storage $ = _s();
        StakingStorage storage ss = _ss();

        _checkGovUnstakeCooldown(msg.sender);
        if (block.timestamp < ss.govUnlockTime[msg.sender]) revert IErrors.InvalidState();

        ss.govStaked[msg.sender] -= amount;
        ss.totalGovStaked -= amount;

        IMintable($.sGovToken).burn(msg.sender, amount);
        $.govToken.safeTransfer(msg.sender, amount);

        emit GovUnstaked(msg.sender, amount);
    }

    // ========== LP STAKING ==========

    /// @inheritdoc IStakingV1
    function updateStakingConfig(address lpToken, bytes32 salt) external onlyOwner {
        IPoolV1.PoolStorage storage $ = _s();
        StakingStorage storage ss = _ss();

        if (ss.sLPTokens[lpToken] != address(0)) revert IErrors.AlreadyConfigured(IErrors.Resource.STAKING, lpToken);

        // Verify LP token is stakeable
        address tokenNorm = _wrap($, lpToken);
        if ($.assets[tokenNorm].decimals == 0) revert IErrors.NotFound(IErrors.Resource.ASSET, tokenNorm);
        if (($.riskConfigs[tokenNorm].flags & C.STAKEABLE_BIT) == 0) revert IErrors.InvalidInput();

        // Generate deterministic salt based on LP token address to prevent collisions
        // This ensures unique salts for each LP token
        bytes32 deterministicSalt = keccak256(abi.encodePacked(
            "StakedLP",
            lpToken,
            block.chainid,
            salt // Allow owner to provide additional entropy if needed
        ));

        // Deploy sLP token via CREATE3
        bytes memory creationCode = abi.encodePacked(
            type(StakedLP).creationCode,
            abi.encode(address(this), lpToken, address(this))
        );
        address sLP = CREATE3.deployDeterministic(creationCode, deterministicSalt);

        // Verify deployment succeeded and address is unique
        if (sLP.code.length == 0) revert IErrors.DeploymentFailed();

        ss.sLPTokens[lpToken] = sLP;
        ss.lpTokens.push(lpToken);
        emit StakingConfigured(lpToken, sLP, deterministicSalt);
    }

    /// @inheritdoc IStakingV1
    function stakeLP(address lpToken, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert IErrors.ZeroValue();

        IPoolV1.PoolStorage storage $ = _s();
        StakingStorage storage ss = _ss();

        address sLP = ss.sLPTokens[lpToken];
        if (sLP == address(0)) revert IErrors.NotConfigured(IErrors.Resource.STAKING, lpToken);

        address tokenNorm = _wrap($, lpToken);
        if (($.riskConfigs[tokenNorm].flags & C.STAKEABLE_BIT) == 0) revert IErrors.InvalidInput();

        uint256 alreadyStaked = $.lpStaked[msg.sender][lpToken];
        uint256 available = $.lpBalances[msg.sender][tokenNorm];
        if (available < alreadyStaked + amount) revert IErrors.InsufficientAmount(available, alreadyStaked + amount);

        IMintable(sLP).mint(msg.sender, amount);

        $.lpStaked[msg.sender][lpToken] += amount;
        $.totalLPStaked[lpToken] += amount;

        uint48 newUnlock = uint48(block.timestamp) + $.stakingConfig.stakeLockDuration;
        if (newUnlock > ss.lpUnlockTime[msg.sender][lpToken]) {
            ss.lpUnlockTime[msg.sender][lpToken] = newUnlock;
        }

        _recordLPStake(msg.sender, lpToken);

        emit LPStaked(msg.sender, lpToken, amount, ss.lpUnlockTime[msg.sender][lpToken]);
    }

    /// @inheritdoc IStakingV1
    function unstakeLP(address lpToken, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert IErrors.ZeroValue();

        IPoolV1.PoolStorage storage $ = _s();
        StakingStorage storage ss = _ss();

        address sLP = ss.sLPTokens[lpToken];
        if (sLP == address(0)) revert IErrors.NotConfigured(IErrors.Resource.STAKING, lpToken);

        _checkLPUnstakeCooldown(msg.sender, lpToken);
        if (block.timestamp < ss.lpUnlockTime[msg.sender][lpToken]) revert IErrors.InvalidState();

        uint256 available = $.lpStaked[msg.sender][lpToken];
        if (available < amount) revert IErrors.InsufficientAmount(available, amount);

        IMintable(sLP).burn(msg.sender, amount);

        $.lpStaked[msg.sender][lpToken] -= amount;
        $.totalLPStaked[lpToken] -= amount;

        emit LPUnstaked(msg.sender, lpToken, amount);
    }

    // ========== DELEGATION ==========

    /// @inheritdoc IStakingV1
    function delegateVoting(address to) external {
        // Allow to == msg.sender as equivalent to clearing delegation (to = address(0))
        if (to == msg.sender) to = address(0);

        StakingStorage storage ss = _ss();

        address prev = ss.delegateOf[msg.sender];

        // Update delegation (metadata-only for off-chain snapshot)
        ss.delegateOf[msg.sender] = to;
        emit DelegateSet(msg.sender, prev, to);
    }

    // ========== ADMIN ==========

    /// @inheritdoc IStakingV1
    function pause() external onlyOwner {
        IPoolV1.PoolStorage storage $ = _s();
        if ($.stakingConfig.stakingPaused) revert IErrors.InvalidState();
        $.stakingConfig.stakingPaused = true;
        emit StakingPaused(msg.sender);
    }

    /// @inheritdoc IStakingV1
    function unpause() external onlyOwner {
        IPoolV1.PoolStorage storage $ = _s();
        if (!$.stakingConfig.stakingPaused) revert IErrors.InvalidState();
        $.stakingConfig.stakingPaused = false;
        emit StakingUnpaused(msg.sender);
    }

    /// @inheritdoc IStakingV1
    function requestStakeLockDurationUpdate(uint48 newLockDuration) external onlyOwner {
        IPoolV1.PoolStorage storage $ = _s();
        $.pendingOps[C.TIMELOCK_ID_STAKING] = TL.pack(C.BASE_TIMELOCK, C.GRACE_PERIOD);
        $.pendingData[C.TIMELOCK_ID_STAKING] = abi.encode(newLockDuration);
        emit StakingConfigUpdateRequested(newLockDuration, uint48(block.timestamp) + C.BASE_TIMELOCK);
    }

    /// @inheritdoc IStakingV1
    function executeStakeLockDurationUpdate() external onlyOwner {
        IPoolV1.PoolStorage storage $ = _s();
        TL.validate($.pendingOps[C.TIMELOCK_ID_STAKING]);

        uint48 newLockDuration = abi.decode($.pendingData[C.TIMELOCK_ID_STAKING], (uint48));

        $.stakingConfig.stakeLockDuration = newLockDuration;

        delete $.pendingOps[C.TIMELOCK_ID_STAKING];
        delete $.pendingData[C.TIMELOCK_ID_STAKING];
        emit StakingConfigUpdated(newLockDuration);
    }

    // ========== VIEWS ==========

    /// @inheritdoc IStakingV1
    function getStakedGov(address user) external view returns (uint256) {
        return _ss().govStaked[user];
    }

    /// @inheritdoc IStakingV1
    function getStakedLP(address user, address lpToken) external view returns (uint256) {
        address sLP = _ss().sLPTokens[lpToken];
        return sLP == address(0) ? 0 : SafeTransferLib.balanceOf(sLP, user);
    }

    /// @inheritdoc IStakingV1
    function getUnlockTime(address user, address lpToken) external view returns (uint48) {
        StakingStorage storage ss = _ss();
        return lpToken == address(0) ? ss.govUnlockTime[user] : ss.lpUnlockTime[user][lpToken];
    }

    /// @inheritdoc IStakingV1
    function getSLPToken(address lpToken) external view returns (address) {
        return _ss().sLPTokens[lpToken];
    }

    /// @inheritdoc IStakingV1
    function getTotalLPStaked(address lpToken) external view returns (uint256) {
        return _s().totalLPStaked[lpToken];
    }

    /// @inheritdoc IStakingV1
    function getStakedBalance(address user, address underlying) external view returns (uint256) {
        IPoolV1.PoolStorage storage $ = _s();
        StakingStorage storage ss = _ss();
        if (underlying == $.govToken) {
            return ss.govStaked[user];
        } else {
            return $.lpStaked[user][underlying];
        }
    }

    /// @inheritdoc IStakingV1
    function getTotalStaked(address underlying) external view returns (uint256) {
        IPoolV1.PoolStorage storage $ = _s();
        StakingStorage storage ss = _ss();
        if (underlying == $.govToken) {
            return ss.totalGovStaked;
        } else {
            return $.totalLPStaked[underlying];
        }
    }

    /// @inheritdoc IStakingV1
    function getDelegateOf(address owner) external view returns (address) {
        return _ss().delegateOf[owner];
    }
}