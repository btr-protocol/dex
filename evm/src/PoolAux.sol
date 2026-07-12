// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "./interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {PoolAdminWrite} from "./libraries/PoolAdminWrite.sol";
import {PoolEdge} from "./libraries/PoolEdge.sol";
import {PoolIO} from "./libraries/PoolIO.sol";
import {PoolHooks} from "./libraries/PoolHooks.sol";
import {Constants as C} from "./libraries/Constants.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title PoolAux -cold-path dispatcher for Pool (Wave-3a EIP-170 reduction)
/// @notice Singleton deployed once per protocol; Pool's fallback DELEGATECALLs to this.
///         Holds all rarely-called external entry points (admin setters,
///         flash send/account, oracle updateFeed/poke) so Pool itself need not allocate
///         selector dispatch entries for them.
/// @dev    Auth + reentrancy checks live HERE (executed under Pool's storage context via
///         delegatecall). Immutables (AC/admin/flash) are inlined into bytecode,
///         so they remain correct under delegatecall (immutables read from code, not
///         storage). The Pool clone's $ at slot 0 is shared transparently.
contract PoolAux is ReentrancyGuardTransient {
    /// @dev Layout MUST mirror Pool: $ at slot 0 so delegatecalls hit the right slots.
    IPool.PoolStorage internal $;

    address public immutable AC;
    address public immutable admin;
    address public immutable flash;

    constructor(address ac_, address admin_, address flash_) {
        if (ac_ == address(0) || admin_ == address(0) || flash_ == address(0)) {
            revert Err.ZeroAddr();
        }
        AC = ac_;
        admin = admin_;
        flash = flash_;
    }

    function _owner() internal view returns (address) {
        return AccessControl(AC).owner();
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Err.NotOwner();
        _;
    }

    modifier onlyFlash() {
        if (msg.sender != flash) revert Err.NotOwner();
        _;
    }

    modifier whenInitialized() {
        if (!$.initialized) revert Err.InvalidState();
        _;
    }

    // ── ADMIN setters ──

    function adminFreezeAsset(address token) external onlyAdmin {
        PoolAdminWrite.freezeAsset($, token);
    }

    function adminUnfreezeAsset(address token) external onlyAdmin {
        PoolAdminWrite.unfreezeAsset($, token);
    }

    function adminPauseAsset(address token) external onlyAdmin {
        PoolAdminWrite.pauseAsset($, token);
    }

    function adminUnpauseAsset(address token) external onlyAdmin {
        PoolAdminWrite.unpauseAsset($, token);
    }

    function adminInitAsset(
        address token,
        IPool.OracleConfig calldata oracleCfg,
        IPool.RiskConfig calldata riskCfg,
        IPool.LiquidityProfile calldata profile,
        uint16 minFeeBps,
        uint8 decimals,
        uint32 minDispersion,
        uint32 maxDispersion,
        uint16 gamma,
        uint16 vega
    ) external onlyAdmin {
        PoolAdminWrite.initAsset(
            $, address(this), token, oracleCfg, riskCfg, profile,
            minFeeBps, decimals, minDispersion, maxDispersion, gamma, vega
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
        uint16 haircutSuppressor,
        uint64 reservationPrice,
        uint64 reservationPriceMax
    ) external onlyAdmin {
        PoolAdminWrite.setAssetParams($, token, minLiquidity, minFeeBps, maxFeeBps, gamma, vega, haircutSuppressor, reservationPrice, reservationPriceMax);
    }

    function adminSetRiskConfig(address token, IPool.RiskConfig calldata cfg) external onlyAdmin {
        PoolAdminWrite.setRiskConfig($, token, cfg);
    }

    function adminSetOracleConfig(address token, IPool.OracleConfig calldata cfg) external onlyAdmin {
        PoolAdminWrite.setOracleConfig($, address(this), token, cfg);
    }

    function adminSetProfile(
        address token,
        IPool.LiquidityProfile calldata profile,
        uint32 minDispersion,
        uint32 maxDispersion
    ) external onlyAdmin {
        PoolAdminWrite.setProfile($, token, profile, minDispersion, maxDispersion);
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

    /// @notice R44-2 (T3-HIGH2): set/unset base-token oracle for depeg detection.
    function adminSetBaseTokenOracle(address oracle, bytes32 feedId) external onlyAdmin {
        PoolAdminWrite.setBaseTokenOracle($, oracle, feedId);
    }

    function adminSetAssetHook(address token, address hook, uint32 flags) external onlyAdmin {
        PoolAdminWrite.setAssetHook($, token, hook, flags);
    }

    function adminClearAssetHook(address token) external onlyAdmin {
        PoolAdminWrite.clearAssetHook($, token);
    }

    // ── Hook views (cold; kept off Pool hot selector table) ──
    // Only views required by OTHER contracts (Flash, VenusHook). Pure storage dumps for
    // off-chain indexers (profile / risk / oracle) live in SDK slot readers — see
    // dex/evm/README.md § "Off-chain reads (no storage getters)".

    function getAssetHook(address tk) external view returns (IPool.HookSlot memory) {
        return $.assetHooks[PoolIO.wrap($, tk)];
    }

    function getInvested(address tk) external view returns (uint128) {
        return $.invested[PoolIO.wrap($, tk)];
    }

    function getLiquidReserves(address tk) external view returns (uint256) {
        return PoolHooks.liquidReserves($, PoolIO.wrap($, tk));
    }

    // ── FLASH ──

    /// @notice Recall enough for `amount` loan while leaving minLiquidity liquid.
    function flashPrepare(address token, uint256 amount, address initiator)
        external
        nonReentrant
        onlyFlash
        whenInitialized
    {
        address t = PoolIO.wrap($, token);
        uint256 need = amount + uint256($.assets[t].minLiquidity);
        PoolHooks.preOutflow($, t, initiator, need);
    }

    function flashSend(address token, uint256 amount, address to) external onlyFlash whenInitialized nonReentrant {
        PoolEdge.flashSend($, token, amount, to);
    }

    function flashAccount(address token, uint256 fee, uint256 protoFee) external onlyFlash {
        PoolEdge.flashAccount($, token, fee, protoFee);
    }

    // ── Hook-authorized ledger (msg.sender must be the registered asset hook) ──
    // `nonReentrant` shares Solady's guard slot with Pool under DELEGATECALL, so writers
    // cannot run during deposit/swap/flash while PoolHooks is booking Δbalance (double-book /
    // phantom R_liq). Hot-path recall/deploy MUST use transfer + Δbalance, not these writers.

    function hookPull(address token, uint256 amount) external nonReentrant {
        address t = PoolIO.wrap($, token);
        IPool.HookSlot memory h = $.assetHooks[t];
        if (msg.sender != h.target) revert Err.NotOwner();
        // HALT-KEEP: block NEW deployment into a hook while the asset is frozen/paused. Recall
        // (hookNotifyRecall) and loss-booking (hookWriteDown) stay open so funds can always exit.
        if (($.riskConfigs[t].flags & C.HALT_MASK) != 0) revert Err.FeatureDisabled(Err.Resource.ASSET);
        // Cannot create/increase invested without a recall path.
        if ((h.flags & C.HOOK_PRE_OUTFLOW) == 0) revert Err.InvalidState();
        if (amount == 0) revert Err.ZeroValue();
        uint256 liq = PoolHooks.liquidReserves($, t);
        uint256 minLiq = $.assets[t].minLiquidity;
        if (liq < amount || liq - amount < minLiq) revert Err.InsufficientAmount(liq, amount);
        uint256 inv = $.invested[t];
        if (inv + amount > type(uint128).max) revert Err.ExcessiveAmount(inv + amount, type(uint128).max);
        $.invested[t] = uint128(inv + amount);
        PoolIO.push($, token, msg.sender, amount);
    }

    /// @notice Keeper trim only: book recall after tokens already sit on the pool.
    /// @dev Hot-path recall uses preOutflow Δbalance. Balance proof: ERC20 bal ≥
    ///      R_liq + protocolFees + amount (transfer-before-notify; fees are escrowed in the same
    ///      token balance). Mutex blocks callback reentry; stale NAV / harvest SLA is ops.
    function hookNotifyRecall(address token, uint256 amount) external nonReentrant {
        address t = PoolIO.wrap($, token);
        if (msg.sender != $.assetHooks[t].target) revert Err.NotOwner();
        if (amount == 0) return;
        uint256 inv = $.invested[t];
        if (amount > inv) revert Err.InsufficientAmount(inv, amount);
        uint256 liq = PoolHooks.liquidReserves($, t);
        uint256 need = liq + $.protocolFees[t] + amount;
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        if (bal < need) revert Err.InsufficientAmount(bal, need);
        unchecked {
            $.invested[t] = uint128(inv - amount);
        }
    }

    /// @notice Credit yield (donate-equivalent): reserves + liabilities + invested.
    function hookCreditYield(address token, uint256 amount) external nonReentrant {
        address t = PoolIO.wrap($, token);
        IPool.HookSlot memory h = $.assetHooks[t];
        if (msg.sender != h.target) revert Err.NotOwner();
        if ((h.flags & C.HOOK_PRE_OUTFLOW) == 0) revert Err.InvalidState();
        if (amount == 0) return;
        if (amount > type(uint128).max) revert Err.ExcessiveAmount(amount, type(uint128).max);
        IPool.Asset storage a = $.assets[t];
        if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
        a.reserves += uint128(amount);
        a.liabilities += uint128(amount);
        uint256 inv = $.invested[t];
        if (inv + amount > type(uint128).max) revert Err.ExcessiveAmount(inv + amount, type(uint128).max);
        $.invested[t] = uint128(inv + amount);
        // Raise liquidity index like donate.
        uint256 liabBefore = uint256(a.liabilities) - amount;
        uint256 idx = a.liquidityIndex == 0 ? C.LIQUIDITY_INDEX_INIT : a.liquidityIndex;
        uint256 newIndex = liabBefore == 0 ? idx : (idx * (liabBefore + amount)) / liabBefore;
        if (newIndex > type(uint64).max) revert Err.ExcessiveAmount(newIndex, type(uint64).max);
        a.liquidityIndex = uint64(newIndex);
    }

    /// @notice Write-down when external NAV < book: cut invested + reserves; haircut liabilities/index.
    /// @dev Caps cut to invested/reserves. Liabilities cut by min(loss, L). If L→0, floor index at 1.
    ///      Never reverts on loss ≥ liabilities (would strand fictional R_inv).
    ///      No on-chain NAV breaker: harvest SLA / pause is ops control for stale book.
    function hookWriteDown(address token, uint256 amount) external nonReentrant {
        address t = PoolIO.wrap($, token);
        if (msg.sender != $.assetHooks[t].target) revert Err.NotOwner();
        if (amount == 0) return;
        IPool.Asset storage a = $.assets[t];
        if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
        uint256 inv = $.invested[t];
        uint256 cut = amount;
        if (cut > inv) cut = inv;
        if (cut > a.reserves) cut = a.reserves;
        if (cut == 0) return;

        uint256 liabBefore = a.liabilities;
        uint256 cutLiab = cut > liabBefore ? liabBefore : cut;
        unchecked {
            a.reserves -= uint128(cut);
            a.liabilities -= uint128(cutLiab);
            $.invested[t] = uint128(inv - cut);
        }
        // Socialize via liquidity index (decay-style). Total claim wipe → floor at 1.
        if (liabBefore > 0) {
            uint256 liabAfter = liabBefore - cutLiab;
            if (liabAfter == 0) {
                a.liquidityIndex = 1;
            } else {
                uint256 idx = a.liquidityIndex == 0 ? C.LIQUIDITY_INDEX_INIT : a.liquidityIndex;
                uint256 scaled = (idx * liabAfter) / liabBefore;
                a.liquidityIndex = uint64(scaled == 0 ? 1 : scaled);
            }
        }
    }
}
