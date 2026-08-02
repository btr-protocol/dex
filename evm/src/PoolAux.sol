// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "./interfaces/IPool.sol";
import {IAdmin} from "./interfaces/IAdmin.sol";
import {Err} from "@btr-shared/Errors.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {PoolAdminWrite} from "./libraries/PoolAdminWrite.sol";
import {PoolEdge} from "./libraries/PoolEdge.sol";
import {PoolLiquidity} from "./libraries/PoolLiquidity.sol";
import {PoolIO} from "./libraries/PoolIO.sol";
import {PoolHooks} from "./libraries/PoolHooks.sol";
import {PoolDecay} from "./libraries/PoolDecay.sol";
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
    if (ac_.code.length == 0 || admin_.code.length == 0 || flash_.code.length == 0) {
      revert Err.NotCode();
    }
    if (IAdmin(admin_).AC() != ac_) revert Err.BadConfig();
    AC = ac_;
    admin = admin_;
    flash = flash_;
  }

  /// @dev NOT a role gate: asserts the caller IS the singleton `Admin` CONTRACT. Named distinctly
  ///      from the fleet-wide `onlyAdminContract` (= AC.owner()) so the two concepts can never be conflated.
  modifier onlyAdminContract() {
    if (msg.sender != admin) revert Err.NotAuth();
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

  function adminFreezeAsset(address token) external onlyAdminContract {
    PoolAdminWrite.freezeAsset($, token);
  }

  function adminUnfreezeAsset(address token) external onlyAdminContract {
    PoolAdminWrite.unfreezeAsset($, token);
  }

  function adminPauseAsset(address token) external onlyAdminContract {
    PoolAdminWrite.pauseAsset($, token);
  }

  function adminUnpauseAsset(address token) external onlyAdminContract {
    PoolAdminWrite.unpauseAsset($, token);
  }

  function adminInitAsset(
    address token,
    IPool.OracleConfig calldata oracleCfg,
    IPool.RiskConfig calldata riskCfg,
    uint16 presetId,
    uint16 minFeePbps,
    uint8 decimals,
    uint32 minDispersion,
    uint32 maxDispersion,
    uint16 gamma,
    uint16 vega
  ) external onlyAdminContract {
    PoolAdminWrite.initAsset(
      $,
      token,
      oracleCfg,
      riskCfg,
      presetId,
      minFeePbps,
      decimals,
      minDispersion,
      maxDispersion,
      gamma,
      vega
    );
  }

  function adminCollectProtocolFees(address token, address recipient)
    external
    nonReentrant
    onlyAdminContract
    returns (uint256)
  {
    return PoolEdge.collectProtocolFees($, token, recipient);
  }

  function adminSetFlowCooldown(uint16 cooldownSeconds) external onlyAdminContract {
    PoolAdminWrite.setFlowCooldown($, cooldownSeconds);
  }

  function adminSetAnchor(address token, address anchor) external onlyAdminContract {
    PoolAdminWrite.setAnchor($, token, anchor);
  }

  function adminSetAssetParams(
    address token,
    uint128 minLiquidity,
    uint16 minFeePbps,
    uint16 maxFeePbps,
    uint16 gamma,
    uint16 vega,
    uint16 haircutSuppressor,
    uint64 reservationPrice,
    uint64 reservationPriceMax
  ) external onlyAdminContract {
    PoolAdminWrite.setAssetParams(
      $,
      token,
      minLiquidity,
      minFeePbps,
      maxFeePbps,
      gamma,
      vega,
      haircutSuppressor,
      reservationPrice,
      reservationPriceMax
    );
  }

  function adminSetRiskConfig(address token, IPool.RiskConfig calldata cfg)
    external
    onlyAdminContract
  {
    PoolAdminWrite.setRiskConfig($, token, cfg);
  }

  function adminSetOracleConfig(address token, IPool.OracleConfig calldata cfg)
    external
    onlyAdminContract
  {
    PoolAdminWrite.setOracleConfig($, token, cfg);
  }

  function adminSetProfile(
    address token,
    uint16 presetId,
    uint32 minDispersion,
    uint32 maxDispersion
  ) external onlyAdminContract {
    PoolAdminWrite.setProfile($, token, presetId, minDispersion, maxDispersion);
  }

  function adminSetCurve(
    uint16 presetId,
    uint256[] calldata interior,
    int256[] calldata wQ,
    uint16 dispRef,
    uint8 flags
  ) external onlyAdminContract {
    PoolAdminWrite.setCurve($, presetId, interior, wQ, dispRef, flags);
  }

  function adminSetFeeParams(IPool.FeeParams calldata params) external onlyAdminContract {
    PoolAdminWrite.setFeeParams($, params);
  }

  function adminSetTreasury(address newTreasury) external onlyAdminContract {
    PoolAdminWrite.setTreasury($, newTreasury);
  }

  function adminSetBaseToken(address newBase, address[] calldata spokes)
    external
    onlyAdminContract
  {
    PoolAdminWrite.setBaseToken($, newBase, spokes);
  }

  function adminSetAssetHook(address token, address hook, uint32 flags) external onlyAdminContract {
    PoolAdminWrite.setAssetHook($, token, hook, flags);
  }

  function adminClearAssetHook(address token) external onlyAdminContract {
    PoolAdminWrite.clearAssetHook($, token);
  }

  // ── Hook views (cold; kept off Pool hot selector table) ──
  // Only views required by OTHER contracts (Flash, yield hooks). Pure storage dumps for
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

  /// @dev One wrap + one Asset SLOT read for the rehypo hooks (was getAsset + getInvested + wrap×2).
  function getBuffer(address tk)
    external
    view
    returns (uint256 reserves, uint256 invested, uint256 minLiquidity)
  {
    address w = PoolIO.wrap($, tk);
    IPool.Asset storage a = $.assets[w];
    return (a.reserves, $.invested[w], a.minLiquidity);
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

  function flashSend(address token, uint256 amount, address to)
    external
    onlyFlash
    whenInitialized
    nonReentrant
  {
    PoolEdge.flashSend($, token, amount, to);
  }

  function flashAccount(address token, uint256 fee, uint256 protoFee) external onlyFlash {
    PoolEdge.flashAccount($, token, fee, protoFee);
  }

  // ── Hook-authorized ledger (msg.sender must be the registered asset hook) ──
  // `nonReentrant` shares Solady's guard slot with Pool under DELEGATECALL, so writers
  // cannot run during deposit/swap/flash while PoolHooks is booking Δbalance (double-book /
  // phantom R_liq). Hot-path recall/deploy MUST use transfer + Δbalance, not these writers.
  // requireNoFlash on ALL FOUR writers: Pool's reentrancy slot is NOT held during the ERC-3156
  // borrower callback (Flash is a separate singleton making sequential calls), so a mid-flash
  // writer would slip both guards and mutate reserves/invested that flashAccount's Δ math
  // double-counts. Unlike HALT_MASK (recall/writedown stay open for fund exit), the flash window
  // is single-tx — blocking all four costs no liveness.

  function hookDeploy(address token, uint256 amount) external nonReentrant {
    PoolIO.requireNoFlash();
    address t = PoolIO.wrap($, token);
    IPool.HookSlot memory h = $.assetHooks[t];
    if (msg.sender != h.target) revert Err.NotOwner();
    // HALT-KEEP: block NEW deployment into a hook while the asset is frozen/paused. Recall
    // (hookRecall) and loss-booking (hookWriteDown) stay open so funds can always exit.
    if (($.riskConfigs[t].flags & C.HALT_MASK) != 0) {
      revert Err.FeatureDisabled(Err.Resource.ASSET);
    }
    // Cannot create/increase invested without a recall path.
    if ((h.flags & C.HOOK_PRE_OUTFLOW) == 0) revert Err.InvalidState();
    if (amount == 0) revert Err.ZeroValue();
    uint256 liq = PoolHooks.liquidReserves($, t);
    uint256 minLiq = $.assets[t].minLiquidity;
    if (liq < amount || liq - amount < minLiq) revert Err.InsufficientAmount(liq, amount);
    uint256 inv = $.invested[t];
    if (inv + amount > type(uint128).max) {
      revert Err.ExcessiveAmount(inv + amount, type(uint128).max);
    }
    $.invested[t] = uint128(inv + amount);
    PoolIO.push($, token, msg.sender, amount);
  }

  /// @notice Keeper trim only: book recall after tokens already sit on the pool.
  /// @dev Hot-path recall uses preOutflow Δbalance. Balance proof: ERC20 bal ≥
  ///      R_liq + protocolFees + amount (transfer-before-notify; fees are escrowed in the same
  ///      token balance). Mutex blocks callback reentry; stale NAV / harvest SLA is ops.
  function hookRecall(address token, uint256 amount) external nonReentrant {
    PoolIO.requireNoFlash();
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
    PoolIO.requireNoFlash();
    address t = PoolIO.wrap($, token);
    IPool.HookSlot memory h = $.assetHooks[t];
    if (msg.sender != h.target) revert Err.NotOwner();
    if ((h.flags & C.HOOK_PRE_OUTFLOW) == 0) revert Err.InvalidState();
    if (amount == 0) return;
    if (amount > type(uint128).max) revert Err.ExcessiveAmount(amount, type(uint128).max);
    IPool.Asset storage a = $.assets[t];
    if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
    // Settle pending decay FIRST, as deposit and donate do: crediting yield onto a stale
    // index/liabilities pair let the pending decay write down the freshly credited amount.
    PoolDecay.applyDecay(a, $.riskConfigs[t]);
    a.reserves += uint128(amount);
    a.liabilities += uint128(amount);
    uint256 inv = $.invested[t];
    if (inv + amount > type(uint128).max) {
      revert Err.ExcessiveAmount(inv + amount, type(uint128).max);
    }
    $.invested[t] = uint128(inv + amount);
    // Raise liquidity index like donate (liabBefore = liabilities prior to the += above).
    PoolLiquidity.raiseIndex(a, uint256(a.liabilities) - amount, amount);
  }

  /// @notice Write-down when external NAV < book: cut invested + reserves; haircut liabilities/index.
  /// @dev Caps cut to invested/reserves. Liabilities cut by min(loss, L). If L→0, floor index at 1.
  ///      Never reverts on loss ≥ liabilities (would strand fictional R_inv).
  ///      No on-chain NAV breaker: harvest SLA / pause is ops control for stale book.
  function hookWriteDown(address token, uint256 amount) external nonReentrant {
    PoolIO.requireNoFlash();
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
    // Socialize via the liquidity index (decay-style). No floor: a total claim wipe sets the index
    // to 0, which is the terminal state (shares worth 0, leg refuses further deposits). Flooring at
    // 1 left outstanding shares with a live claim against the NEXT depositor's money.
    if (liabBefore > 0) {
      a.liquidityIndex = uint64((uint256(a.liquidityIndex) * (liabBefore - cutLiab)) / liabBefore);
    }
  }
}
