// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPool} from "./interfaces/IPool.sol";
import {IPoolHooks} from "./interfaces/IPoolHooks.sol";
import {IPoolModule} from "./interfaces/modules/IPool.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {IERC20} from "./interfaces/external/IERC20.sol";
import {IWETH9} from "./interfaces/external/IWETH9.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Pricing} from "./libraries/Pricing.sol";
import {Maths as M} from "./libraries/Maths.sol";
import {Oracle} from "./libraries/Oracle.sol";
import {Constants as C} from "./libraries/Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {AnchorTree} from "./libraries/AnchorTree.sol";
import {TransientCache as TCache} from "./libraries/TransientCache.sol";

/// @title Pool — standalone AIMM (no proxy, no modules, no ERC-7201 indirection)
/// @notice Phase 42H.B.3d — drops ERC-7201, deletes Base.sol, collapses PoolProxy.
///         Each pool instance is now a direct EIP-1167 minimal-proxy clone of this impl
///         (deployment via PoolFactory). Per-clone state is initialized via initialize().
contract Pool {
    using SafeTransferLib for address;
    using {M.b64To1e18} for uint64;

    // ────────────────────────────────────────────────────────────────
    // STORAGE
    // ────────────────────────────────────────────────────────────────

    /// @dev Single struct holding all pool state — laid out at slot 0 onward.
    ///      Pricing/AnchorTree libraries take this by reference.
    IPool.PoolStorage internal $;

    // ────────────────────────────────────────────────────────────────
    // IMMUTABLES (set @ impl deploy; shared by all clones)
    // ────────────────────────────────────────────────────────────────

    /// @notice Shared singleton AccessControl (Phase 42H.B.1). Owner = `AccessControl(AC).owner()`.
    address public immutable AC;

    /// @notice Singleton Admin contract gating restricted setters.
    address public immutable admin;

    /// @notice Singleton Staking contract.
    address public immutable staking;

    /// @notice Singleton Flash contract.
    address public immutable flash;

    constructor(address ac_, address admin_, address staking_, address flash_) {
        if (ac_ == address(0) || admin_ == address(0) || staking_ == address(0) || flash_ == address(0)) {
            revert Err.ZeroAddr();
        }
        AC = ac_;
        admin = admin_;
        staking = staking_;
        flash = flash_;
    }

    // ────────────────────────────────────────────────────────────────
    // CONSTANTS
    // ────────────────────────────────────────────────────────────────

    /// @dev keccak256("pool.reentrancy.guard")
    bytes32 private constant REENTRANCY_GUARD_SLOT =
        0xe22c27e8d25bc3725093027126bd674994df6625365bae10cf4b95c8b45f98b6;

    /// @dev Initial liquidity index (1e12 → ~18M× growth before uint64 overflow).
    uint256 private constant INIT_LIQUIDITY_INDEX = 1e12;

    // Internal oracle TWAP constants (was: InternalOracle.sol).
    uint32 public constant FAST_WINDOW = 300;
    uint32 public constant SLOW_WINDOW = 3600;
    uint32 public constant FAST_VOL_ALPHA = 200;
    uint32 public constant SLOW_VOL_ALPHA = 1800;
    uint32 public constant MAX_VOLATILITY = 100 * uint32(SC.PBPS);
    uint16 public constant DEFAULT_TTL = 3600;
    uint256 private constant MAX_STALENESS = 604800;

    // ────────────────────────────────────────────────────────────────
    // EVENTS
    // ────────────────────────────────────────────────────────────────

    event Deposited(address indexed sender, address indexed token, uint256 amount, uint256 lpAmount);
    event Withdrawn(address indexed sender, address indexed token, uint256 amount, uint256 lpAmount);
    event LiabilitySwapped(address indexed sender, address indexed tokenIn, address indexed tokenOut, uint256 lpAmountIn, uint256 lpAmountOut, uint256 haircut);
    event Donated(address indexed sender, address indexed token, uint256 amount);

    // ────────────────────────────────────────────────────────────────
    // MODIFIERS
    // ────────────────────────────────────────────────────────────────

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

    modifier onlyOwner() {
        if (msg.sender != _owner()) revert Ownable.Unauthorized();
        _;
    }

    modifier whenInitialized() {
        if (!$.initialized) revert Err.InvalidState();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Ownable.Unauthorized();
        _;
    }

    modifier onlyStaking() {
        if (msg.sender != staking) revert Ownable.Unauthorized();
        _;
    }

    modifier onlyFlash() {
        if (msg.sender != flash) revert Ownable.Unauthorized();
        _;
    }

    // ────────────────────────────────────────────────────────────────
    // INITIALIZE (per-clone)
    // ────────────────────────────────────────────────────────────────

    /// @notice One-shot initializer for clone state (owner is the singleton AC).
    /// @dev Called atomically by PoolFactory.createPool — no front-run window.
    function initialize(
        address baseToken_,
        address wnative_,
        IPool.FeeParams calldata feeParams
    ) external {
        if ($.initialized) revert Err.InvalidState();
        if (feeParams.protoShare > 100) revert Err.InvalidInput();
        $.baseToken = baseToken_;
        $.wnative = wnative_;
        $.feeParams = feeParams;
        $.flowCooldownSeconds = C.DEFAULT_FLOW_COOLDOWN;
        $.initialized = true;
        emit IPool.PoolInitialized(_owner(), baseToken_, wnative_);
    }

    // ────────────────────────────────────────────────────────────────
    // HELPERS (was: Base.sol)
    // ────────────────────────────────────────────────────────────────

    /// @notice Single source of truth: shared singleton AccessControl owner.
    function _owner() internal view returns (address) {
        return AccessControl(AC).owner();
    }

    function _recordDeposit(address user, address asset) internal {
        $.lastDepositTime[user][asset] = uint32(block.timestamp);
    }

    function _checkWithdrawCooldown(address user, address asset) internal view {
        _checkCooldown($.lastDepositTime[user][asset]);
    }

    function _recordLPStake(address user, address lpToken) internal {
        $.lastLPStakeTime[user][lpToken] = uint32(block.timestamp);
    }

    function _checkLPUnstakeCooldown(address user, address lpToken) internal view {
        _checkCooldown($.lastLPStakeTime[user][lpToken]);
    }

    function _checkCooldown(uint32 lastTs) private view {
        uint16 cooldown = $.flowCooldownSeconds;
        if (cooldown == 0 || lastTs == 0) return;
        unchecked {
            if (block.timestamp < lastTs + cooldown) {
                revert Err.CooldownActive(lastTs + cooldown - uint32(block.timestamp));
            }
        }
    }

    function _asset(address tokenNorm) internal view returns (IPool.Asset storage asset) {
        asset = $.assets[tokenNorm];
        if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tokenNorm);
    }

    function _hook(address tokenNorm, uint32 flag) internal view returns (address h) {
        h = $.hooks[tokenNorm];
        if (h == address(0)) return address(0);
        return ($.hookFlags[tokenNorm] & flag) != 0 ? h : address(0);
    }

    function _wrap(address token) internal view returns (address) {
        return token == SC.NATIVE ? $.wnative : token;
    }

    function _balanceOf(address token) internal view returns (uint256) {
        return SafeTransferLib.balanceOf(token, address(this));
    }

    function _pull(address token, uint256 amount) internal returns (uint256) {
        if (token == SC.NATIVE) {
            if (msg.value < amount) revert Err.InsufficientAmount(msg.value, amount);
            IWETH9($.wnative).deposit{value: amount}();
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
        if (token == SC.NATIVE) {
            IWETH9($.wnative).withdraw(amount);
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            SafeTransferLib.safeTransfer(token, to, amount);
        }
    }

    function _checkRisk(address token, uint16 requiredFlag) internal view {
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
        address token,
        bool requireConfigured
    ) internal view returns (IOracle.FeedData memory data, bool isFresh) {
        IPool.FeedAccumulator storage acc = $.accumulators[token];

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

        if (block.timestamp < acc.lastUpdate) {
            isFresh = false;
        } else {
            unchecked { isFresh = block.timestamp - acc.lastUpdate <= acc.ttl; }
        }
    }

    /// @notice Read oracle with primary→fallback. DoS-resistant via try/catch.
    function _readOracle(address token) internal returns (IOracle.FeedData memory data) {
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
            (data, isFresh) = _readInternalOracle(token, true);
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
                (data, isFresh) = _readInternalOracle(token, false);
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
    function _applyDecay(address token, IPool.Asset storage asset) internal {
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

    /// @notice ERC7802 bridge auth — bridgeable tokens query this.
    function getAuthorizedBridge() external view returns (address) {
        return $.bridge;
    }

    // ────────────────────────────────────────────────────────────────
    // INTERNAL ORACLE (was: InternalOracle.sol)
    // ────────────────────────────────────────────────────────────────

    function getFeed(address token) external view returns (IOracle.FeedData memory data) {
        address t = _wrap(token);
        IPool.FeedAccumulator storage acc = $.accumulators[t];
        if (acc.lastUpdate == 0) revert Err.NotConfigured(Err.Resource.ORACLE, t);
        data = IOracle.FeedData({
            lastPriceB64: acc.lastPriceB64,
            fastOffset: acc.fastOffset,
            slowOffset: acc.slowOffset,
            fastVolEMA: acc.fastVolEMA,
            slowVolEMA: acc.slowVolEMA,
            updatedAt: acc.lastUpdate,
            ttl: acc.ttl,
            confidence: acc.confidence
        });
    }

    function isFeedFresh(address token, uint32 maxAge) external view returns (bool) {
        IPool.FeedAccumulator storage acc = $.accumulators[_wrap(token)];
        if (acc.lastUpdate == 0) return false;
        unchecked { return block.timestamp - acc.lastUpdate <= maxAge; }
    }

    function isFeedFresh(address token) external view returns (bool) {
        IPool.FeedAccumulator storage acc = $.accumulators[_wrap(token)];
        if (acc.lastUpdate == 0) return false;
        unchecked { return block.timestamp - acc.lastUpdate <= acc.ttl; }
    }

    function getFastTWAP(address token) external view returns (uint64) {
        address t = _wrap(token);
        IPool.FeedAccumulator storage acc = $.accumulators[t];
        if (acc.lastUpdate == 0) revert Err.NotConfigured(Err.Resource.ORACLE, t);
        int32 off = acc.fastOffset;
        if (off == 0) return acc.lastPriceB64;
        uint256 spot = M.b64To1e18(acc.lastPriceB64);
        int256 mult = int256(Oracle.ORACLE_PBPS) + int256(off);
        if (mult <= 0) return M.encodeB64(1, 18);
        uint256 twap = FixedPointMathLib.fullMulDiv(spot, uint256(mult), Oracle.ORACLE_PBPS);
        return M.encodeB64(twap, 18);
    }

    /// @notice Init/reset feed.
    function updateFeed(
        address token,
        uint64 initialPrice,
        uint8 accDecimals,
        uint32 fastVolEMA,
        uint32 slowVolEMA
    ) external {
        if (msg.sender != _owner() && msg.sender != address(this)) revert Ownable.Unauthorized();
        if (initialPrice == 0) revert Err.ZeroValue();
        if (accDecimals > 18) revert Err.InvalidInput();

        address t = _wrap(token);
        IPool.FeedAccumulator storage acc = $.accumulators[t];

        acc.lastPriceB64 = initialPrice;
        acc.accDecimals = accDecimals;
        acc.fastVolEMA = fastVolEMA;
        acc.slowVolEMA = slowVolEMA;
        acc.lastUpdate = uint32(block.timestamp);
        acc.ttl = DEFAULT_TTL;
        acc.confidence = 100;
        acc.priceAccB64 = 0;
        acc.fastSnapB64 = 0;
        acc.slowSnapB64 = 0;
        acc.fastSnapshotTime = uint32(block.timestamp);
        acc.slowSnapshotTime = uint32(block.timestamp);
        acc.fastOffset = 0;
        acc.slowOffset = 0;

        emit IOracle.OracleUpdated(t, initialPrice, fastVolEMA, slowVolEMA);
    }

    /// @dev Disabled — internal oracle updates via pushFeedInternal on swaps.
    function pushFeed(address, uint64, uint32) external pure {
        revert Err.InvalidInput();
    }

    /// @dev Inlined hot path. Skips msg.sender guard ∵ internal-only caller.
    function _pushFeedInternal(
        address tokenA,
        address tokenB,
        uint64 priceA,
        uint64 priceB
    ) internal {
        if (tokenA != address(0) && priceA != 0) _updateFeeds(tokenA, priceA);
        if (tokenB != address(0) && priceB != 0) _updateFeeds(tokenB, priceB);
    }

    function _updateFeeds(address token, uint64 newPrice) private {
        address t = _wrap(token);
        IPool.FeedAccumulator storage acc = $.accumulators[t];
        uint32 currentTime = uint32(block.timestamp);

        if (acc.lastUpdate == 0) {
            acc.lastPriceB64 = newPrice;
            acc.fastVolEMA = uint32(SC.ONE_PCT_PBPS / 100);
            acc.slowVolEMA = uint32(SC.ONE_PCT_PBPS / 100);
            acc.lastUpdate = currentTime;
            acc.ttl = DEFAULT_TTL;
            acc.confidence = 100;
            acc.accDecimals = 6;
            acc.fastSnapshotTime = currentTime;
            acc.slowSnapshotTime = currentTime;
            return;
        }

        unchecked {
            uint256 dt = currentTime - acc.lastUpdate;
            if (dt == 0) return;

            if (dt > MAX_STALENESS) {
                dt = MAX_STALENESS;
                acc.fastSnapB64 = acc.priceAccB64;
                acc.slowSnapB64 = acc.priceAccB64;
                acc.fastSnapshotTime = acc.lastUpdate;
                acc.slowSnapshotTime = acc.lastUpdate;
            }

            uint8 accDec = acc.accDecimals;
            uint256 lastPriceInAccDec = M.decodeB64(acc.lastPriceB64, accDec);
            uint256 currentAcc = acc.priceAccB64 == 0 ? 0 : M.decodeB64(acc.priceAccB64, accDec);
            currentAcc += lastPriceInAccDec * dt;
            acc.priceAccB64 = M.encodeB64(currentAcc, accDec);

            uint256 lastPriceInt = M.b64To1e18(acc.lastPriceB64);
            _rollWindow(acc, accDec, currentAcc, lastPriceInt, currentTime, true);
            _rollWindow(acc, accDec, currentAcc, lastPriceInt, currentTime, false);

            uint32 priceChange = M.diff1e6(acc.lastPriceB64, newPrice);
            acc.fastVolEMA = _updateVolEMA(acc.fastVolEMA, priceChange, FAST_VOL_ALPHA);
            acc.slowVolEMA = _updateVolEMA(acc.slowVolEMA, priceChange, SLOW_VOL_ALPHA);

            acc.lastPriceB64 = newPrice;
            acc.lastUpdate = currentTime;
            acc.confidence = 100;
        }
    }

    function _rollWindow(
        IPool.FeedAccumulator storage acc,
        uint8 accDec,
        uint256 currentAcc,
        uint256 lastPriceInt,
        uint32 currentTime,
        bool isFast
    ) private {
        uint32 windowSize = isFast ? FAST_WINDOW : SLOW_WINDOW;
        uint32 snapTime = isFast ? acc.fastSnapshotTime : acc.slowSnapshotTime;
        uint64 snapB64 = isFast ? acc.fastSnapB64 : acc.slowSnapB64;

        unchecked {
            uint256 dt = currentTime - snapTime;
            if (dt < windowSize) return;

            uint256 snapAcc = snapB64 == 0 ? 0 : M.decodeB64(snapB64, accDec);
            if (snapAcc > currentAcc) {
                if (isFast) { acc.fastSnapB64 = acc.priceAccB64; acc.fastSnapshotTime = currentTime; }
                else { acc.slowSnapB64 = acc.priceAccB64; acc.slowSnapshotTime = currentTime; }
                return;
            }

            uint256 twapInAccDec = (currentAcc - snapAcc) / dt;
            uint256 twap = twapInAccDec * (10 ** (18 - accDec));
            int32 offset = Oracle.encodeOffset1e18(lastPriceInt, twap);
            if (isFast) {
                acc.fastOffset = offset;
                acc.fastSnapB64 = acc.priceAccB64;
                acc.fastSnapshotTime = currentTime;
            } else {
                acc.slowOffset = offset;
                acc.slowSnapB64 = acc.priceAccB64;
                acc.slowSnapshotTime = currentTime;
            }
        }
    }

    function _updateVolEMA(uint32 oldVol, uint32 newVol, uint32 alpha) private pure returns (uint32) {
        unchecked {
            uint256 o = oldVol;
            uint256 n = newVol;
            uint256 delta = n > o ? ((n - o) * alpha) / SC.PBPS : ((o - n) * alpha) / SC.PBPS;
            if (n > o) {
                uint256 r = o + delta;
                return r > type(uint32).max ? type(uint32).max : uint32(r);
            }
            return uint32(o - delta);
        }
    }

    // ────────────────────────────────────────────────────────────────
    // LIQUIDITY DOMAIN
    // ────────────────────────────────────────────────────────────────

    function deposit(
        address token,
        uint256 amount
    ) external payable nonReentrant whenInitialized returns (IPool.DepositResult memory) {
        if (amount == 0) revert Err.ZeroValue();

        address tkn = _wrap(token);
        IPool.Asset storage asset = _asset(tkn);

        _applyDecay(tkn, asset);
        if (($.riskConfigs[tkn].flags & C.FROZEN_BIT) != 0) revert Err.FeatureDisabled(Err.Resource.ASSET);

        uint256 amt = _pull(token, amount);
        if (amt > type(uint128).max) revert Err.ExcessiveAmount(amt, type(uint128).max);

        uint256 lpAmt = (amt * SC.WAD) / (asset.liquidityIndex == 0 ? INIT_LIQUIDITY_INDEX : asset.liquidityIndex);

        asset.reserves += uint128(amt);
        asset.liabilities += uint128(amt);
        $.lpBalances[msg.sender][tkn] += lpAmt;
        _recordDeposit(msg.sender, tkn);

        emit Deposited(msg.sender, tkn, amt, lpAmt);
        return IPool.DepositResult({lpAmount: lpAmt, actualDeposit: amt});
    }

    function donate(address token, uint256 amount) external payable nonReentrant whenInitialized {
        if (amount == 0) revert Err.ZeroValue();

        address tkn = _wrap(token);
        IPool.Asset storage asset = _asset(tkn);

        _applyDecay(tkn, asset);
        _checkRisk(tkn, 0);

        uint256 amt = _pull(token, amount);
        if (amt > type(uint128).max) revert Err.ExcessiveAmount(amt, type(uint128).max);

        uint256 liabBefore = uint256(asset.liabilities);
        asset.reserves += uint128(amt);
        asset.liabilities += uint128(amt);

        uint256 idx = asset.liquidityIndex == 0 ? INIT_LIQUIDITY_INDEX : asset.liquidityIndex;
        asset.liquidityIndex = uint64(liabBefore == 0 ? idx : (idx * (liabBefore + amt)) / liabBefore);

        emit Donated(msg.sender, token, amt);
    }

    function withdraw(
        address token,
        uint256 lpAmount,
        uint256 minAmountOut
    ) external nonReentrant whenInitialized returns (IPool.WithdrawResult memory) {
        return _withdrawTo(token, token, lpAmount, minAmountOut);
    }

    function withdrawTo(
        address tokenFrom,
        address tokenTo,
        uint256 lpAmount,
        uint256 minAmountOut
    ) public nonReentrant whenInitialized returns (IPool.WithdrawResult memory) {
        return _withdrawTo(tokenFrom, tokenTo, lpAmount, minAmountOut);
    }

    function _withdrawTo(
        address tokenFrom,
        address tokenTo,
        uint256 lpAmount,
        uint256 minAmountOut
    ) private returns (IPool.WithdrawResult memory) {
        if (lpAmount == 0) revert Err.ZeroValue();

        address fromTk = _wrap(tokenFrom);
        address toTk = _wrap(tokenTo);

        _checkWithdrawCooldown(msg.sender, fromTk);
        if ($.lpBalances[msg.sender][fromTk] < lpAmount) {
            revert Err.InsufficientAmount($.lpBalances[msg.sender][fromTk], lpAmount);
        }

        IPool.Asset storage assetFrom = _asset(fromTk);
        IPool.Asset storage assetTo = _asset(toTk);
        _applyDecay(fromTk, assetFrom);
        _applyDecay(toTk, assetTo);

        uint256 withdrawValue = (lpAmount * (assetFrom.liquidityIndex == 0 ? INIT_LIQUIDITY_INDEX : assetFrom.liquidityIndex)) / SC.WAD;
        uint256 amt;
        uint256 haircut;

        if (fromTk == toTk) {
            (amt, haircut) = _applyHaircut(withdrawValue, assetFrom.reserves, assetFrom.liabilities, assetFrom.haircutSuppressor);
            if (assetFrom.reserves < amt) revert Err.InsufficientAmount(assetFrom.reserves, amt);
            if (amt > type(uint128).max) revert Err.ExcessiveAmount(amt, type(uint128).max);

            uint256 liabRed = withdrawValue > assetFrom.liabilities ? assetFrom.liabilities : withdrawValue;
            assetFrom.reserves -= uint128(amt);
            assetFrom.liabilities -= uint128(liabRed);
        } else {
            IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, fromTk, toTk, withdrawValue);
            (amt, haircut) = _applyHaircut(q.amountOut, assetTo.reserves, assetTo.liabilities, assetTo.haircutSuppressor);
            if (assetTo.reserves < amt + q.protoFee) revert Err.InsufficientAmount(assetTo.reserves, amt + q.protoFee);

            uint256 liabRed = withdrawValue > assetFrom.liabilities ? assetFrom.liabilities : withdrawValue;
            assetFrom.liabilities -= uint128(liabRed);

            if (q.protoFee > 0) $.protocolFees[toTk] += q.protoFee;
            assetTo.reserves -= uint128(amt + q.protoFee);
        }

        $.lpBalances[msg.sender][fromTk] -= lpAmount;
        if (assetTo.reserves < assetTo.minLiquidity) {
            revert Err.ThresholdViolation(assetTo.reserves, assetTo.minLiquidity);
        }
        if (amt < minAmountOut) revert Err.ThresholdViolation(amt, minAmountOut);
        _push(tokenTo, msg.sender, amt);

        if (fromTk == toTk) {
            emit Withdrawn(msg.sender, fromTk, amt, lpAmount);
        } else {
            emit LiabilitySwapped(msg.sender, fromTk, toTk, lpAmount, 0, haircut);
            emit Withdrawn(msg.sender, toTk, amt, lpAmount);
        }
        return IPool.WithdrawResult({amountOut: amt, lpBurned: lpAmount});
    }

    function swapLiability(
        address tokenIn,
        address tokenOut,
        uint256 lpAmountIn,
        uint256 minLpAmountOut
    ) external nonReentrant whenInitialized returns (uint256 lpAmountOut) {
        if (lpAmountIn == 0) revert Err.ZeroValue();

        address inTk = _wrap(tokenIn);
        address outTk = _wrap(tokenOut);
        if (inTk == outTk) revert Err.InvalidInput();

        IPool.Asset storage assetIn = $.assets[inTk];
        IPool.Asset storage assetOut = $.assets[outTk];
        if (assetIn.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, inTk);
        if (assetOut.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, outTk);

        _applyDecay(inTk, assetIn);
        _applyDecay(outTk, assetOut);
        _checkRisk(inTk, C.LIABILITY_SWAP_ENABLED_BIT);
        _checkRisk(outTk, C.LIABILITY_SWAP_ENABLED_BIT);

        if ($.lpBalances[msg.sender][inTk] < lpAmountIn) {
            revert Err.InsufficientAmount($.lpBalances[msg.sender][inTk], lpAmountIn);
        }

        uint256 liabIn = (lpAmountIn * (assetIn.liquidityIndex == 0 ? INIT_LIQUIDITY_INDEX : assetIn.liquidityIndex)) / SC.WAD;
        if (liabIn > assetIn.liabilities) revert Err.InsufficientAmount(assetIn.liabilities, liabIn);

        IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, inTk, outTk, liabIn);
        uint256 liabOut = q.amountOut;
        uint256 haircut;

        if (assetOut.reserves < assetOut.liabilities) {
            (liabOut, haircut) = _applyHaircut(liabOut, assetOut.reserves, assetOut.liabilities, assetOut.haircutSuppressor);
        }

        lpAmountOut = (liabOut * SC.WAD) / (assetOut.liquidityIndex == 0 ? INIT_LIQUIDITY_INDEX : assetOut.liquidityIndex);

        assetIn.liabilities -= uint128(liabIn);
        assetOut.liabilities += uint128(liabOut);
        if (lpAmountOut < minLpAmountOut) revert Err.ThresholdViolation(lpAmountOut, minLpAmountOut);

        $.lpBalances[msg.sender][inTk] -= lpAmountIn;
        $.lpBalances[msg.sender][outTk] += lpAmountOut;

        emit LiabilitySwapped(msg.sender, inTk, outTk, lpAmountIn, lpAmountOut, haircut);
        return lpAmountOut;
    }

    function _applyHaircut(
        uint256 amount,
        uint128 reserves,
        uint128 liabilities,
        uint16 suppression
    ) private pure returns (uint256 actualAmount, uint256 haircutAmount) {
        if (liabilities == 0 || reserves >= liabilities) return (amount, 0);
        uint256 deficit = ((uint256(liabilities) - uint256(reserves)) * 1e18) / uint256(liabilities);
        uint256 factor = suppression >= 20000 ? 0 : 1e18 - (uint256(suppression) * 1e18 / 20000);
        uint256 haircutRatio = (deficit * factor) / 1e18;
        if (haircutRatio > 1e18) haircutRatio = 1e18;
        haircutAmount = (amount * haircutRatio) / 1e18;
        actualAmount = amount - haircutAmount;
    }

    // ────────────────────────────────────────────────────────────────
    // EXCHANGE DOMAIN
    // ────────────────────────────────────────────────────────────────

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external payable nonReentrant whenInitialized returns (uint256 out) {
        address[2] memory tk = [_wrap(tokenIn), _wrap(tokenOut)];
        if (tk[0] == tk[1]) revert Err.InvalidInput();
        if (amountIn == 0) revert Err.ZeroValue();

        _checkRisk(tk[0], C.SWAP_ENABLED_BIT);
        _checkRisk(tk[1], C.SWAP_ENABLED_BIT);
        _applyDecay(tk[0], $.assets[tk[0]]);
        _applyDecay(tk[1], $.assets[tk[1]]);

        uint256 actualIn = _pull(tokenIn, amountIn);
        IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, tk[0], tk[1], actualIn);

        out = _processSwap(tk, actualIn, q);

        if ($.assets[tk[1]].reserves < $.assets[tk[1]].minLiquidity) {
            revert Err.ThresholdViolation($.assets[tk[1]].reserves, $.assets[tk[1]].minLiquidity);
        }

        _oracle(q);
        if (out < minAmountOut) revert Err.ThresholdViolation(out, minAmountOut);

        _push(tokenOut, recipient, out);
        emit IPoolModule.Swapped(msg.sender, recipient, tk[0], tk[1], actualIn, out, q.spreadBps, q.protoFee, q.lpFee);
    }

    function _processSwap(
        address[2] memory tk,
        uint256 actualIn,
        IPool.SwapQuote memory q
    ) internal returns (uint256 out) {
        (uint256 extraFee, uint16 feeOverride) = _preSwap(tk[0], tk[1], actualIn, q.amountOut);
        out = q.amountOut;

        if (feeOverride > 0) {
            uint256 raw = out + q.protoFee + q.lpFee;
            uint256 fee = (raw * feeOverride) / 1_000_000;
            (q.protoFee, q.lpFee) = Pricing.splitFee(fee, $.feeParams.protoShare);
            q.spreadBps = feeOverride;
            q.amountOut = raw - fee;
            out = q.amountOut;
        }

        out = _applyHookFee(extraFee, q, out);
        _exec(tk[0], tk[1], actualIn, q);

        int256 delta = _postSwap(tk[0], tk[1], actualIn, out);
        uint256 protoDelta = 0;
        if (delta > 0) {
            uint256 protoBefore = q.protoFee;
            out = _applyHookFee(uint256(delta), q, out);
            protoDelta = q.protoFee - protoBefore;
            if (protoDelta != 0) {
                $.protocolFees[tk[1]] += protoDelta;
            }
        } else if (delta < 0) {
            out += uint256(-delta);
        }

        _reconcile($.assets[tk[1]], out, q.amountOut);

        if (protoDelta != 0) {
            $.assets[tk[1]].reserves -= uint128(protoDelta);
        }
    }

    function getSwapQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external returns (IPool.SwapQuote memory) {
        return Pricing.getAnchorPathQuote($, _wrap(tokenIn), _wrap(tokenOut), amountIn);
    }

    function batchSwap(
        bytes calldata inputs,
        bytes calldata outputs,
        address recipient
    ) external payable nonReentrant whenInitialized returns (uint256[] memory amountsOut) {
        uint256 inLen = inputs.length / 32;
        uint256 outLen = outputs.length / 32;

        if (inputs.length % 32 != 0 || inLen == 0 || inLen > 8) revert Err.InvalidInput();
        if (outputs.length % 32 != 0 || outLen == 0 || outLen > 8) revert Err.InvalidInput();

        address base = $.baseToken;
        amountsOut = new uint256[](outLen);
        uint256 baseTotal;

        for (uint256 i; i < inLen;) {
            address tk; uint64 amtB64;
            assembly {
                let packed := calldataload(add(inputs.offset, mul(i, 32)))
                tk := shr(96, packed)
                amtB64 := and(shr(32, packed), 0xFFFFFFFFFFFFFFFF)
            }
            tk = _wrap(tk);
            IPool.Asset storage a = $.assets[tk];
            if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tk);

            _checkRisk(tk, C.SWAP_ENABLED_BIT);
            _applyDecay(tk, a);

            uint256 amt = _pull(tk == $.wnative ? SC.NATIVE : tk, M.decodeB64(amtB64, a.decimals));

            if (tk == base) {
                baseTotal += amt;
            } else {
                IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, tk, base, amt);
                _exec(tk, base, amt, q);
                _oracle(q);
                baseTotal += q.amountOut;
            }
            unchecked { ++i; }
        }

        if (baseTotal == 0) revert Err.ZeroValue();

        uint256 wSum;
        for (uint256 j; j < outLen;) {
            address tk; uint16 w; uint64 minB64;
            assembly {
                let packed := calldataload(add(outputs.offset, mul(j, 32)))
                tk := shr(96, packed)
                w := and(shr(80, packed), 0xFFFF)
                minB64 := and(packed, 0xFFFFFFFFFFFFFFFF)
            }
            tk = _wrap(tk);
            IPool.Asset storage a = $.assets[tk];
            if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tk);

            wSum += w;
            uint256 baseIn = (baseTotal * w) / 10000;

            _checkRisk(tk, C.SWAP_ENABLED_BIT);
            _applyDecay(tk, a);

            if (tk == base) {
                amountsOut[j] = baseIn;
            } else {
                IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, base, tk, baseIn);
                _exec(base, tk, baseIn, q);
                _oracle(q);
                amountsOut[j] = q.amountOut;
            }

            uint256 minOut = M.decodeB64(minB64, a.decimals);
            if (amountsOut[j] < minOut) revert Err.ThresholdViolation(amountsOut[j], minOut);
            unchecked { ++j; }
        }

        if (wSum != 10000) revert Err.InvalidInput();

        for (uint256 j; j < outLen;) {
            address tk;
            assembly { tk := shr(96, calldataload(add(outputs.offset, mul(j, 32)))) }
            tk = _wrap(tk);
            _push(tk == $.wnative ? SC.NATIVE : tk, recipient, amountsOut[j]);
            unchecked { ++j; }
        }

        emit IPoolModule.BatchSwapped(msg.sender, recipient, inLen, outLen, baseTotal);
    }

    // ── Views ──
    function owner() external view returns (address) { return _owner(); }
    function baseToken() external view returns (address) { return $.baseToken; }
    function wnative() external view returns (address) { return $.wnative; }
    function treasury() external view returns (address) { return $.treasury; }

    function getAsset(address tk) external view returns (IPool.Asset memory) {
        return $.assets[_wrap(tk)];
    }
    function getLPBalance(address u, address tk) external view returns (uint256) {
        return $.lpBalances[u][_wrap(tk)];
    }
    function getProtocolFees(address tk) external view returns (uint256) {
        return $.protocolFees[_wrap(tk)];
    }
    function getRiskFlags(address tk) external view returns (uint16) {
        return $.riskConfigs[_wrap(tk)].flags;
    }
    function getFeeParams() external view returns (IPool.FeeParams memory) { return $.feeParams; }
    function getHookForFlag(address tk, uint32 flag) external view returns (address) {
        return _hook(_wrap(tk), flag);
    }
    function getMidPrice(address tk) external returns (uint256) {
        return _readOracle(_wrap(tk)).lastPriceB64.b64To1e18();
    }

    // ── Internal swap helpers ──

    function _exec(
        address tkIn,
        address tkOut,
        uint256 amtIn,
        IPool.SwapQuote memory q
    ) private {
        IPool.Asset storage aIn = $.assets[tkIn];
        IPool.Asset storage aOut = $.assets[tkOut];

        uint256 minReq = q.amountOut + q.protoFee + aOut.minLiquidity;
        if (aOut.reserves < minReq) revert Err.InsufficientAmount(aOut.reserves, minReq);

        uint256 inFee = (amtIn * q.spreadBps / 2) / 1_000_000;
        aIn.reserves += uint128(amtIn - inFee);
        $.protocolFees[tkIn] += inFee;
        aOut.reserves -= uint128(q.amountOut + q.protoFee);
        $.protocolFees[tkOut] += q.protoFee;

        uint64 floor = aOut.reservationPrice;
        if (floor != 0) {
            uint64 price = _readOracle(tkOut).lastPriceB64;
            if (price < floor) revert Err.PriceBelowReservation(price, floor);
        }
    }

    function _oracle(IPool.SwapQuote memory q) private {
        if (q.routeHops.length < 2 || q.hopPrices.length == 0) return;
        address base = $.baseToken;

        for (uint256 i; i < q.routeHops.length - 1;) {
            address a = q.routeHops[i];
            address b = q.routeHops[i + 1];
            uint64 p = q.hopPrices[i];

            if (a == base) _pushFeedInternal(b, address(0), p, 0);
            else if (b == base) _pushFeedInternal(a, address(0), p, 0);
            else _pushFeedInternal(a, b, p, p);

            unchecked { ++i; }
        }
    }

    function _runHook(
        address tk,
        address other,
        uint32 flag,
        bool isPre,
        address tkIn,
        address tkOut,
        uint256 amtIn,
        uint256 amtOutOrFee
    ) private returns (uint256 extraFee, uint16 feeOverride, int256 delta) {
        address h = $.hooks[tk];
        if (h == address(0) || h == other) return (0, 0, 0);
        if (($.hookFlags[tk] & flag) == 0) return (0, 0, 0);

        if (isPre) {
            (uint256 f, uint16 o) = IPoolHooks(h).preSwap(address(this), msg.sender, tkIn, tkOut, amtIn, amtOutOrFee);
            return (f, o, 0);
        }
        return (0, 0, IPoolHooks(h).postSwap(address(this), msg.sender, tkIn, tkOut, amtIn, amtOutOrFee));
    }

    function _preSwap(
        address tkIn,
        address tkOut,
        uint256 amtIn,
        uint256 amtOut
    ) private returns (uint256 extraFee, uint16 feeOverride) {
        (uint256 f1, uint16 o1, ) = _runHook(tkIn, address(0), C.HOOK_PRE_SWAP, true, tkIn, tkOut, amtIn, amtOut);
        extraFee += f1;
        if (o1 > 0) feeOverride = o1;
        (uint256 f2, uint16 o2, ) = _runHook(tkOut, $.hooks[tkIn], C.HOOK_PRE_SWAP, true, tkIn, tkOut, amtIn, amtOut);
        extraFee += f2;
        if (o2 > 0) feeOverride = o2;
    }

    function _postSwap(
        address tkIn,
        address tkOut,
        uint256 amtIn,
        uint256 amtOut
    ) private returns (int256) {
        (, , int256 d1) = _runHook(tkIn, address(0), C.HOOK_POST_SWAP, false, tkIn, tkOut, amtIn, amtOut);
        (, , int256 d2) = _runHook(tkOut, $.hooks[tkIn], C.HOOK_POST_SWAP, false, tkIn, tkOut, amtIn, amtOut);
        return d1 + d2;
    }

    function _applyHookFee(
        uint256 fee,
        IPool.SwapQuote memory q,
        uint256 out
    ) private view returns (uint256) {
        if (fee == 0) return out;
        (uint256 pf, uint256 lf) = Pricing.splitFee(fee, $.feeParams.protoShare);
        q.protoFee += pf;
        q.lpFee += lf;
        return out > fee ? out - fee : 0;
    }

    function _reconcile(IPool.Asset storage a, uint256 actual, uint256 expected) private {
        if (actual == expected) return;
        uint256 d = actual > expected ? actual - expected : expected - actual;
        if (d > type(uint128).max) revert Err.ExcessiveAmount(d, type(uint128).max);
        if (actual > expected) a.reserves -= uint128(d);
        else a.reserves += uint128(d);
    }

    // ────────────────────────────────────────────────────────────────
    // ADMIN DOMAIN — restricted setters gated by `admin` singleton
    // ────────────────────────────────────────────────────────────────

    function adminFreezeAsset(address token) external onlyAdmin {
        address t = _wrap(token);
        _asset(t);
        $.riskConfigs[t].flags |= C.FROZEN_BIT;
    }

    function adminUnfreezeAsset(address token) external onlyAdmin {
        address t = _wrap(token);
        _asset(t);
        $.riskConfigs[t].flags &= ~C.FROZEN_BIT;
    }

    function adminInitAsset(
        address token,
        IPool.OracleConfig calldata oracleCfg,
        IPool.RiskConfig calldata riskCfg,
        IPool.LiquidityProfile calldata profile,
        uint16 minFeeBps,
        uint8 decimals,
        uint64 initialPrice,
        uint32 initialFastVolEMA,
        uint32 initialSlowVolEMA,
        uint32 minDispersion,
        uint32 maxDispersion,
        uint16 gamma,
        uint16 vega,
        uint16 lambda
    ) external onlyAdmin {
        if (initialPrice == 0) revert Err.ZeroValue();
        if (initialFastVolEMA == 0 || initialSlowVolEMA == 0) revert Err.InvalidInput();

        address t = _wrap(token);
        if ($.assets[t].decimals != 0) revert Err.AlreadyConfigured(Err.Resource.ASSET, t);

        _validateProfileMemory(profile);
        _validateOracleConfig(oracleCfg);
        _initAsset(t, decimals, minFeeBps, minDispersion, maxDispersion, gamma, vega, lambda);
        _setupOracleAndConfig(t, oracleCfg, riskCfg, profile, initialPrice, initialFastVolEMA, initialSlowVolEMA);
    }

    function adminCollectProtocolFees(address token, address recipient)
        external nonReentrant onlyAdmin returns (uint256 amount)
    {
        address t = _wrap(token);
        amount = $.protocolFees[t];
        if (amount > 0) {
            $.protocolFees[t] = 0;
            _push(token, recipient, amount);
        }
    }

    function adminSetFlowCooldown(uint16 cooldownSeconds) external onlyAdmin {
        $.flowCooldownSeconds = cooldownSeconds;
    }

    function adminSetAnchor(address token, address anchor) external onlyAdmin {
        address t = _wrap(token);
        IPool.Asset storage asset = $.assets[t];
        if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
        uint8 depth = AnchorTree.validateAnchor($, t, anchor);
        asset.anchor = anchor;
        asset.anchorDepth = depth;
    }

    function adminSetAssetParams(
        address token,
        uint128 minLiquidity,
        uint16 minFeeBps,
        uint16 maxFeeBps,
        uint16 gamma,
        uint16 vega,
        uint16 lambda,
        uint16 haircutSuppressor,
        uint64 reservationPrice
    ) external onlyAdmin {
        address t = _wrap(token);
        IPool.Asset storage asset = $.assets[t];
        if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
        if (minFeeBps > maxFeeBps) revert Err.InvalidInput();

        asset.minLiquidity = minLiquidity;
        asset.minFeeBps = minFeeBps;
        asset.maxFeeBps = maxFeeBps;
        asset.gamma = gamma;
        asset.vega = vega;
        asset.lambda = lambda;
        asset.haircutSuppressor = haircutSuppressor;
        asset.reservationPrice = reservationPrice;
    }

    function adminSetRiskConfig(address token, IPool.RiskConfig calldata cfg) external onlyAdmin {
        address t = _wrap(token);
        _asset(t);
        $.riskConfigs[t] = cfg;
    }

    function adminSetOracleConfig(address token, IPool.OracleConfig calldata cfg) external onlyAdmin {
        _validateOracleConfig(cfg);
        $.oracleConfigs[token] = cfg;
    }

    function adminSetFeeParams(IPool.FeeParams calldata params) external onlyAdmin {
        if (params.protoShare > 100) revert Err.InvalidInput();
        $.feeParams = params;
    }

    function adminSetBridge(address newBridge) external onlyAdmin {
        $.bridge = newBridge;
    }

    function adminSetTreasury(address newTreasury) external onlyAdmin {
        if (newTreasury == address(0)) revert Err.ZeroValue();
        $.treasury = newTreasury;
    }

    function adminSetBaseToken(address newBase) external onlyAdmin {
        $.baseToken = newBase;
    }

    // ────────────────────────────────────────────────────────────────
    // STAKING — restricted setter gated by `staking` singleton
    // ────────────────────────────────────────────────────────────────

    function stakingAdjustLpBalance(address user, address token, int256 delta) external onlyStaking {
        address t = _wrap(token);
        if (delta > 0) {
            $.lpBalances[user][t] += uint256(delta);
        } else if (delta < 0) {
            uint256 d = uint256(-delta);
            uint256 cur = $.lpBalances[user][t];
            if (cur < d) revert Err.InsufficientAmount(cur, d);
            $.lpBalances[user][t] = cur - d;
        }
    }

    // ────────────────────────────────────────────────────────────────
    // FLASH — restricted setters gated by `flash` singleton
    // ────────────────────────────────────────────────────────────────

    function flashSend(address token, uint256 amount, address to) external onlyFlash whenInitialized nonReentrant {
        address t = _wrap(token);
        IPool.Asset storage asset = _asset(t);
        _applyDecay(t, asset);
        if (amount == 0) revert Err.ZeroValue();
        if (asset.reserves < amount || asset.reserves - amount < asset.minLiquidity) {
            revert Err.InsufficientAmount(asset.reserves, amount);
        }
        _push(token, to, amount);
    }

    function flashAccount(address token, uint256 fee, uint256 protoFee) external onlyFlash {
        if (protoFee > fee) revert Err.InvalidInput();
        address t = _wrap(token);
        IPool.Asset storage asset = _asset(t);
        unchecked { asset.reserves += uint128(fee - protoFee); }
        $.protocolFees[t] += protoFee;
    }

    // ── helpers ──

    function _validateProfileMemory(IPool.LiquidityProfile memory profile) internal pure {
        if (profile.weights[0] == 0) revert Err.InvalidInput();

        uint256 sum = 0;
        uint256 segmentCount = 0;
        unchecked {
            for (uint256 i = 0; i < 16; ++i) {
                if (profile.weights[i] == 0) { segmentCount = i; break; }
                sum += profile.weights[i];
                if (i == 15) segmentCount = 16;
            }
        }
        if (segmentCount == 0 || sum != 200) revert Err.InvalidInput();

        uint256 knotCount = segmentCount + 1;
        unchecked {
            for (uint256 i = 1; i < knotCount; ++i) {
                if (profile.knots[i] < profile.knots[i - 1]) revert Err.InvalidInput();
            }
        }
        if (int16(profile.knots[knotCount - 1]) - int16(profile.knots[0]) != 100) revert Err.InvalidInput();
    }

    function _validateOracleConfig(IPool.OracleConfig memory cfg) internal view {
        if (cfg.primary == address(0)) revert Err.InvalidInput();
        if (cfg.primary != address(this)) {
            try IOracle(cfg.primary).getFeed(cfg.feedId) returns (IOracle.FeedData memory) {} catch {
                revert Err.InvalidInput();
            }
        }
        if (cfg.secondary != address(0) && cfg.secondary != address(this)) {
            try IOracle(cfg.secondary).getFeed(cfg.feedId) returns (IOracle.FeedData memory) {} catch {
                revert Err.InvalidInput();
            }
        }
    }

    function _initAsset(
        address t,
        uint8 decimals,
        uint16 minFeeBps,
        uint32 minDispersion,
        uint32 maxDispersion,
        uint16 gamma,
        uint16 vega,
        uint16 lambda
    ) internal {
        IPool.Asset storage asset = $.assets[t];
        asset.decimals = decimals;
        asset.minFeeBps = minFeeBps;
        asset.maxFeeBps = 10000;
        asset.minLiquidity = 0;
        asset.minDispersion = minDispersion == 0 ? 1000 : minDispersion;
        asset.maxDispersion = maxDispersion == 0 ? 100000 : maxDispersion;
        asset.gamma = gamma == 0 ? 10000 : gamma;
        asset.vega = vega == 0 ? 10000 : vega;
        asset.lambda = lambda == 0 ? 10000 : lambda;
        asset.haircutSuppressor = 10000;

        if (t == $.baseToken) {
            asset.anchor = address(0);
            asset.anchorDepth = 0;
        } else {
            asset.anchor = $.baseToken;
            asset.anchorDepth = 1;
        }
    }

    function _setupOracleAndConfig(
        address t,
        IPool.OracleConfig memory oracleCfg,
        IPool.RiskConfig memory riskCfg,
        IPool.LiquidityProfile memory profile,
        uint64 initialPrice,
        uint32 initialFastVolEMA,
        uint32 initialSlowVolEMA
    ) internal {
        $.oracleConfigs[t] = oracleCfg;
        $.riskConfigs[t] = riskCfg;
        $.profiles[t] = profile;

        if (oracleCfg.primary == address(this)) {
            uint8 accDec = oracleCfg.accDecimals == 0 ? 6 : oracleCfg.accDecimals;
            // Self-call to satisfy `msg.sender == address(this)` gate inside updateFeed.
            try Pool(payable(address(this))).updateFeed(t, initialPrice, accDec, initialFastVolEMA, initialSlowVolEMA) {} catch {
                revert Err.OperationFailed();
            }
        }
    }

    receive() external payable {}
}
