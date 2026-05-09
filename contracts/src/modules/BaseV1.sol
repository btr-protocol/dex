// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IPoolV1} from "../interfaces/IPoolV1.sol";
import {Err} from "../Errors.sol";
import {IOracleV1} from "../interfaces/IOracleV1.sol";
import {IERC20} from "../interfaces/external/IERC20.sol";
import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";
import {LibTransientCache as TCache} from "../libraries/LibTransientCache.sol";
// NB: LibPricing intentionally NOT imported here to keep BaseV1 lean
// Modules needing pricing import it directly; decay calculation is inlined below

/// @title BaseV1
/// @notice Base contract for all AIMM modules with shared storage access
/// @dev All modules inherit from this to access PoolStorage via ERC-7201
///      Storage location: LibConstants.CORE_STORAGE_LOC
abstract contract BaseV1 {
    using {M.b64To1e18} for uint64;

    /// @dev Transient storage slot for reentrancy guard (EIP-1153)
    /// @dev keccak256("pool.reentrancy.guard")
    bytes32 private constant REENTRANCY_GUARD_SLOT =
        0xe22c27e8d25bc3725093027126bd674994df6625365bae10cf4b95c8b45f98b6;

    modifier nonReentrant() {
        assembly {
            // Check if already entered
            if tload(REENTRANCY_GUARD_SLOT) {
                // Revert with ReentrancyDetected() selector
                // keccak256("ReentrancyDetected()") = 0x92f0d5b400000000...
                mstore(0x00, 0x92f0d5b4)
                revert(0x00, 0x04)
            }
            // Set guard
            tstore(REENTRANCY_GUARD_SLOT, 1)
        }
        _;
        assembly {
            // Clear guard
            tstore(REENTRANCY_GUARD_SLOT, 0)
        }
    }

    modifier onlyOwner() virtual {
        if (msg.sender != _s().owner) revert Ownable.Unauthorized();
        _;
    }

    modifier whenInitialized() virtual {
        if (!_s().initialized) revert Err.InvalidState();
        _;
    }

    function _s() internal pure returns (IPoolV1.PoolStorage storage $) {
        bytes32 slot = C.CORE_STORAGE_LOC;
        assembly {
            $.slot := slot
        }
    }

    function _os() internal pure returns (IPoolV1.OracleStorage storage $) {
        bytes32 slot = C.ORACLE_STORAGE_LOC;
        assembly {
            $.slot := slot
        }
    }

    function _fg() internal pure returns (IPoolV1.FlowGuardStorage storage $) {
        bytes32 slot = C.FLOW_GUARD_STORAGE_LOC;
        assembly {
            $.slot := slot
        }
    }

    // ========== FLOW GUARD (JIT PROTECTION) ==========

    /// @dev Record deposit timestamp for flow guard
    /// @param user User address
    /// @param asset Asset address (normalized)
    function _recordDeposit(address user, address asset) internal {
        _fg().lastDepositTime[user][asset] = uint32(block.timestamp);
    }

    /// @dev Check withdraw cooldown for flow guard
    /// @param user User address
    /// @param asset Asset address (normalized)
    function _checkWithdrawCooldown(address user, address asset) internal view {
        uint16 cooldown = _s().flowCooldownSeconds;
        if (cooldown == 0) return; // Flow guard disabled

        uint32 lastDeposit = _fg().lastDepositTime[user][asset];
        if (lastDeposit == 0) return; // No prior deposit recorded

        unchecked {
            if (block.timestamp < lastDeposit + cooldown) {
                revert Err.CooldownActive(lastDeposit + cooldown - uint32(block.timestamp));
            }
        }
    }

    /// @dev Record gov stake timestamp for flow guard
    /// @param user User address
    function _recordGovStake(address user) internal {
        _fg().lastGovStakeTime[user] = uint32(block.timestamp);
    }

    /// @dev Check gov unstake cooldown for flow guard
    /// @param user User address
    function _checkGovUnstakeCooldown(address user) internal view {
        uint16 cooldown = _s().flowCooldownSeconds;
        if (cooldown == 0) return;

        uint32 lastStake = _fg().lastGovStakeTime[user];
        if (lastStake == 0) return;

        unchecked {
            if (block.timestamp < lastStake + cooldown) {
                revert Err.CooldownActive(lastStake + cooldown - uint32(block.timestamp));
            }
        }
    }

    /// @dev Record LP stake timestamp for flow guard
    /// @param user User address
    /// @param lpToken LP token address
    function _recordLPStake(address user, address lpToken) internal {
        _fg().lastLPStakeTime[user][lpToken] = uint32(block.timestamp);
    }

    /// @dev Check LP unstake cooldown for flow guard
    /// @param user User address
    /// @param lpToken LP token address
    function _checkLPUnstakeCooldown(address user, address lpToken) internal view {
        uint16 cooldown = _s().flowCooldownSeconds;
        if (cooldown == 0) return;

        uint32 lastStake = _fg().lastLPStakeTime[user][lpToken];
        if (lastStake == 0) return;

        unchecked {
            if (block.timestamp < lastStake + cooldown) {
                revert Err.CooldownActive(lastStake + cooldown - uint32(block.timestamp));
            }
        }
    }

    // ========== INTERNAL HELPERS ==========

    /// @dev Centralized asset lookup with existence validation
    function _asset(IPoolV1.PoolStorage storage $, address tokenNorm)
        internal view
        returns (IPoolV1.Asset storage asset)
    {
        asset = $.assets[tokenNorm];
        if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tokenNorm);
    }

    /// @dev Centralized hook lookup with flag check
    function _hook(IPoolV1.PoolStorage storage $, address tokenNorm, uint32 flag)
        internal view
        returns (address h)
    {
        h = $.hooks[tokenNorm];
        if (h == address(0)) return address(0);
        return ($.hookFlags[tokenNorm] & flag) != 0 ? h : address(0);
    }

    /// @dev Normalize token address with storage context
    function _wrap(IPoolV1.PoolStorage storage $, address token)
        internal view
        returns (address)
    {
        return token == C.NATIVE ? $.wnative : token;
    }

    /// @dev Safe uint128 cast with overflow check
    function _toUint128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert Err.ExcessiveAmount(x, type(uint128).max);
        return uint128(x);
    }

    /// @dev Get balance of this contract
    function _balanceOf(address token) internal view returns (uint256) {
        return SafeTransferLib.balanceOf(token, address(this));
    }

    function _pull(address token, uint256 amount) internal returns (uint256 actual) {
        if (token == C.NATIVE) {
            if (msg.value < amount) revert Err.InsufficientAmount(msg.value, amount);
            IWETH9(_s().wnative).deposit{value: amount}();
            // H-02 FIX: Refund excess ETH to prevent trapped funds
            unchecked {
                uint256 excess = msg.value - amount;
                if (excess > 0) {
                    SafeTransferLib.safeTransferETH(msg.sender, excess);
                }
            }
            return amount;
        } else {
            uint256 balBefore = _balanceOf(token);
            SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
            return _balanceOf(token) - balBefore;
        }
    }

    function _push(address token, address to, uint256 amount) internal {
        if (token == C.NATIVE) {
            IWETH9(_s().wnative).withdraw(amount);
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            SafeTransferLib.safeTransfer(token, to, amount);
        }
    }

    function _checkRisk(IPoolV1.PoolStorage storage $, address token, uint16 requiredFlag) internal view {
        IPoolV1.RiskConfig storage risk = $.riskConfigs[token];
        if ((risk.flags & C.FROZEN_BIT) != 0) revert Err.FeatureDisabled(Err.Resource.ASSET);
        if (requiredFlag != 0 && (risk.flags & requiredFlag) == 0) {
            if (requiredFlag == C.SWAP_ENABLED_BIT) revert Err.FeatureDisabled(Err.Resource.SWAP);
            if (requiredFlag == C.LIABILITY_SWAP_ENABLED_BIT) revert Err.FeatureDisabled(Err.Resource.LIABILITY_SWAP);
            if (requiredFlag == C.FLASH_ENABLED_BIT) revert Err.FeatureDisabled(Err.Resource.FLASH);
        }
    }

    /// @dev Helper to read internal oracle with conditional configuration check
    function _readInternalOracle(
        IPoolV1.PoolStorage storage /* $ */,
        address token,
        bool requireConfigured
    ) internal view returns (IOracleV1.FeedData memory data, bool isFresh) {
        IPoolV1.FeedAccumulator storage acc = _os().accumulators[token];

        if (acc.lastUpdate == 0) {
            if (requireConfigured) revert Err.NotConfigured(Err.Resource.ORACLE, token);
            return (data, false);
        }

        data = IOracleV1.FeedData({
            lastPriceB64: acc.lastPriceB64,
            fastOffset: 0,
            slowOffset: 0,
            fastVolEMA: acc.fastVolEMA,
            slowVolEMA: acc.slowVolEMA,
            updatedAt: acc.lastUpdate,
            ttl: acc.ttl,
            confidence: acc.confidence
        });

        // M-05 FIX: Handle timestamp wrapping - future timestamps are not fresh
        if (block.timestamp < acc.lastUpdate) {
            // Future timestamp - treat as stale (defensive check for buggy module)
            isFresh = false;
        } else {
            unchecked {
                isFresh = block.timestamp - acc.lastUpdate <= acc.ttl;
            }
        }
    }

    /// @notice Read oracle data with fallback support
    /// @dev M-03 DOCUMENTATION: Oracle fallback economics
    ///      - Primary oracle failures trigger fallback WITHOUT price deviation checks
    ///      - Security relies on oracle infrastructure correctness, not on-chain validation
    ///      - If secondary oracle is manipulated and primary DoS'd, system accepts bad prices
    ///      - Mitigation: Use reputable oracle providers with independent infrastructure
    ///      - Future consideration: Add deviation circuit breaker at AMM math level
    function _readOracle(
        IPoolV1.PoolStorage storage $,
        address token
    ) internal virtual returns (IOracleV1.FeedData memory data) {
        // Try transient cache first (saves ~2,100 gas on cache hit)
        bool found;
        (found, data) = TCache.tryLoadOracleFeed(token);
        if (found) return data;

        // Cache miss: perform oracle read
        IPoolV1.OracleConfig memory cfg = $.oracleConfigs[token];
        if (cfg.primary == address(0)) revert Err.NotConfigured(Err.Resource.ORACLE, token);

        // M-02 FIX: Track actual age/maxAge for error reporting
        uint256 lastAge;
        uint256 lastMaxAge;

        // Try primary oracle
        bool isFresh;
        bool primaryFailed;

        if (cfg.primary == address(this)) {
            (data, isFresh) = _readInternalOracle($, token, true);
            if (isFresh) {
                // Cache for subsequent reads in this transaction
                TCache.cacheOracleFeed(token, data);
                return data;
            }
            // M-02 FIX: Capture staleness info
            unchecked {
                lastAge = block.timestamp - data.updatedAt;
                lastMaxAge = data.ttl;
            }
        } else {
            // CRITICAL FIX: Wrap external oracle calls in try/catch to prevent DoS
            // If primary oracle reverts (paused, maintenance, etc), fall back to secondary
            try IOracleV1(cfg.primary).getFeed(cfg.feedId) returns (IOracleV1.FeedData memory feedData) {
                data = feedData;
                try IOracleV1(cfg.primary).isFeedFresh(cfg.feedId) returns (bool fresh) {
                    if (fresh) {
                        // Cache for subsequent reads in this transaction
                        TCache.cacheOracleFeed(token, data);
                        return data;
                    }
                    // M-02 FIX: Capture staleness info
                    unchecked {
                        lastAge = block.timestamp - data.updatedAt;
                        lastMaxAge = data.ttl;
                    }
                } catch {
                    // isFeedFresh failed, treat as stale
                    primaryFailed = true;
                }
            } catch {
                // getFeed failed, mark primary as failed and try fallback
                primaryFailed = true;
            }
        }

        // Try fallback (if primary failed or returned stale data)
        if ((cfg.modeFlags & C.MODE_ALLOW_FALLBACK) != 0 && cfg.secondary != address(0)) {
            if (cfg.secondary == address(this)) {
                (data, isFresh) = _readInternalOracle($, token, false);
                if (isFresh) {
                    // Cache fallback result
                    TCache.cacheOracleFeed(token, data);
                    return data;
                }
                // M-02 FIX: Update staleness info
                unchecked {
                    lastAge = block.timestamp - data.updatedAt;
                    lastMaxAge = data.ttl;
                }
            } else {
                // CRITICAL FIX: Wrap external secondary oracle calls in try/catch
                try IOracleV1(cfg.secondary).getFeed(cfg.feedId) returns (IOracleV1.FeedData memory feedData) {
                    data = feedData;
                    try IOracleV1(cfg.secondary).isFeedFresh(cfg.feedId) returns (bool fresh) {
                        if (fresh) {
                            // Cache fallback result
                            TCache.cacheOracleFeed(token, data);
                            return data;
                        }
                        // M-02 FIX: Update staleness info
                        unchecked {
                            lastAge = block.timestamp - data.updatedAt;
                            lastMaxAge = data.ttl;
                        }
                    } catch {
                        // isFeedFresh failed on secondary, treat as stale
                        // Will revert below with staleness error
                    }
                } catch {
                    // Secondary oracle also failed
                    // If primary also failed, revert with oracle failure
                    if (primaryFailed) {
                        revert Err.NotConfigured(Err.Resource.ORACLE, token); // Both oracles failed
                    }
                    // Otherwise fall through to staleness check
                }
            }
        } else if (primaryFailed) {
            // No fallback configured and primary failed
            revert Err.NotConfigured(Err.Resource.ORACLE, token);
        }

        // M-02 FIX: Revert with actual staleness values
        revert Err.StaleData(uint32(lastAge), uint32(lastMaxAge));
    }

    /// @notice Apply liability decay if conditions are met
    /// @dev Consolidated implementation used by CoreV1 and FlashV1
    /// @param $ Storage pointer
    /// @param token Token address
    /// @param asset Asset storage
    function _applyDecay(IPoolV1.PoolStorage storage $, address token, IPoolV1.Asset storage asset) internal {
        IPoolV1.RiskConfig storage rc = $.riskConfigs[token];
        if ((rc.flags & C.DECAY_ENABLED_BIT) == 0 || rc.decaySlope == 0) {
            asset.lastUpdate = uint32(block.timestamp);
            return;
        }

        uint32 dt = uint32(block.timestamp) - asset.lastUpdate;
        if (dt == 0) return;

        // Inlined decay calculation (avoids importing LibPricing into BaseV1)
        uint128 decayAmount = _calculateDecay(
            asset.liabilities, asset.reserves, rc.decayStartRatioBps, rc.decaySlope, dt
        );

        if (decayAmount > 0) {
            asset.liabilities -= decayAmount;
        }

        asset.lastUpdate = uint32(block.timestamp);
    }

    /// @dev Inlined from LibPricing to avoid pulling entire pricing lib into all modules
    function _calculateDecay(
        uint128 liabilities,
        uint128 reserves,
        uint16 decayStartRatioBps,
        uint32 decaySlope,
        uint32 dt
    ) private pure returns (uint128) {
        if (dt == 0 || decaySlope == 0 || liabilities == 0) return 0;

        // Calculate coverage ratio (WAD units)
        uint256 coverage = liabilities == 0 ? type(uint256).max : (uint256(reserves) * 1e18) / uint256(liabilities);
        uint256 threshold = (uint256(decayStartRatioBps) * 1e18) / 1_000_000;

        // Only decay if coverage below threshold
        if (coverage >= threshold) return 0;

        // Linear decay: liabilities × decaySlope × dt / WAD
        uint256 rawDecay = (uint256(liabilities) * uint256(decaySlope) * uint256(dt)) / 1e18;

        // Cap at (liabilities - reserves) to maintain liabilities >= reserves
        uint256 maxDecay = liabilities > reserves ? liabilities - reserves : 0;
        return uint128(rawDecay > maxDecay ? maxDecay : rawDecay);
    }

    /// @notice Get asset price in base token units (with fallback)
    /// @dev Centralized price retrieval used across all modules
    ///      All oracle feeds are asset->base (base as quote), so price is directly usable
    /// @param $ Storage pointer
    /// @param token Token address to get price for
    /// @return price Price in base token units (1e18 scale)
    function _getAssetPrice(
        IPoolV1.PoolStorage storage $,
        address token
    ) internal virtual returns (uint256 price) {
        // Base token always priced at 1.0
        if (token == $.baseToken) return 1e18;

        // Get oracle data (with fallback logic)
        IOracleV1.FeedData memory data = _readOracle($, token);

        // Decode b64 price to 1e18 scale
        // Oracle feed is always asset->base (base as quote)
        // So lastPrice is already in base token units
        price = M.b64To1e18(data.lastPriceB64);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BRIDGE AUTHORIZATION (ERC7802)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Get authorized crosschain bridge contract
    /// @dev Called by bridgeable tokens to verify caller authorization
    /// @return bridge Address of authorized bridge (address(0) if none)
    function getAuthorizedBridge() external view returns (address bridge) {
        return _s().bridge;
    }
}
