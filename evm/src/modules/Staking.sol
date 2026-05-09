// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Base} from "./Base.sol";
import {Err} from "@btr-peripheral/Errors.sol";
import {IMintable} from "../interfaces/IMintable.sol";
import {IStaking} from "../interfaces/modules/IStaking.sol";
import {IPool} from "../interfaces/IPool.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {StakedLP} from "../tokens/StakedLP.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";
import {LibTimelock as TL} from "../libraries/LibTimelock.sol";

/// @title Staking — gov + LP staking, CREATE3 sLP deployment
contract Staking is Base, IStaking {
    using SafeTransferLib for address;

    function _ss() internal pure returns (StakingStorage storage $) {
        bytes32 slot = C.STAKING_STORAGE_LOC;
        assembly { $.slot := slot }
    }

    modifier whenNotPaused() {
        if (_s().stakingConfig.stakingPaused) revert Err.InvalidState();
        _;
    }


    function stakeGov(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert Err.ZeroValue();
        IPool.PoolStorage storage $ = _s();
        StakingStorage storage ss = _ss();

        if ($.govToken == address(0) || $.sGovToken == address(0)) {
            revert Err.NotConfigured(Err.Resource.STAKING, address(0));
        }

        $.govToken.safeTransferFrom(msg.sender, address(this), amount);
        IMintable($.sGovToken).mint(msg.sender, amount);

        ss.govStaked[msg.sender] += amount;
        ss.totalGovStaked += amount;

        // F-A4-R16-1 (R16 INFO, DISCARD): unchecked uint48 add. Realistic
        // `stakeLockDuration` (days–years) leaves ~8.9M-year headroom vs uint48 timestamp;
        // reachable only by owner setting `stakeLockDuration` near uint48.max — itself bounded
        // post-R16 to ≤ 365 days at requestStakeLockDurationUpdate. Theoretical only.
        uint48 newUnlock = uint48(block.timestamp) + $.stakingConfig.stakeLockDuration;
        if (newUnlock > ss.govUnlockTime[msg.sender]) ss.govUnlockTime[msg.sender] = newUnlock;

        _recordGovStake(msg.sender);
        emit GovStaked(msg.sender, amount, ss.govUnlockTime[msg.sender]);
    }

    function unstakeGov(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert Err.ZeroValue();
        IPool.PoolStorage storage $ = _s();
        StakingStorage storage ss = _ss();

        _checkGovUnstakeCooldown(msg.sender);
        if (block.timestamp < ss.govUnlockTime[msg.sender]) revert Err.InvalidState();

        ss.govStaked[msg.sender] -= amount;
        ss.totalGovStaked -= amount;

        IMintable($.sGovToken).burn(msg.sender, amount);
        $.govToken.safeTransfer(msg.sender, amount);

        emit GovUnstaked(msg.sender, amount);
    }


    function updateStakingConfig(address lpToken, bytes32 salt) external onlyOwner {
        IPool.PoolStorage storage $ = _s();
        StakingStorage storage ss = _ss();

        if (ss.sLPTokens[lpToken] != address(0)) revert Err.AlreadyConfigured(Err.Resource.STAKING, lpToken);

        address t = _wrap($, lpToken);
        if ($.assets[t].decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
        if (($.riskConfigs[t].flags & C.STAKEABLE_BIT) == 0) revert Err.InvalidInput();

        // Deterministic salt → unique sLP per LP token, w/ caller-provided entropy
        bytes32 detSalt = keccak256(abi.encodePacked("StakedLP", lpToken, block.chainid, salt));

        bytes memory creationCode = abi.encodePacked(
            type(StakedLP).creationCode,
            abi.encode(address(this), lpToken, address(this))
        );
        address sLP = CREATE3.deployDeterministic(creationCode, detSalt);
        if (sLP.code.length == 0) revert Err.DeploymentFailed();

        ss.sLPTokens[lpToken] = sLP;
        ss.lpTokens.push(lpToken);
        emit StakingConfigured(lpToken, sLP, detSalt);
    }

    function stakeLP(address lpToken, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert Err.ZeroValue();
        IPool.PoolStorage storage $ = _s();
        StakingStorage storage ss = _ss();

        address sLP = ss.sLPTokens[lpToken];
        if (sLP == address(0)) revert Err.NotConfigured(Err.Resource.STAKING, lpToken);

        address t = _wrap($, lpToken);
        if (($.riskConfigs[t].flags & C.STAKEABLE_BIT) == 0) revert Err.InvalidInput();

        // F-A1-R16-1 (R16 HIGH): conservation invariant — user's total LP claim
        //   `lp_effective(user, t) = $.lpBalances[user][t] + IMintable(sLP).balanceOf(user)`
        // is preserved across stake/unstake. `stakeLP` MOVES `amount` from `lpBalances` →
        // sLP-minted. Without this debit, a user could `stakeLP(amount)` and then
        // `Pool.withdraw(amount)` against the unchanged `lpBalances` slot, draining the
        // underlying reserves while retaining a non-zero sLP balance — bypassing the lock.
        // (Symmetric restore on `unstakeLP`.)
        uint256 available = $.lpBalances[msg.sender][t];
        if (available < amount) revert Err.InsufficientAmount(available, amount);

        $.lpBalances[msg.sender][t] = available - amount;
        IMintable(sLP).mint(msg.sender, amount);
        $.lpStaked[msg.sender][lpToken] += amount;
        $.totalLPStaked[lpToken] += amount;

        uint48 newUnlock = uint48(block.timestamp) + $.stakingConfig.stakeLockDuration;
        if (newUnlock > ss.lpUnlockTime[msg.sender][lpToken]) ss.lpUnlockTime[msg.sender][lpToken] = newUnlock;

        _recordLPStake(msg.sender, lpToken);
        emit LPStaked(msg.sender, lpToken, amount, ss.lpUnlockTime[msg.sender][lpToken]);
    }

    function unstakeLP(address lpToken, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert Err.ZeroValue();
        IPool.PoolStorage storage $ = _s();
        StakingStorage storage ss = _ss();

        address sLP = ss.sLPTokens[lpToken];
        if (sLP == address(0)) revert Err.NotConfigured(Err.Resource.STAKING, lpToken);

        _checkLPUnstakeCooldown(msg.sender, lpToken);
        if (block.timestamp < ss.lpUnlockTime[msg.sender][lpToken]) revert Err.InvalidState();

        uint256 available = $.lpStaked[msg.sender][lpToken];
        if (available < amount) revert Err.InsufficientAmount(available, amount);

        IMintable(sLP).burn(msg.sender, amount);
        $.lpStaked[msg.sender][lpToken] -= amount;
        $.totalLPStaked[lpToken] -= amount;
        // F-A1-R16-1: restore lpBalances (symmetric to stakeLP debit). Conservation invariant
        // preserved end-to-end.
        address t = _wrap($, lpToken);
        $.lpBalances[msg.sender][t] += amount;

        emit LPUnstaked(msg.sender, lpToken, amount);
    }


    /// @dev F-A2-R16-1 (R16 LOW, DISCARDED): `delegateOf` write surface has no on-chain
    ///      read consumer (no voting-power view in `src/`). Retained as off-chain
    ///      governance signal (snapshot/Tally-style). Wiring an on-chain voting-power view
    ///      requires a sToken→delegate aggregation pass; deferred. Off-chain consumers MUST
    ///      treat `delegateOf` as advisory; no on-chain enforcement of delegated voting weight.
    function delegateVoting(address to) external {
        // self-delegation == clear
        if (to == msg.sender) to = address(0);
        StakingStorage storage ss = _ss();
        address prev = ss.delegateOf[msg.sender];
        ss.delegateOf[msg.sender] = to;
        emit DelegateSet(msg.sender, prev, to);
    }


    function pause() external onlyOwner {
        IPool.PoolStorage storage $ = _s();
        if ($.stakingConfig.stakingPaused) revert Err.InvalidState();
        $.stakingConfig.stakingPaused = true;
        emit StakingPaused(msg.sender);
    }

    function unpause() external onlyOwner {
        IPool.PoolStorage storage $ = _s();
        if (!$.stakingConfig.stakingPaused) revert Err.InvalidState();
        $.stakingConfig.stakingPaused = false;
        emit StakingUnpaused(msg.sender);
    }

    /// @dev F-A2-R16-2 (R16 LOW): bound + re-entry guard. Bound `newLockDuration ≤ 365 days`
    ///      prevents owner-induced permanent-lock griefing AND keeps `block.timestamp +
    ///      stakeLockDuration` headroom comfortable below uint48 horizon (resolves F-A4-R16-1
    ///      INFO numerical concern). Reject double-queue to align with `Treasury` pattern
    ///      (`requestEmissionsCapChange:271`); avoids silent overwrite of grace clock.
    function requestStakeLockDurationUpdate(uint48 newLockDuration) external onlyOwner {
        if (newLockDuration > 365 days) revert Err.InvalidInput();
        IPool.PoolStorage storage $ = _s();
        if ($.pendingOps[C.TIMELOCK_ID_STAKING] != 0) {
            revert Err.PendingTimelock(uint48(block.timestamp));
        }
        $.pendingOps[C.TIMELOCK_ID_STAKING] = TL.pack(C.BASE_TIMELOCK, C.GRACE_PERIOD);
        $.pendingData[C.TIMELOCK_ID_STAKING] = abi.encode(newLockDuration);
        emit StakingConfigUpdateRequested(newLockDuration, uint48(block.timestamp) + C.BASE_TIMELOCK);
    }

    function executeStakeLockDurationUpdate() external onlyOwner {
        IPool.PoolStorage storage $ = _s();
        TL.validate($.pendingOps[C.TIMELOCK_ID_STAKING]);
        uint48 newLockDuration = abi.decode($.pendingData[C.TIMELOCK_ID_STAKING], (uint48));
        $.stakingConfig.stakeLockDuration = newLockDuration;
        delete $.pendingOps[C.TIMELOCK_ID_STAKING];
        delete $.pendingData[C.TIMELOCK_ID_STAKING];
        emit StakingConfigUpdated(newLockDuration);
    }


    function getStakedGov(address user) external view returns (uint256) { return _ss().govStaked[user]; }

    function getStakedLP(address user, address lpToken) external view returns (uint256) {
        address sLP = _ss().sLPTokens[lpToken];
        return sLP == address(0) ? 0 : SafeTransferLib.balanceOf(sLP, user);
    }

    function getUnlockTime(address user, address lpToken) external view returns (uint48) {
        StakingStorage storage ss = _ss();
        return lpToken == address(0) ? ss.govUnlockTime[user] : ss.lpUnlockTime[user][lpToken];
    }

    function getSLPToken(address lpToken) external view returns (address) { return _ss().sLPTokens[lpToken]; }
    function getTotalLPStaked(address lpToken) external view returns (uint256) { return _s().totalLPStaked[lpToken]; }

    function getStakedBalance(address user, address underlying) external view returns (uint256) {
        IPool.PoolStorage storage $ = _s();
        return underlying == $.govToken ? _ss().govStaked[user] : $.lpStaked[user][underlying];
    }

    function getTotalStaked(address underlying) external view returns (uint256) {
        IPool.PoolStorage storage $ = _s();
        return underlying == $.govToken ? _ss().totalGovStaked : $.totalLPStaked[underlying];
    }

    function getDelegateOf(address owner) external view returns (address) { return _ss().delegateOf[owner]; }
}
