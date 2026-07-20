// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {NUQuartic} from "../libraries/NUQuartic.sol";

/// @title IPool — Adaptive Inventory Market Maker (canonical surface)
/// @dev Flash is a standalone singleton (IFlash). Routing is off-chain.
interface IPool {
  struct Asset {
    // slot 0
    uint128 reserves;
    uint128 liabilities;
    // slot 1 (16 bits free)
    uint128 minLiquidity;
    uint64 liquidityIndex;
    uint32 lastUpdate;
    // Pricing-shape pointer into PoolStorage.curves (shared preset table). 0 = none (fallback quote).
    uint16 presetId;
    // slot 2 (16 bits free)
    address anchor;
    uint16 minFeePbps;
    uint16 maxFeePbps;
    uint32 maxDispersion;
    uint8 decimals;
    uint16 gamma;
    // slot 3 — `minDispersion` lives here (not slot 1) so the sell leg reads it warm: slot 3 is always
    // warmed by vega/reservationPrice, whereas slot 1 is cold when decay is disabled (no lastUpdate read).
    uint16 vega;
    uint16 haircutSuppressor;
    uint32 minDispersion;
    uint64 reservationPrice; // absolute MIN swap price (base-per-asset, b64); 0 = no floor
    uint64 reservationPriceMax; // absolute MAX swap price (b64); 0 = no ceiling
    // INTERNAL-mode quote peg (B64 base-per-asset); default WAD=1.0 at init. EXTERNAL mode ignores.
    uint64 pegB64;
  }

  struct RiskConfig {
    uint16 decayStartRatioBps;
    uint16 coverageMin;
    uint16 coverageMax;
    uint32 decaySlope;
    uint16 depthAmplifier;
    uint16 flags;
    // κ (bps): convex coverage-wall strength (Pricing._covToll). 0 = off (volatiles, 0 gas). >0
    // requires depthAmplifier==0 (the c<1 depth subsidy fights the wall) — enforced at config.
    uint16 kappaCovBps;
  }

  struct OracleConfig {
    bytes32 feedId; // mark feed id on `primary`
    // Depeg guard: halt swaps if this asset's mark leaves refBandBps of the REFERENCE feed's price
    // (e.g. WBTC vs the BTC feed, XAUT vs a gold feed). refFeedId is the on-chain feed id
    // keccak256(base,quote) on `refPrimary` (same scheme as `feedId`). 0 = disabled (use the
    // absolute reservationPrice band instead).
    bytes32 refFeedId;
    address primary; // external mark source; IOracle.getFeed(feedId) = fresh quote mark
    uint16 refBandBps; // symmetric tolerance in BPS (200 = ±2%); 0 = disabled
    // Internal-oracle stableswap mode. EXTERNAL (0, default): quote off the keeper mark. INTERNAL
    // (1): quote off Asset.pegB64 (fixed peg; default WAD=1.0 at init). primary/feedId/refFeedId/
    // refBandBps STAY populated — the external feed is the depeg breaker (gate), not the price
    // source. Eligibility: fixed-peg assets ONLY (see setOracleConfig validation).
    uint8 mode;
    // Oracle instance serving refFeedId — MUST differ from `primary` whenever refBandBps != 0.
    // Distinct addresses are enforced on-chain; independent signer/admin failure domains remain a
    // deployment invariant (two instances sharing keys can still be walked together). 0 remains a
    // read-time fallback for legacy stored state, but new/updated armed configs reject it.
    // Appended last: own slot, prior packing kept.
    address refPrimary;
  }

  struct FeeParams {
    uint8 protoShare;
    uint16 flashFeePbps;
  }

  struct DepositResult {
    uint256 lpAmount;
    uint256 actualDeposit;
  }

  struct WithdrawResult {
    uint256 amountOut;
    uint256 lpBurned;
  }

  struct RoutePath {
    address[] hops;
  }

  enum OpType {
    NONE,
    MIGRATE_BASE_TOKEN,
    UPDATE_ORACLE,
    ADD_ASSET,
    UPDATE_RISK,
    UPDATE_FEES,
    UPDATE_TREASURY,
    UPDATE_PROFILE,
    UPDATE_HOOK,
    UPDATE_CURVE
  }

  /// @dev Packed hook slot: one SLOAD = target + flags. `address(0)` = disabled.
  struct HookSlot {
    address target;
    uint32 flags;
  }

  /// @dev Phase 42H.B.3d -ERC-7201 indirection dropped. Pool storage is now plain
  ///      state vars at slot 0+. PoolStorage struct moved into Pool.sol as a
  ///      single instance variable for library compat (Pricing/AnchorTree pass-by-ref).
  /// @dev Dead-state from earlier phases removed: govToken/sGovToken/stakingConfig/
  ///      lpStaked/totalLPStaked/modules/pendingOps/pendingData/owner.
  /// @dev Off-chain readers: do NOT add view getters for mappings below — use
  ///      eth_getStorageAt (SDK `@sdk/pool/storage`). Mapping slots pinned:
  ///      assets=3, oracleConfigs=4, riskConfigs=5, curves=6.
  struct PoolStorage {
    // slot 0: baseToken + initialized — the whenInitialized latch rides the one slot every hot
    // entrypoint already reads (was packed with treasury, a slot no swap path touches: −1 cold SLOAD).
    address baseToken;
    bool initialized;
    address wnative;
    address treasury;
    mapping(address => IPool.Asset) assets;
    mapping(address => IPool.OracleConfig) oracleConfigs;
    mapping(address => IPool.RiskConfig) riskConfigs;
    // Shared pricing-shape preset table (quartic I-spline curves); assets point in via presetId.
    mapping(uint16 => NUQuartic.Curve) curves;
    mapping(address => mapping(address => uint256)) lpBalances;
    mapping(address => uint256) protocolFees;
    IPool.FeeParams feeParams;
    uint16 flowCooldownSeconds;
    // Flow-guard cooldown timestamps (was: FlowGuardStorage @ FLOW_GUARD_STORAGE_LOC).
    mapping(address user => mapping(address asset => uint32)) lastDepositTime;
    mapping(address user => mapping(address lpToken => uint32)) lastLPStakeTime;
    // REG-02: the PoolFactory that created this clone (captured from `msg.sender` in `initialize`,
    //   which the factory calls via createPool). Lets the pool keep the factory's discovery index in
    //   sync when NEW assets are listed (registerTokens) or the base migrates (setPoolBaseToken), so
    //   SafetyOps enumeration finds them. 0 for a non-factory-initialized clone (sync skipped).
    //   ⚠ Appended AT TAIL to preserve mapping slot indices + storage-layout pins. Do not move.
    address factory;
    // Hooks (append-only): per-asset HookSlot + R_inv book cache. Asset.reserves = R_liq + R_inv.
    //   ⚠ Appended AT TAIL. Do not reorder prior fields.
    mapping(address => HookSlot) assetHooks;
    mapping(address => uint128) invested;
  }

  event PoolInitialized(address indexed owner, address indexed baseToken, address indexed wnative);

  function initialize(address baseToken, address wnative, FeeParams calldata feeParams) external;

  // ── Phase 42H.B.3a: restricted setters gated by `admin` singleton ──
  function adminFreezeAsset(address token) external;
  function adminUnfreezeAsset(address token) external;
  function adminPauseAsset(address token) external;
  function adminUnpauseAsset(address token) external;
  function adminInitAsset(
    address token,
    OracleConfig calldata oracleCfg,
    RiskConfig calldata riskCfg,
    uint16 presetId,
    uint16 minFeePbps,
    uint8 decimals,
    uint32 minDispersion,
    uint32 maxDispersion,
    uint16 gamma,
    uint16 vega
  ) external;
  function adminCollectProtocolFees(address token, address recipient) external returns (uint256);
  function adminSetFlowCooldown(uint16 cooldownSeconds) external;
  function adminSetAnchor(address token, address anchor) external;
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
  ) external;
  function adminSetRiskConfig(address token, RiskConfig calldata cfg) external;
  function adminSetOracleConfig(address token, OracleConfig calldata cfg) external;
  /// @notice Recalibrate an asset's pricing-shape pointer + dispersion band (pricing-shape only).
  function adminSetProfile(address token, uint16 presetId, uint32 minDispersion, uint32 maxDispersion)
    external;
  /// @notice Install/recalibrate a shared preset curve (quartic I-spline). Timelocked via Admin.
  function adminSetCurve(
    uint16 presetId,
    uint256[] calldata interior,
    int256[] calldata wQ,
    uint16 dispRef,
    uint8 flags
  ) external;
  function adminSetFeeParams(FeeParams calldata params) external;
  function adminSetTreasury(address newTreasury) external;
  function adminSetBaseToken(address newBase) external;
  /// @notice Timelocked hook install/replace (Admin.executeSetAssetHook).
  function adminSetAssetHook(address token, address hook, uint32 flags) external;
  /// @notice Immediate hook clear (Admin.clearAssetHook). Requires invested == 0.
  function adminClearAssetHook(address token) external;

  // ── Phase 42H.B.3c: restricted setters gated by `flash` singleton ──
  /// @notice Pre-flash recall: ensures R_liq ≥ amount + minLiquidity (via preOutflow).
  function flashPrepare(address token, uint256 amount, address initiator) external;
  function flashSend(address token, uint256 amount, address to) external;
  function flashAccount(address token, uint256 fee, uint256 protoFee) external;

  // ── Hook-authorized ledger (yield-hook keeper paths; not user entrypoints) ──
  // Mutex: nonReentrant under Pool DELEGATECALL — blocked during PoolHooks Δbalance booking.
  function hookDeploy(address token, uint256 amount) external;
  /// @notice Keeper trim only (transfer tokens to pool first). Hot-path recall = preOutflow Δbalance.
  function hookRecall(address token, uint256 amount) external;
  function hookCreditYield(address token, uint256 amount) external;
  /// @notice Write-down when venue NAV < book: cut invested + reserves; haircut L/index (L→0 floors idx).
  ///         Stale NAV: harvest SLA / pause is ops (no on-chain breaker).
  function hookWriteDown(address token, uint256 amount) external;

  // ── views for on-chain consumers (Flash / hooks / ALM) ──
  // Off-chain MUST read profile/risk/oracle via eth_getStorageAt (SDK @sdk/pool/storage).
  // Do NOT add storage-mirror getters — see dex/evm/README.md § "Off-chain reads".
  // TODO(Wave-ABI-break): rename view getters getX → x for style harmonization with ALM.
  /// @notice Read packed `Asset` record (reserves, liabilities, fees, params) for `token`.
  /// @param token Asset address.
  /// @return Asset struct snapshot.
  function getAsset(address token) external view returns (Asset memory);
  function getLPBalance(address user, address token) external view returns (uint256);
  function getRiskFlags(address token) external view returns (uint16);
  function getFeeParams() external view returns (FeeParams memory);
  function getAssetHook(address token) external view returns (HookSlot memory);
  function getInvested(address token) external view returns (uint128);
  /// @notice Executable liquid reserves R_liq = reserves − invested (pricing uses full economic R).
  function getLiquidReserves(address token) external view returns (uint256);
  /// @notice Lean rehypo triple in one CALL/wrap: (reserves, invested, minLiquidity).
  function getBuffer(address token)
    external
    view
    returns (uint256 reserves, uint256 invested, uint256 minLiquidity);

  // ─── Exchange types & events (canonical -was IPoolModule) ────────────────
  struct SwapQuote {
    uint256 amountOut;
    uint256 amountIn;
    uint16 spreadPbps;
    uint256 protoFee;
    uint256 lpFee;
    int8 skewIn;
    int8 skewOut;
    address[] routeHops;
    uint256[] hopAmounts;
    uint64[] hopPrices;
  }

  event Swapped(
    address indexed sender,
    address indexed recipient,
    address indexed tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOut,
    uint16 spreadPbps,
    uint256 protoFee,
    uint256 lpFee
  );

  event BatchSwapped(
    address indexed sender,
    address indexed recipient,
    uint256 inputCount,
    uint256 outputCount,
    uint256 totalBaseValue
  );

  // ─── Liquidity events (canonical) ────────────────────────────────────────
  event Deposited(address indexed sender, address indexed token, uint256 amount, uint256 lpAmount);
  event Withdrawn(address indexed sender, address indexed token, uint256 amount, uint256 lpAmount);
  event LiabilitySwapped(
    address indexed sender,
    address indexed tokenIn,
    address indexed tokenOut,
    uint256 lpAmountIn,
    uint256 lpAmountOut,
    uint256 haircut
  );
  event Donated(address indexed sender, address indexed token, uint256 amount);

  // ─── Exchange functions ──────────────────────────────────────────────────
  function owner() external view returns (address);
  function baseToken() external view returns (address);
  function wnative() external view returns (address);
  /// @notice Baked-in immutable wiring (from the impl bytecode) — used by PoolFactory to assert a
  ///         candidate upgrade impl matches the live fleet's AC/admin/flash and has a codeful poolAux.
  function AC() external view returns (address);
  function admin() external view returns (address);
  function flash() external view returns (address);
  function poolAux() external view returns (address);
  function getCoverageRatio(address token) external view returns (uint256);

  /// @notice Swap `amountIn` of `tokenIn` for ≥`minAmountOut` of `tokenOut`, sending output to `recipient`.
  /// @param tokenIn Input asset.
  /// @param tokenOut Output asset.
  /// @param amountIn Input amount (token decimals).
  /// @param minAmountOut Slippage floor; reverts if not met.
  /// @param recipient Output recipient.
  /// @return amountOut Output amount delivered.
  function swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address recipient
  ) external payable returns (uint256 amountOut);

  /// @notice Batch swap (≤8 in, ≤8 out).
  /// @param inputs ABI-packed `(token, amount)` input legs.
  /// @param outputs ABI-packed `(token, minOut)` output legs.
  /// @param recipient Output recipient.
  /// @return amountsOut Output amounts per leg.
  function batchSwap(bytes calldata inputs, bytes calldata outputs, address recipient)
    external
    payable
    returns (uint256[] memory amountsOut);

  /// @notice Quote a swap without executing (view).
  /// @param tokenIn Input asset.
  /// @param tokenOut Output asset.
  /// @param amountIn Input amount.
  /// @return quote Quote struct (amountOut, fees, spread, route, hop prices).
  function getSwapQuote(address tokenIn, address tokenOut, uint256 amountIn)
    external
    view
    returns (SwapQuote memory quote);

  function getProtocolFees(address token) external view returns (uint256);

  // ─── Liquidity functions ─────────────────────────────────────────────────
  /// @notice Deposit `amount` of `token`, mint LP shares to caller.
  /// @param token Asset to deposit (use wnative for native; send msg.value).
  /// @param amount Deposit amount in token decimals.
  /// @return result `(lpAmount, actualDeposit)` — LP minted + amount actually pulled.
  function deposit(address token, uint256 amount)
    external
    payable
    returns (DepositResult memory result);

  /// @notice Burn `lpAmount` LP of `token`, return underlying ≥ `minAmountOut`.
  /// @param token Asset to withdraw.
  /// @param lpAmount LP shares to burn.
  /// @param minAmountOut Slippage floor; reverts if not met.
  /// @return result `(amountOut, lpBurned)`.
  function withdraw(address token, uint256 lpAmount, uint256 minAmountOut)
    external
    returns (WithdrawResult memory result);

  /// @notice Withdraw LP for different asset (swaps via internal quote)
  function withdrawTo(address tokenFrom, address tokenTo, uint256 lpAmount, uint256 minAmountOut)
    external
    returns (WithdrawResult memory result);

  /// @notice Swap LP between assets (changes liability exposure)
  function swapLiability(
    address tokenIn,
    address tokenOut,
    uint256 lpAmountIn,
    uint256 minLpAmountOut
  ) external returns (uint256 lpAmountOut);

  /// @notice Donate reserves w/o LP mint (raises liquidity index)
  function donate(address token, uint256 amount) external payable;

  /// @notice LP preview: returns (amountOut, haircut) for `lp` shares of `token`.
  function previewWithdraw(address token, uint256 lp)
    external
    view
    returns (uint256 amountOut, uint256 haircut);
}
