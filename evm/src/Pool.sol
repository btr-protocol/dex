// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "./interfaces/IPool.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {IERC20} from "./interfaces/external/IERC20.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Pricing} from "./libraries/Pricing.sol";
import {Maths as M} from "./libraries/Maths.sol";
import {Constants as C} from "./libraries/Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {PoolOracle} from "./libraries/PoolOracle.sol";
import {PoolHookExec} from "./libraries/PoolHookExec.sol";
import {PoolAdminWrite} from "./libraries/PoolAdminWrite.sol";
import {PoolBatch} from "./libraries/PoolBatch.sol";
import {PoolLiquidity} from "./libraries/PoolLiquidity.sol";
import {PoolSwap} from "./libraries/PoolSwap.sol";
import {PoolEdge} from "./libraries/PoolEdge.sol";

/// @title Pool -standalone AIMM (no proxy, no modules, no ERC-7201 indirection)
/// @notice Phase 42H.B.3d -drops ERC-7201, deletes Base.sol, collapses PoolProxy.
///         Each pool instance is now a direct EIP-1167 minimal-proxy clone of this impl
///         (deployment via PoolFactory). Per-clone state is initialized via initialize().
/// @dev STORAGE LAYOUT (Phase 42H.B.3d intentional decision):
///      `IPool.PoolStorage $` lives at slot 0 of every clone. We do NOT use ERC-7201
///      namespaced slots because:
///        1. Each Pool is a fresh EIP-1167 clone (its own storage space) -no slot
///           collision risk with delegate-callers, libraries, or other state.
///        2. Pool is non-upgradeable per-instance (clones cannot upgrade); the
///           `referencePool` impl is replaceable only via PoolFactory's 7d-timelocked
///           swap, which produces NEW clones rather than mutating live storage.
///        3. Slot-0 layout removes the keccak deref overhead on every storage access
///           (hot path: swap, deposit, withdraw) -material gas saving across the
///           thousands of `$.<field>` accesses in this contract.
///      UPGRADE-SAFETY NOTE: any change to `IPool.PoolStorage` field order or types
///      would break existing clones if they were ever migrated. New `referencePool`
///      impls MUST keep `PoolStorage` append-only (new fields appended; existing
///      fields' offsets/types unchanged). See Phase 42H.B.3d ADR.
contract Pool is ReentrancyGuardTransient {
    using {M.b64To1e18} for uint64;

    // ────────────────────────────────────────────────────────────────
    // STORAGE
    // ────────────────────────────────────────────────────────────────

    /// @dev Single struct holding all pool state -laid out at slot 0 onward.
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

    /// @dev Initial liquidity index (1e12 → ~18M× growth before uint64 overflow).
    uint256 private constant INIT_LIQUIDITY_INDEX = 1e12;

    /// @notice Oracle constants (mirror `PoolOracle` lib values). Demoted to internal
    ///         (Wave-1 over-exposed-getter cleanup) -consumers should read PoolOracle directly.
    uint32 internal constant FAST_WINDOW = PoolOracle.FAST_WINDOW;
    uint32 internal constant SLOW_WINDOW = PoolOracle.SLOW_WINDOW;
    uint32 internal constant FAST_VOL_ALPHA = PoolOracle.FAST_VOL_ALPHA;
    uint32 internal constant SLOW_VOL_ALPHA = PoolOracle.SLOW_VOL_ALPHA;
    uint32 internal constant MAX_VOLATILITY = 100 * uint32(SC.PBPS);
    uint16 internal constant DEFAULT_TTL = PoolOracle.DEFAULT_TTL;

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
    /// @dev Called atomically by PoolFactory.createPool -no front-run window.
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

    function _hook(address tokenNorm, uint32 flag) internal view returns (address h) {
        h = $.hooks[tokenNorm];
        if (h == address(0)) return address(0);
        return ($.hookFlags[tokenNorm] & flag) != 0 ? h : address(0);
    }

    function _wrap(address token) internal view returns (address) {
        return token == SC.NATIVE ? $.wnative : token;
    }

    /// @notice ERC7802 bridge auth -bridgeable tokens query this.
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
        return PoolOracle.computeFastTWAP($, _wrap(token));
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
        PoolEdge.updateFeed($, token, initialPrice, accDecimals, fastVolEMA, slowVolEMA);
    }

    // ────────────────────────────────────────────────────────────────
    // LIQUIDITY DOMAIN
    // ────────────────────────────────────────────────────────────────

    function deposit(
        address token,
        uint256 amount
    ) external payable nonReentrant whenInitialized returns (IPool.DepositResult memory) {
        return PoolLiquidity.deposit($, token, amount);
    }

    function donate(address token, uint256 amount) external payable nonReentrant whenInitialized {
        PoolLiquidity.donate($, token, amount);
    }

    function withdraw(
        address token,
        uint256 lpAmount,
        uint256 minAmountOut
    ) external nonReentrant whenInitialized returns (IPool.WithdrawResult memory) {
        return PoolLiquidity.withdrawTo($, token, token, lpAmount, minAmountOut);
    }

    function withdrawTo(
        address tokenFrom,
        address tokenTo,
        uint256 lpAmount,
        uint256 minAmountOut
    ) public nonReentrant whenInitialized returns (IPool.WithdrawResult memory) {
        return PoolLiquidity.withdrawTo($, tokenFrom, tokenTo, lpAmount, minAmountOut);
    }

    function swapLiability(
        address tokenIn,
        address tokenOut,
        uint256 lpAmountIn,
        uint256 minLpAmountOut
    ) external nonReentrant whenInitialized returns (uint256 lpAmountOut) {
        return PoolLiquidity.swapLiability($, tokenIn, tokenOut, lpAmountIn, minLpAmountOut);
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
        return PoolSwap.swap($, tokenIn, tokenOut, amountIn, minAmountOut, recipient);
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
        return PoolBatch.batchSwap($, inputs, outputs, recipient);
    }

    // ── Views ──
    function owner() external view returns (address) { return _owner(); }
    function baseToken() external view returns (address) { return $.baseToken; }
    function wnative() external view returns (address) { return $.wnative; }
    function treasury() external view returns (address) { return $.treasury; }

    function getAsset(address tk) external view returns (IPool.Asset memory) {
        return $.assets[_wrap(tk)];
    }
    /// @notice Preview single-asset withdraw output for an LP balance against this token's book.
    /// @dev    Same math as withdraw same-token branch; haircut applied iff coverage < 100%.
    ///         View-only -does NOT call PoolDecay.applyDecay; reads current asset state as-is.
    function previewWithdraw(address tk, uint256 lp) external view returns (uint256 amountOut, uint256 haircut) {
        IPool.Asset storage a = $.assets[_wrap(tk)];
        uint256 li = a.liquidityIndex == 0 ? INIT_LIQUIDITY_INDEX : a.liquidityIndex;
        uint256 wv = (lp * li) / SC.WAD;
        (amountOut, haircut) = PoolLiquidity.applyHaircut(wv, a.reserves, a.liabilities, a.haircutSuppressor);
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
    /// @notice Pure view of the last cached oracle price for `tk` (no accumulator mutation).
    /// @dev    Wave-1 split (Cohort-1 finding): `getMidPrice` was non-view ∵ `_readOracle` mutates
    ///         `lastUpdate`/EMAs via primary→fallback dispatch. SDK + indexer consumers need a
    ///         true `view`; keepers that want the side-effect should call `pokeMidPrice`.
    function midPrice(address tk) external view returns (uint256) {
        return $.accumulators[_wrap(tk)].lastPriceB64.b64To1e18();
    }

    /// @notice Coverage ratio = reserves / liabilities (WAD). Returns max-uint when no liabilities.
    /// @dev    Wave-1 (IPoolModule.getCoverageRatio impl). Reverts NotFound if asset unregistered.
    function getCoverageRatio(address tk) external view returns (uint256) {
        IPool.Asset storage a = $.assets[_wrap(tk)];
        if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tk);
        if (a.liabilities == 0) return type(uint256).max;
        return (uint256(a.reserves) * SC.WAD) / uint256(a.liabilities);
    }

    /// @notice Refresh-then-read oracle price. Mutates accumulators (EMAs, last update ts).
    /// @dev    Renamed from `getMidPrice` (Wave-1): non-view nature was previously hidden by
    ///         interface declaring `view`. Keeper-callable: drives oracle freshness off-chain.
    function pokeMidPrice(address tk) external returns (uint256) {
        return PoolEdge.pokeMidPrice($, address(this), tk);
    }

    // ── Internal swap helpers ──

    // ────────────────────────────────────────────────────────────────
    // ADMIN DOMAIN -restricted setters gated by `admin` singleton
    // ────────────────────────────────────────────────────────────────

    function adminFreezeAsset(address token) external onlyAdmin {
        PoolAdminWrite.freezeAsset($, token);
    }

    function adminUnfreezeAsset(address token) external onlyAdmin {
        PoolAdminWrite.unfreezeAsset($, token);
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
        PoolAdminWrite.initAsset(
            $, address(this), token, oracleCfg, riskCfg, profile,
            minFeeBps, decimals, initialPrice, initialFastVolEMA, initialSlowVolEMA,
            minDispersion, maxDispersion, gamma, vega, lambda
        );
    }

    function adminCollectProtocolFees(address token, address recipient)
        external nonReentrant onlyAdmin returns (uint256)
    {
        return PoolEdge.collectProtocolFees($, token, recipient);
    }

    function adminSetFlowCooldown(uint16 cooldownSeconds) external onlyAdmin {
        PoolAdminWrite.setFlowCooldown($, cooldownSeconds);
    }

    function adminSetAnchor(address token, address anchor) external onlyAdmin {
        PoolAdminWrite.setAnchor($, token, anchor);
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
        PoolAdminWrite.setAssetParams($, token, minLiquidity, minFeeBps, maxFeeBps, gamma, vega, lambda, haircutSuppressor, reservationPrice);
    }

    function adminSetRiskConfig(address token, IPool.RiskConfig calldata cfg) external onlyAdmin {
        PoolAdminWrite.setRiskConfig($, token, cfg);
    }

    function adminSetOracleConfig(address token, IPool.OracleConfig calldata cfg) external onlyAdmin {
        PoolAdminWrite.setOracleConfig($, address(this), token, cfg);
    }

    function adminSetFeeParams(IPool.FeeParams calldata params) external onlyAdmin {
        PoolAdminWrite.setFeeParams($, params);
    }

    function adminSetBridge(address newBridge) external onlyAdmin {
        PoolAdminWrite.setBridge($, newBridge);
    }

    function adminSetTreasury(address newTreasury) external onlyAdmin {
        PoolAdminWrite.setTreasury($, newTreasury);
    }

    function adminSetBaseToken(address newBase) external onlyAdmin {
        PoolAdminWrite.setBaseToken($, newBase);
    }

    // ────────────────────────────────────────────────────────────────
    // STAKING -restricted setter gated by `staking` singleton
    // ────────────────────────────────────────────────────────────────

    function stakingAdjustLpBalance(address user, address token, int256 delta) external onlyStaking {
        PoolEdge.stakingAdjustLpBalance($, user, token, delta);
    }

    // ────────────────────────────────────────────────────────────────
    // FLASH -restricted setters gated by `flash` singleton
    // ────────────────────────────────────────────────────────────────

    function flashSend(address token, uint256 amount, address to) external onlyFlash whenInitialized nonReentrant {
        PoolEdge.flashSend($, token, amount, to);
    }

    function flashAccount(address token, uint256 fee, uint256 protoFee) external onlyFlash {
        PoolEdge.flashAccount($, token, fee, protoFee);
    }

    // ── helpers ──


    receive() external payable {}
}
