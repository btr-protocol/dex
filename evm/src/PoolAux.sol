// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "./interfaces/IPool.sol";
import {IAdmin} from "./interfaces/IAdmin.sol";
import {Err} from "@btr-shared/Errors.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {PoolAdminWrite} from "./libraries/PoolAdminWrite.sol";
import {PoolEdge} from "./libraries/PoolEdge.sol";
import {PoolLiquidity} from "./libraries/PoolLiquidity.sol";
import {PoolIO} from "./libraries/PoolIO.sol";
import {PoolHooks} from "./libraries/PoolHooks.sol";
import {PoolDecay} from "./libraries/PoolDecay.sol";
import {Constants as C} from "./libraries/Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
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

  /// @notice One-shot #73 upgrade step: restore each leg's `liquidityIndex` after the Asset repack.
  /// @dev MUST run in the SAME transaction as the beacon upgrade, before any other call touches the
  ///      pool. `minLiquidity` shrank 128→96 so `liquidityIndex` could grow 64→96, which moves the
  ///      index field's low bit from 128 to 96: a word written by the old impl therefore reads back
  ///      as `oldIndex << 32`, and every share would claim 2**32x its backing until this runs.
  ///      `minLiquidity`, `lastUpdate` and `presetId` are untouched by the repack and need no fixup.
  ///      Shift ONLY: a legacy leg keeps the 1e12 base. `LIQUIDITY_INDEX_INIT = 1e18` applies to
  ///      newly listed legs, and rescaling a live leg's index without rescaling its shares would
  ///      multiply every claim by 1e6.
  ///      Idempotency: only a leg still carrying the shifted value is rewritten, and a leg outside
  ///      that band reverts rather than being silently halved.
  ///      Gated on the fleet OWNER, not on the `Admin` singleton, because PoolFactory asserts the
  ///      candidate impl's `admin` immutable equals the live one: adding a forwarder to Admin would
  ///      need a new Admin address and `requestReferenceUpgrade` would reject the upgrade.
  // ponytail: keyed on the uint64 ceiling, which is exact for the deployed fleet (every live index
  // sits within a few percent of 1e12) but is a band, not a proof. Delete this with the migration.
  function adminRebaseIndexWidth(address[] calldata tokens) external {
    if (msg.sender != AccessControl(AC).owner()) revert Err.NotOwner();
    for (uint256 i; i < tokens.length; ++i) {
      IPool.Asset storage a = $.assets[PoolIO.wrap($, tokens[i])];
      if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tokens[i]);
      uint96 idx = a.liquidityIndex;
      if (idx == 0) {
        // NOT a wipe: every leg listed before `initAsset` began writing the base explicitly stores
        // 0, and the PREVIOUS impl read that 0 as LEGACY_LIQUIDITY_INDEX. 30 of the 33 live Sepolia
        // legs are in this state and are healthy. This impl reads 0 as terminal, so skipping here
        // would zero their LPs with no writer able to restore it (every index writer multiplies an
        // existing value). Write the legacy base back.
        // The two writers that can reach 0 (PoolDecay, hookWriteDown) both scale the index by
        // `newLiabilities/oldLiabilities`, so index 0 implies liabilities 0; and after a wipe every
        // credit path fails closed on `mintIndex`, so liabilities can never return. `liabilities
        // != 0` is therefore an exact discriminator, and needs no share supply (there is none).
        // A genuinely wiped or never-credited leg stays terminal and must be re-listed.
        if (a.liabilities == 0) continue;
        a.liquidityIndex = uint96(C.LEGACY_LIQUIDITY_INDEX);
        emit IPool.IndexUpdated(
          tokens[i], C.LEGACY_LIQUIDITY_INDEX, a.reserves, a.liabilities, C.INDEX_REASON_WRITEDOWN
        );
        continue;
      }
      if (idx <= type(uint64).max) revert Err.InvalidState(); // already migrated
      a.liquidityIndex = idx >> 32;
      emit IPool.IndexUpdated(
        tokens[i], idx >> 32, a.reserves, a.liabilities, C.INDEX_REASON_WRITEDOWN
      );
    }
  }

  /// @notice Per-leg dead-share seed, as a power of ten of the token's own unit. 0 = the
  ///         decimals-derived default (`10**decimals / DEAD_SHARE_SEED_DIV`).
  /// @dev The seed's job is to price an index pin at `seed * headroom`, which is a VALUE, but the
  ///      default is denominated in token units: 0.001 WBTC burns ~$64 of the first depositor while
  ///      0.001 KRW1 prices the pin at ~$54k. Set this per leg so the seed lands near $0.001 of
  ///      value. Bounded at `decimals + 3` (1000 whole tokens) so it can never become a listing toll.
  ///      Owner-gated for the same reason as `adminRebaseIndexWidth`: the `Admin` singleton is
  ///      pinned by PoolFactory's immutable check and cannot grow a forwarder.
  ///      Takes effect only while the leg is UNSEEDED; once seeded the floor is already written.
  function adminSetDeadSeedPow10(address token, uint8 pow10) external {
    if (msg.sender != AccessControl(AC).owner()) revert Err.NotOwner();
    IPool.Asset storage a = $.assets[PoolIO.wrap($, token)];
    if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, token);
    if (pow10 > a.decimals + C.DEAD_SEED_POW10_HEADROOM) {
      revert Err.ExcessiveAmount(pow10, a.decimals + C.DEAD_SEED_POW10_HEADROOM);
    }
    a.deadSeedPow10 = pow10;
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
    PoolDecay.applyDecay(a, $.riskConfigs[t], t);
    a.reserves += uint128(amount);
    a.liabilities += uint128(amount);
    uint256 inv = $.invested[t];
    if (inv + amount > type(uint128).max) {
      revert Err.ExcessiveAmount(inv + amount, type(uint128).max);
    }
    $.invested[t] = uint128(inv + amount);
    // Raise liquidity index like donate (liabBefore = liabilities prior to the += above), and split
    // the dead seed out of the credit for the same reason: this is a liability-credit site.
    // A credit too small to carry the seed SKIPS both, like `accrueLpFee`: this runs under the
    // keeper's `rebalance()` -> `_harvest`, and the first post-upgrade harvest on a migrated leg is
    // routinely sub-seed (a 100-token book at 100bps over 1s credits ~1.16e13 against a 1e15 seed).
    // Reverting there bricks the keeper transaction for a leg that is otherwise healthy. The credit
    // still lands in reserves + liabilities; only the index raise waits for a credit that can open
    // the leg, which is self-healing on the next harvest.
    uint256 liabBefore = uint256(a.liabilities) - amount;
    uint256 idx = PoolLiquidity.mintIndex(a);
    (uint256 deadLp, bool seeded) = PoolLiquidity.seedDeadShares($, a, t, idx, amount, false);
    if (!seeded) return;
    uint256 seedVal = (deadLp * idx) / SC.WAD;
    PoolLiquidity.raiseIndex(
      a, t, liabBefore == 0 ? 0 : liabBefore + seedVal, amount - seedVal, C.INDEX_REASON_YIELD
    );
  }

  /// @notice Write-down when external NAV < book: cut invested + reserves; haircut liabilities/index.
  /// @dev Caps cut to invested/reserves. Liabilities cut by min(loss, L). If L→0 the index goes to 0
  ///      and the leg is TERMINAL: shares are worth 0, deposits and accruals revert, it is never
  ///      re-listable. Never reverts on loss ≥ liabilities (would strand fictional R_inv).
  ///      No on-chain NAV breaker: harvest SLA / pause is ops control for stale book.
  function hookWriteDown(address token, uint256 amount) external nonReentrant {
    PoolIO.requireNoFlash();
    address t = PoolIO.wrap($, token);
    if (msg.sender != $.assetHooks[t].target) revert Err.NotOwner();
    if (amount == 0) return;
    IPool.Asset storage a = $.assets[t];
    if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
    // Settle pending decay FIRST, as hookCreditYield/deposit/donate do: scaling the index against a
    // stale `liabilities` and then leaving `lastUpdate` untouched let the full pending dt decay the
    // already-written-down book a second time.
    PoolDecay.applyDecay(a, $.riskConfigs[t], t);
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
      uint256 newIdx = (uint256(a.liquidityIndex) * (liabBefore - cutLiab)) / liabBefore;
      a.liquidityIndex = uint96(newIdx);
      emit IPool.IndexUpdated(t, newIdx, a.reserves, a.liabilities, C.INDEX_REASON_WRITEDOWN);
    }
  }
}
