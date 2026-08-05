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
    // slot 1 (8 bits free). liquidityIndex is 96 bits over a WAD base, so the first share is 1:1
    // with the first underlying unit and the receipt can carry the underlying's own decimals.
    // minLiquidity is bounded < 2**96 at setAssetParams.
    uint96 minLiquidity;
    uint96 liquidityIndex;
    uint32 lastUpdate;
    // Pricing-shape pointer into PoolStorage.curves (shared preset table). 0 = none (fallback quote).
    uint16 presetId;
    // Dead-share seed as a power of ten of the token's own unit; 0 = the decimals-derived default.
    // Token units are not value: 0.001 WBTC is ~$64 burned from the first depositor while 0.001
    // KRW1 prices an index pin at ~$54k. This re-denominates the seed per leg without a new slot,
    // and reads 0 (= default) out of every legacy word. Bounded at `decimals + 3` by its setter.
    uint8 deadSeedPow10;
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
    uint64 reservationPriceMax; // absolute MAX swap price (base-per-asset, b64); 0 = no ceiling
    // ^^^ Quote unit = BASE per asset ALWAYS (DEN-02/03). For usdQuoted legs, priceBandGuard
    // converts the USD primary mark into base before comparing to these bounds.
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
    // DEN-01 mark denomination. false (default): the mark is already quoted in BASE units
    // (a genuine <TOKEN>-<BASE> cross, e.g. ETH-USDC / BTC-USDC). true: the attested mark is quoted
    // in the UNIT OF ACCOUNT (<TOKEN>-USD, e.g. USDT-USD, DAI-USD, EURC-USD, the inverted FX legs) —
    // NXR cannot sign a real <TOKEN>-USDC for these (their composed cross has no provider
    // observation), so the pool MUST re-denominate at consumption:
    //   X/base = (USD per X) / (USD per base) = mark / basePrice.
    // Without it the pool prices X-USD as if it were X-base, i.e. it mis-prices every base<->X swap
    // by exactly the base's own depeg |basePrice-1|, unbounded up to BASE_DEPEG_HALT_BPS.
    // Quote-unit contract (DEN-02/03):
    //   - reservationPrice{,Max} = BASE-per-asset (always); usdQuoted legs convert before abs check.
    //   - refFeedId mark shares the primary's catalog unit (USD when usdQuoted, else base cross);
    //     priceBandGuard compares raw vs raw in that common unit.
    // Packs into the primary/refBandBps/mode slot: storage layout of refPrimary is unchanged.
    bool usdQuoted;
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
    /// @notice Shares carved out of `lpAmount` and sunk to address(0) if this opened the leg.
    uint256 deadLp;
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
    UPDATE_CURVE,
    UPDATE_ASSET_PARAMS
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
  ///      assets=3, oracleConfigs=4, riskConfigs=5, curves=6; tail assetHooks=11,
  ///      invested=12, lpTokens=13. `factory` packs into slot 10 at offset 2, behind
  ///      `flowCooldownSeconds`. Pinned by `test/PoolStorageLayout.t.sol`.
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
    // Was `lpBalances`; the per-leg LPToken clone is now the sole share ledger. Kept as a pin
    // holder because deleting it shifts `protocolFees` to 7 and renumbers everything after it,
    // breaking the storage pin and the SDK map for no benefit. Never read, never written.
    uint256 __reserved_lpBalances;
    mapping(address => uint256) protocolFees;
    IPool.FeeParams feeParams;
    uint16 flowCooldownSeconds;
    // Slots 11 and 12 held `lastDepositTime` and the dead `lastLPStakeTime`. The anti-JIT lock is
    // now a frozen AMOUNT held per holder in the leg's LPToken, so no pool-side timestamp survives.
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
    /// @dev Per-leg ERC-20 receipt (EIP-1167 clone), written once at `initAsset`. ⚠ Appended AT TAIL.
    mapping(address leg => address) lpTokens;
    /// @dev A1-M1 / M-1: last `hookCreditYield` timestamp per leg (rate bucket). ⚠ Appended AT TAIL (slot 14).
    ///      Does not renumber slots 0–13. Seeded at `initAsset` and reset on `setAssetHook` so a late
    ///      hook install cannot harvest a multi-day phantom bucket (`hookCreditYield` also clamps dt ≤ 1d).
    mapping(address => uint32) lastHookCreditAt;
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
  function adminSetDeadSeedPow10(address token, uint8 pow10) external;
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
  function adminSetProfile(
    address token,
    uint16 presetId,
    uint32 minDispersion,
    uint32 maxDispersion
  ) external;
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
  function adminSetBaseToken(address newBase, address[] calldata spokes) external;
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
  /// @notice Leg share index (WAD base). 0 = terminal wipe. CDP / integrators; no storage change.
  function liquidityIndex(address token) external view returns (uint256);
  /// @notice Max LP `owner` can redeem now (halt / cooldown / R_liq−minLiq). See PoolView.maxRedeem.
  function maxRedeem(address owner, address token) external view returns (uint256);
  /// @notice When owner's anti-JIT freeze clears; 0 if clear.
  function withdrawUnlockTime(address owner, address token) external view returns (uint32);
  /// @notice Oracle config snapshot for on-chain consumers (CDP basis). No storage layout change.
  function getOracleConfig(address token) external view returns (OracleConfig memory);
  /// @notice previewWithdraw with virtual pending decay applied (no SSTORE).
  function previewWithdrawFresh(address token, uint256 lp)
    external
    view
    returns (uint256 amountOut, uint256 haircut);
  function pendingDecay(address token) external view returns (uint128);
  /// @notice CDP mark tuple: (primary, feedId, mode).
  function markFeed(address token)
    external
    view
    returns (address primary, bytes32 feedId, uint8 mode);
  function assetDecimals(address token) external view returns (uint8);
  function getLPBalance(address user, address token) external view returns (uint256);
  /// @notice The leg's ERC-20 receipt; `address(0)` if the leg is not listed.
  function lpToken(address token) external view returns (address);
  /// @notice Anti-JIT window, capped at `Constants.MAX_FLOW_COOLDOWN`. Read by every leg receipt.
  function flowCooldownSeconds() external view returns (uint16);
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
    /// @dev Path oracle mark and executable mid, both B64 (1e18 convention, `tokenOut` per
    ///      `tokenIn`, chained across legs). `markPriceB64` is the oracle fair value, `midPriceB64`
    ///      the inventory-skewed centre the book actually quotes around; their gap is the skew
    ///      premium, and (exec − mid) is the only genuinely extractable part.
    uint64 markPriceB64;
    uint64 midPriceB64;
    /// @dev Coverage toll withheld from the gross output BEFORE the fee, `tokenOut` units.
    uint256 covToll;
    address[] routeHops;
    uint256[] hopAmounts;
    uint64[] hopPrices;
  }

  /// @dev protoFee + lpFee are the WHOLE fee and are denominated in `tokenOut` (Pricing
  ///      `_settleQuote` charges it out of the output leg): there is no input-leg fee, so an
  ///      indexer must credit 100% of a swap's fee to `tokenOut` and never to both legs.
  ///      `spreadPbps` is PBPS (1e6), and the realised fee is spreadPbps/2 of the pre-fee
  ///      output — half the round-trip spread, not spreadPbps itself.
  ///      `markPriceB64` / `midPriceB64` are B64 (1e18 convention, same as `lastPriceB64`) and are
  ///      `tokenOut` per `tokenIn`, chained over every leg of the path, so they are directly
  ///      comparable to the realised amountOut/amountIn. The book is centred on the MID, not the
  ///      mark, so OEV decomposes exactly: (exec−mid)/mid is extractable value, (mid−mark)/mark is
  ///      inventory skew, and the two sum to the old exec-vs-mark number.
  ///      `covToll` is the coverage toll withheld from the gross output before the fee, in
  ///      `tokenOut` units (the same units as `amountOut`, `protoFee` and `lpFee`).
  event Swapped(
    address indexed sender,
    address indexed recipient,
    address indexed tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOut,
    uint16 spreadPbps,
    uint256 protoFee,
    uint256 lpFee,
    uint64 markPriceB64,
    uint64 midPriceB64,
    uint256 covToll
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
  /// @notice One-time per leg: the unburnable seed carved out of whatever first credited its
  ///         liabilities. Distinct from Deposited because no deposit happened: emitting it as
  ///         Deposited(address(0), ...) made every log replayer book phantom user inflow.
  event DeadSharesSeeded(address indexed token, uint256 value, uint256 lpAmount);
  /// @notice Every liquidityIndex move. Without it there is no historical NAV per share, no derivable
  ///         APR, no TWAP, and a write-down is invisible: the index is the sole share↔value
  ///         converter and nothing else logs it. `reason` is Constants.INDEX_REASON_*; reserves and
  ///         liabilities ride along because they are not readable at a historical block without an
  ///         archive node, and the coverage haircut cannot be reconstructed without them.
  ///         `index` is uint256 so the field survives the liquidityIndex width change.
  event IndexUpdated(
    address indexed token, uint256 index, uint128 reserves, uint128 liabilities, uint8 reason
  );

  // ─── Exchange functions ──────────────────────────────────────────────────
  function owner() external view returns (address);
  function baseToken() external view returns (address);
  function treasury() external view returns (address);
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
  /// @param deadline Unix ts; reverts Expired if block.timestamp > deadline.
  /// @return amountOut Output amount delivered.
  function swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address recipient,
    uint256 deadline
  ) external payable returns (uint256 amountOut);

  /// @notice Batch swap (≤8 in, ≤8 out).
  /// @param inputs ABI-packed `(token, amount)` input legs.
  /// @param outputs ABI-packed `(token, minOut)` output legs.
  /// @param recipient Output recipient.
  /// @param deadline Unix ts; reverts Expired if block.timestamp > deadline.
  /// @return amountsOut Output amounts per leg.
  function batchSwap(
    bytes calldata inputs,
    bytes calldata outputs,
    address recipient,
    uint256 deadline
  ) external payable returns (uint256[] memory amountsOut);

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
  /// @param deadline Unix ts; reverts Expired if block.timestamp > deadline.
  /// @return result `(amountOut, lpBurned)`.
  function withdraw(address token, uint256 lpAmount, uint256 minAmountOut, uint256 deadline)
    external
    returns (WithdrawResult memory result);

  /// @notice Withdraw LP for different asset (swaps via internal quote)
  /// @param deadline Unix ts; reverts Expired if block.timestamp > deadline.
  function withdrawTo(
    address tokenFrom,
    address tokenTo,
    uint256 lpAmount,
    uint256 minAmountOut,
    uint256 deadline
  ) external returns (WithdrawResult memory result);

  /// @notice Swap LP between assets (changes liability exposure)
  /// @param deadline Unix ts; reverts Expired if block.timestamp > deadline.
  function swapLiability(
    address tokenIn,
    address tokenOut,
    uint256 lpAmountIn,
    uint256 minLpAmountOut,
    uint256 deadline
  ) external returns (uint256 lpAmountOut);

  /// @notice Donate reserves w/o LP mint (raises liquidity index)
  function donate(address token, uint256 amount) external payable;

  /// @notice LP preview: returns (amountOut, haircut) for `lp` shares of `token`.
  function previewWithdraw(address token, uint256 lp)
    external
    view
    returns (uint256 amountOut, uint256 haircut);
}
