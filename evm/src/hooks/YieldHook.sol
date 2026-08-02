// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {BasePoolHook} from "./BasePoolHook.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IHasTreasury} from "../interfaces/IHasTreasury.sol";
import {IMerklDistributor} from "../interfaces/external/IMerklDistributor.sol";
import {Constants as C} from "../libraries/Constants.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title YieldHook - shared rehypothecation buffer + incentive sweep to Treasury.
/// @notice Hot path: recall only on liquid shortfall (no venue NAV). Cold: harvest NAV + buffer.
///         Incentive tokens (Merkl / Turtle / venue) are claimed then pushed to `pool.treasury()` —
///         never swapped inside adapters.
/// @dev Subclasses implement `_venueDeposit` / `_venueWithdraw` / `_navAssets` / `_maxWithdrawable`.
abstract contract YieldHook is BasePoolHook {
  using SafeTransferLib for address;

  uint16 public constant DEFAULT_TARGET_INVESTED_BPS = 6500;
  uint16 public constant DEFAULT_HYSTERESIS_BPS = 500;
  /// @notice Default max credit as BPS of book PER DAY (100 = 1%/day). Owner may raise.
  uint16 public constant DEFAULT_MAX_HARVEST_CREDIT_BPS = 100;

  address public immutable AC;
  address public immutable pool;
  address public immutable token;

  uint16 public targetInvestedBps;
  uint16 public hysteresisBps;
  /// @notice Cap on `hookCreditYield` (BPS of book PER DAY; 0 disables credit).
  uint16 public maxHarvestCreditBps;
  /// @notice Last crediting harvest. The cap is a RATE, not a per-call allowance: without it,
  ///         `rebalance()` has no cooldown, so N calls in one block each credited a full
  ///         `book·capBps/BPS` and compounded the index N times off one NAV move.
  ///         Packs with the three uint16s above (48+32 bits, one slot).
  uint32 public lastHarvest;
  /// @notice Optional override; address(0) → `IHasTreasury(pool).treasury()`.
  address public incentivesReceiver;
  /// @notice Merkl distributor used by the base (proof-carrying) claim route. Defaults to the canonical
  ///         multi-chain address; owner-settable so deploys/tests can point at a verified/mock address.
  ///         Ctor-injection would change every adapter's ctor (Aave unaffected per spec) → use a setter.
  address public merklDistributor = C.MERKL_DISTRIBUTOR;

  modifier onlyPool() {
    if (msg.sender != pool) revert Err.NotPool();
    _;
  }

  modifier onlyOwner() {
    if (msg.sender != AccessControl(AC).owner()) revert Err.NotOwner();
    _;
  }

  modifier onlyKeeperOrOwner() {
    AccessControl ac_ = AccessControl(AC);
    if (!ac_.isKeeper(msg.sender) && msg.sender != ac_.owner()) revert Err.NotAuth();
    _;
  }

  constructor(address ac_, address pool_, address token_) {
    if (ac_ == address(0) || pool_ == address(0) || token_ == address(0)) revert Err.ZeroAddr();
    AC = ac_;
    pool = pool_;
    token = token_;
    targetInvestedBps = DEFAULT_TARGET_INVESTED_BPS;
    hysteresisBps = DEFAULT_HYSTERESIS_BPS;
    maxHarvestCreditBps = DEFAULT_MAX_HARVEST_CREDIT_BPS;
    // Seed the rate clock at deploy: a 0 start would read `dt = block.timestamp` and disable the cap.
    lastHarvest = uint32(block.timestamp);
  }

  function recommendedFlags() external pure virtual returns (uint32) {
    return C.HOOK_PRE_OUTFLOW | C.HOOK_POST_INFLOW;
  }

  function setBuffer(uint16 targetInvestedBps_, uint16 hysteresisBps_) external onlyOwner {
    if (targetInvestedBps_ > SC.BPS || hysteresisBps_ > targetInvestedBps_) revert Err.BadConfig();
    targetInvestedBps = targetInvestedBps_;
    hysteresisBps = hysteresisBps_;
  }

  function setMaxHarvestCreditBps(uint16 bps_) external onlyOwner {
    if (bps_ > SC.BPS) revert Err.BadConfig();
    maxHarvestCreditBps = bps_;
  }

  /// @notice MED: gated by `treasuryOwner` (the treasury authority), not `owner` — this override
  ///         redirects the incentive sweep destination away from `pool.treasury()`, a custody-split
  ///         decision that must sit with the same principal as the timelocked treasury-rotation path,
  ///         not the param/admin owner.
  function setIncentivesReceiver(address receiver_) external {
    if (msg.sender != AccessControl(AC).treasuryOwner()) revert Err.NotAuth();
    incentivesReceiver = receiver_;
  }

  function setMerklDistributor(address distributor_) external onlyOwner {
    merklDistributor = distributor_;
  }

  /// @notice Escape hatch: crystallize a stuck-venue loss when `_navAssets()` reverts (bricked/paused/
  ///         rogue-upgraded venue), which wedges `_harvest` and leaves no path to lower `invested` —
  ///         so `setAssetHook`/`clearAssetHook` (both require `invested == 0`) can never replace or clear
  ///         this hook. Writes `invested` down (decrease-only; `hookWriteDown` caps to invested and
  ///         socializes the loss via the liquidity index), freeing migration. Owner = timelocked gov,
  ///         the same principal as `setAssetHook`; keeper is intentionally excluded (loss socialization
  ///         is governance-grade). `msg.sender == assetHooks[token].target == address(this)` satisfies
  ///         the pool-side hook-target gate.
  function forceWriteDown(uint256 amount) external onlyOwner {
    IPool(pool).hookWriteDown(token, amount);
  }

  // ─── IPoolHooks ───

  function preOutflow(address, address, address token_, uint256 amountNeeded)
    external
    virtual
    override
    onlyPool
  {
    _recall(token_, amountNeeded);
  }

  function postInflow(address, address, address token_, uint256, uint256)
    external
    virtual
    override
    onlyPool
  {
    if (token_ != token) return;
    _deploy();
  }

  /// @notice Cold path: mark venue NAV into books, then retarget buffer.
  /// @dev deploy/trim are mutually exclusive (inv can't be both < lowInv and > highInv), so dispatch
  ///      exactly one leg off a single post-harvest read instead of calling both (one always no-ops).
  function rebalance() external virtual onlyKeeperOrOwner {
    _harvest();
    (uint256 reserves, uint256 inv, uint256 minLiq) = IPool(pool).getBuffer(token);
    if (reserves == 0) return;
    uint256 highInv = (reserves * _hiBps()) / SC.BPS;
    if (inv > highInv) _trimToTarget(reserves, inv);
    else _deploy(reserves, inv, minLiq);
  }

  // ─── Incentives → Treasury (no in-hook swaps) ───

  /// @notice Venue claim → rewards land on the hook, then `sweepIncentives` pushes them to Treasury.
  /// @dev Native venues (Aave, Compound) override `_claimVenueIncentives`. The base default is the
  ///      universal Merkl route for proof-carrying campaigns (Morpho, Euler rEUL, generic ERC4626).
  function claimVenueIncentives(bytes calldata data) external onlyKeeperOrOwner {
    _claimVenueIncentives(data);
  }

  /// @notice Push non-underlying, non-position-token balances to Treasury (or `incentivesReceiver`).
  /// @dev Skips `token` and `_positionToken()` (aToken / cToken / ERC4626 shares). Morpho Blue holds
  ///      no share ERC20 → `_positionToken() == address(0)`.
  function sweepIncentives(address[] calldata rewardTokens) external onlyKeeperOrOwner {
    address to = _incentivesTo();
    if (to == address(0)) revert Err.ZeroAddr();
    address pos = _positionToken();
    uint256 n = rewardTokens.length;
    for (uint256 i; i < n; ++i) {
      address t = rewardTokens[i];
      if (t == token || (pos != address(0) && t == pos)) continue;
      uint256 bal = t.balanceOf(address(this));
      if (bal == 0) continue;
      t.safeTransfer(to, bal);
    }
  }

  // ─── Venue hooks (subclass) ───

  function _venueDeposit(uint256 assets) internal virtual;
  function _venueWithdraw(uint256 assets) internal virtual returns (uint256 received);
  function _navAssets() internal view virtual returns (uint256);
  function _maxWithdrawable() internal view virtual returns (uint256);

  /// @notice Base default: Merkl (Angle) proof-carrying claim. Empty data → no-op (also the empty-data
  ///         path native overrides own). Rewards land on the hook (users[i] = this) → swept to Treasury.
  /// @dev data = abi.encode(address[] tokens, uint256[] amounts, bytes32[][] proofs) — keeper builds it
  ///      off-chain from the Merkl API. No custom claimRecipient (default recipient = the hook).
  function _claimVenueIncentives(bytes calldata data) internal virtual {
    if (data.length == 0) return;
    (address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) =
      abi.decode(data, (address[], uint256[], bytes32[][]));
    address dist = merklDistributor;
    if (dist == address(0)) revert Err.ZeroAddr();
    uint256 n = tokens.length;
    address[] memory users = new address[](n);
    for (uint256 i; i < n; ++i) {
      users[i] = address(this);
    }
    IMerklDistributor(dist).claim(users, tokens, amounts, proofs);
  }

  /// @notice Venue position ERC20 held by this hook (aToken, cToken, vault shares). address(0) if none.
  function _positionToken() internal view virtual returns (address) {
    return address(0);
  }

  // ─── Buffer internals ───

  function _incentivesTo() internal view returns (address) {
    address override_ = incentivesReceiver;
    if (override_ != address(0)) return override_;
    return IHasTreasury(pool).treasury();
  }

  /// @dev Capped invested hysteresis ceiling (BPS). Shared by deploy/trim/rebalance.
  function _hiBps() private view returns (uint256 hi) {
    hi = uint256(targetInvestedBps) + hysteresisBps;
    if (hi > SC.BPS) hi = SC.BPS;
  }

  function _recall(address token_, uint256 amountNeeded) internal {
    if (token_ != token) return;
    // Single wrap+read: liq and inv share the same buffer read (was getLiquidReserves + getInvested).
    (uint256 reserves, uint256 inv,) = IPool(pool).getBuffer(token);
    uint256 liq = reserves > inv ? reserves - inv : 0;
    if (liq >= amountNeeded) return;

    uint256 shortfall = amountNeeded - liq;
    if (shortfall > inv) shortfall = inv;
    if (shortfall == 0) return;

    uint256 maxW = _maxWithdrawable();
    if (shortfall > maxW) shortfall = maxW;
    if (shortfall == 0) return;

    uint256 got = _venueWithdraw(shortfall);
    if (got == 0) return;
    token.safeTransfer(pool, got);
  }

  function _deploy() internal {
    (uint256 reserves, uint256 inv, uint256 minLiq) = IPool(pool).getBuffer(token);
    _deploy(reserves, inv, minLiq);
  }

  function _deploy(uint256 reserves, uint256 inv, uint256 minLiq) private {
    if (reserves == 0) return;
    uint256 liq = reserves > inv ? reserves - inv : 0;

    uint256 targetInv = (reserves * targetInvestedBps) / SC.BPS;
    uint256 lowInv = targetInvestedBps > hysteresisBps
      ? (reserves * (targetInvestedBps - hysteresisBps)) / SC.BPS
      : 0;
    if (inv >= lowInv) return;
    uint256 keepLiq = reserves - ((reserves * _hiBps()) / SC.BPS);
    if (keepLiq < minLiq) keepLiq = minLiq;
    if (liq <= keepLiq) return;
    uint256 deployAmt = liq - keepLiq;
    uint256 gap = targetInv > inv ? targetInv - inv : 0;
    if (deployAmt > gap) deployAmt = gap;
    if (deployAmt == 0) return;

    if (msg.sender == pool) {
      token.safeTransferFrom(pool, address(this), deployAmt);
    } else {
      IPool(pool).hookDeploy(token, deployAmt);
    }
    _venueDeposit(deployAmt);
  }

  function _trimToTarget(uint256 reserves, uint256 inv) private {
    if (reserves == 0) return;
    uint256 highInv = (reserves * _hiBps()) / SC.BPS;
    if (inv <= highInv) return;
    uint256 trim = inv - ((reserves * targetInvestedBps) / SC.BPS);
    uint256 maxW = _maxWithdrawable();
    if (trim > maxW) trim = maxW;
    if (trim == 0) return;
    uint256 got = _venueWithdraw(trim);
    if (got == 0) return;
    token.safeTransfer(pool, got);
    IPool(pool).hookRecall(token, got);
  }

  function _harvest() internal {
    uint256 book = IPool(pool).getInvested(token);
    uint256 nav = _navAssets();
    if (nav == 0) {
      if (book > 0) IPool(pool).hookWriteDown(token, book);
      return;
    }
    if (nav == book) return;
    if (nav > book) {
      uint256 credit = nav - book;
      // Sandwich/inflation bound: credit at most maxHarvestCreditBps of book PER DAY. dt == 0 (a
      // second harvest in the same block) credits nothing, so `rebalance()` cannot be spun to
      // compound one NAV move. Unused allowance accrues, so a genuine gain still lands in full
      // after enough elapsed time; the excess stays as unrealised NAV until then.
      uint16 capBps = maxHarvestCreditBps;
      if (capBps == 0) return;
      uint256 dt = block.timestamp - lastHarvest;
      uint256 maxCredit = (book * uint256(capBps) * dt) / (SC.BPS * 1 days);
      if (credit > maxCredit) credit = maxCredit;
      if (credit == 0) return;
      lastHarvest = uint32(block.timestamp);
      IPool(pool).hookCreditYield(token, credit);
    } else {
      IPool(pool).hookWriteDown(token, book - nav);
    }
  }
}
