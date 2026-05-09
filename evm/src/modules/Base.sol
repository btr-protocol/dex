// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-peripheral/Errors.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IERC20} from "../interfaces/external/IERC20.sol";
import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";
import {LibTransientCache as TCache} from "../libraries/LibTransientCache.sol";

/// @title Base
/// @notice Shared storage + helpers for all modules (ERC-7201)
abstract contract Base {
    using {M.b64To1e18} for uint64;

    /// @dev keccak256("pool.reentrancy.guard")
    bytes32 private constant REENTRANCY_GUARD_SLOT =
        0xe22c27e8d25bc3725093027126bd674994df6625365bae10cf4b95c8b45f98b6;

    modifier nonReentrant() {
        assembly {
            if tload(REENTRANCY_GUARD_SLOT) {
                mstore(0x00, 0x92f0d5b4) // ReentrancyDetected()
                revert(0x00, 0x04)
            }
            tstore(REENTRANCY_GUARD_SLOT, 1)
        }
        _;
        assembly { tstore(REENTRANCY_GUARD_SLOT, 0) }
    }

    modifier onlyOwner() virtual {
        if (msg.sender != _s().owner) revert Ownable.Unauthorized();
        _;
    }

    modifier whenInitialized() virtual {
        if (!_s().initialized) revert Err.InvalidState();
        _;
    }

    function _s() internal pure returns (IPool.PoolStorage storage $) {
        bytes32 slot = C.CORE_STORAGE_LOC;
        assembly { $.slot := slot }
    }

    function _os() internal pure returns (IPool.OracleStorage storage $) {
        bytes32 slot = C.ORACLE_STORAGE_LOC;
        assembly { $.slot := slot }
    }

    function _fg() internal pure returns (IPool.FlowGuardStorage storage $) {
        bytes32 slot = C.FLOW_GUARD_STORAGE_LOC;
        assembly { $.slot := slot }
    }


    function _recordDeposit(address user, address asset) internal {
        _fg().lastDepositTime[user][asset] = uint32(block.timestamp);
    }

    function _checkWithdrawCooldown(address user, address asset) internal view {
        _checkCooldown(_fg().lastDepositTime[user][asset]);
    }

    function _recordGovStake(address user) internal {
        _fg().lastGovStakeTime[user] = uint32(block.timestamp);
    }

    function _checkGovUnstakeCooldown(address user) internal view {
        _checkCooldown(_fg().lastGovStakeTime[user]);
    }

    function _recordLPStake(address user, address lpToken) internal {
        _fg().lastLPStakeTime[user][lpToken] = uint32(block.timestamp);
    }

    function _checkLPUnstakeCooldown(address user, address lpToken) internal view {
        _checkCooldown(_fg().lastLPStakeTime[user][lpToken]);
    }

    function _checkCooldown(uint32 lastTs) private view {
        uint16 cooldown = _s().flowCooldownSeconds;
        if (cooldown == 0 || lastTs == 0) return;
        unchecked {
            if (block.timestamp < lastTs + cooldown) {
                revert Err.CooldownActive(lastTs + cooldown - uint32(block.timestamp));
            }
        }
    }


    function _asset(IPool.PoolStorage storage $, address tokenNorm)
        internal view returns (IPool.Asset storage asset)
    {
        asset = $.assets[tokenNorm];
        if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tokenNorm);
    }

    function _hook(IPool.PoolStorage storage $, address tokenNorm, uint32 flag)
        internal view returns (address h)
    {
        h = $.hooks[tokenNorm];
        if (h == address(0)) return address(0);
        return ($.hookFlags[tokenNorm] & flag) != 0 ? h : address(0);
    }

    function _wrap(IPool.PoolStorage storage $, address token) internal view returns (address) {
        return token == C.NATIVE ? $.wnative : token;
    }

    function _toUint128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert Err.ExcessiveAmount(x, type(uint128).max);
        return uint128(x);
    }

    function _balanceOf(address token) internal view returns (uint256) {
        return SafeTransferLib.balanceOf(token, address(this));
    }

    function _pull(address token, uint256 amount) internal returns (uint256 actual) {
        if (token == C.NATIVE) {
            if (msg.value < amount) revert Err.InsufficientAmount(msg.value, amount);
            IWETH9(_s().wnative).deposit{value: amount}();
            unchecked {
                uint256 excess = msg.value - amount;
                if (excess > 0) SafeTransferLib.safeTransferETH(msg.sender, excess);
            }
            return amount;
        }
        uint256 balBefore = _balanceOf(token);
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        return _balanceOf(token) - balBefore;
    }

    function _push(address token, address to, uint256 amount) internal {
        if (token == C.NATIVE) {
            IWETH9(_s().wnative).withdraw(amount);
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            SafeTransferLib.safeTransfer(token, to, amount);
        }
    }

    function _checkRisk(IPool.PoolStorage storage $, address token, uint16 requiredFlag) internal view {
        IPool.RiskConfig storage risk = $.riskConfigs[token];
        if ((risk.flags & C.FROZEN_BIT) != 0) revert Err.FeatureDisabled(Err.Resource.ASSET);
        if (requiredFlag != 0 && (risk.flags & requiredFlag) == 0) {
            if (requiredFlag == C.SWAP_ENABLED_BIT) revert Err.FeatureDisabled(Err.Resource.SWAP);
            if (requiredFlag == C.LIABILITY_SWAP_ENABLED_BIT) revert Err.FeatureDisabled(Err.Resource.LIABILITY_SWAP);
            if (requiredFlag == C.FLASH_ENABLED_BIT) revert Err.FeatureDisabled(Err.Resource.FLASH);
        }
    }

    /// @dev Read internal oracle accumulator
    function _readInternalOracle(
        IPool.PoolStorage storage,
        address token,
        bool requireConfigured
    ) internal view returns (IOracle.FeedData memory data, bool isFresh) {
        IPool.FeedAccumulator storage acc = _os().accumulators[token];

        if (acc.lastUpdate == 0) {
            if (requireConfigured) revert Err.NotConfigured(Err.Resource.ORACLE, token);
            return (data, false);
        }

        data = IOracle.FeedData({
            lastPriceB64: acc.lastPriceB64,
            fastOffset: 0,
            slowOffset: 0,
            fastVolEMA: acc.fastVolEMA,
            slowVolEMA: acc.slowVolEMA,
            updatedAt: acc.lastUpdate,
            ttl: acc.ttl,
            confidence: acc.confidence
        });

        // Future timestamp → stale (defensive)
        if (block.timestamp < acc.lastUpdate) {
            isFresh = false;
        } else {
            unchecked { isFresh = block.timestamp - acc.lastUpdate <= acc.ttl; }
        }
    }

    /// @notice Read oracle with primary→fallback. DoS-resistant via try/catch.
    function _readOracle(
        IPool.PoolStorage storage $,
        address token
    ) internal virtual returns (IOracle.FeedData memory data) {
        bool found;
        (found, data) = TCache.tryLoadOracleFeed(token);
        if (found) return data;

        IPool.OracleConfig memory cfg = $.oracleConfigs[token];
        if (cfg.primary == address(0)) revert Err.NotConfigured(Err.Resource.ORACLE, token);

        uint256 lastAge;
        uint256 lastMaxAge;
        bool isFresh;
        bool primaryFailed;

        if (cfg.primary == address(this)) {
            (data, isFresh) = _readInternalOracle($, token, true);
            if (isFresh) { TCache.cacheOracleFeed(token, data); return data; }
            unchecked { lastAge = block.timestamp - data.updatedAt; lastMaxAge = data.ttl; }
        } else {
            try IOracle(cfg.primary).getFeed(cfg.feedId) returns (IOracle.FeedData memory feedData) {
                data = feedData;
                try IOracle(cfg.primary).isFeedFresh(cfg.feedId) returns (bool fresh) {
                    if (fresh) { TCache.cacheOracleFeed(token, data); return data; }
                    unchecked { lastAge = block.timestamp - data.updatedAt; lastMaxAge = data.ttl; }
                } catch { primaryFailed = true; }
            } catch { primaryFailed = true; }
        }

        if ((cfg.modeFlags & C.MODE_ALLOW_FALLBACK) != 0 && cfg.secondary != address(0)) {
            if (cfg.secondary == address(this)) {
                (data, isFresh) = _readInternalOracle($, token, false);
                if (isFresh) { TCache.cacheOracleFeed(token, data); return data; }
                unchecked { lastAge = block.timestamp - data.updatedAt; lastMaxAge = data.ttl; }
            } else {
                try IOracle(cfg.secondary).getFeed(cfg.feedId) returns (IOracle.FeedData memory feedData) {
                    data = feedData;
                    try IOracle(cfg.secondary).isFeedFresh(cfg.feedId) returns (bool fresh) {
                        if (fresh) { TCache.cacheOracleFeed(token, data); return data; }
                        unchecked { lastAge = block.timestamp - data.updatedAt; lastMaxAge = data.ttl; }
                    } catch {}
                } catch {
                    if (primaryFailed) revert Err.NotConfigured(Err.Resource.ORACLE, token);
                }
            }
        } else if (primaryFailed) {
            revert Err.NotConfigured(Err.Resource.ORACLE, token);
        }

        revert Err.StaleData(uint32(lastAge), uint32(lastMaxAge));
    }

    /// @notice Apply liability decay
    function _applyDecay(IPool.PoolStorage storage $, address token, IPool.Asset storage asset) internal {
        IPool.RiskConfig storage rc = $.riskConfigs[token];
        if ((rc.flags & C.DECAY_ENABLED_BIT) == 0 || rc.decaySlope == 0) {
            asset.lastUpdate = uint32(block.timestamp);
            return;
        }

        uint32 dt = uint32(block.timestamp) - asset.lastUpdate;
        if (dt == 0) return;

        uint128 decayAmount = _calculateDecay(
            asset.liabilities, asset.reserves, rc.decayStartRatioBps, rc.decaySlope, dt
        );

        if (decayAmount > 0) asset.liabilities -= decayAmount;
        asset.lastUpdate = uint32(block.timestamp);
    }

    function _calculateDecay(
        uint128 liabilities,
        uint128 reserves,
        uint16 decayStartRatioBps,
        uint32 decaySlope,
        uint32 dt
    ) private pure returns (uint128) {
        if (dt == 0 || decaySlope == 0 || liabilities == 0) return 0;

        uint256 coverage = liabilities == 0 ? type(uint256).max : (uint256(reserves) * 1e18) / uint256(liabilities);
        uint256 threshold = (uint256(decayStartRatioBps) * 1e18) / 1_000_000;
        if (coverage >= threshold) return 0;

        uint256 rawDecay = (uint256(liabilities) * uint256(decaySlope) * uint256(dt)) / 1e18;
        uint256 maxDecay = liabilities > reserves ? liabilities - reserves : 0;
        return uint128(rawDecay > maxDecay ? maxDecay : rawDecay);
    }

    /// @notice Get asset price in base token units (1e18). Base = 1.0.
    function _getAssetPrice(
        IPool.PoolStorage storage $,
        address token
    ) internal virtual returns (uint256 price) {
        if (token == $.baseToken) return 1e18;
        IOracle.FeedData memory data = _readOracle($, token);
        price = M.b64To1e18(data.lastPriceB64);
    }

    /// @notice ERC7802 bridge auth — bridgeable tokens query this
    function getAuthorizedBridge() external view returns (address bridge) {
        return _s().bridge;
    }
}
