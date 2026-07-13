// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {BasePoolHook} from "./BasePoolHook.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IHasTreasury} from "../interfaces/IHasTreasury.sol";
import {Constants as C} from "../libraries/Constants.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title YieldHook — shared rehypothecation buffer + incentive sweep to Treasury.
/// @notice Hot path: recall only on liquid shortfall (no venue NAV). Cold: harvest NAV + buffer.
///         Incentive tokens (Merkl / Turtle / venue) are claimed then pushed to `pool.treasury()` —
///         never swapped inside adapters.
/// @dev Subclasses implement `_venueDeposit` / `_venueWithdraw` / `_navAssets` / `_maxWithdrawable`.
abstract contract YieldHook is BasePoolHook {
    using SafeTransferLib for address;

    uint16 public constant DEFAULT_TARGET_INVESTED_BPS = 6500;
    uint16 public constant DEFAULT_HYSTERESIS_BPS = 500;
    /// @notice Default max credit per harvest as BPS of book (100 = 1%). Owner may raise.
    uint16 public constant DEFAULT_MAX_HARVEST_CREDIT_BPS = 100;

    address public immutable AC;
    address public immutable pool;
    address public immutable token;

    uint16 public targetInvestedBps;
    uint16 public hysteresisBps;
    /// @notice Cap on `hookCreditYield` per harvest (BPS of book; 0 disables credit).
    uint16 public maxHarvestCreditBps;
    /// @notice Optional override; address(0) → `IHasTreasury(pool).treasury()`.
    address public incentivesReceiver;

    error OnlyPool();

    modifier onlyPool() {
        if (msg.sender != pool) revert OnlyPool();
        _;
    }

    modifier onlyKeeperOrOwner() {
        if (!AccessControl(AC).isKeeper(msg.sender) && msg.sender != AccessControl(AC).owner()) {
            revert Ownable.Unauthorized();
        }
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
    }

    function recommendedFlags() external pure virtual returns (uint32) {
        return C.HOOK_PRE_OUTFLOW | C.HOOK_POST_INFLOW;
    }

    function setBuffer(uint16 targetInvestedBps_, uint16 hysteresisBps_) external {
        if (msg.sender != AccessControl(AC).owner()) revert Ownable.Unauthorized();
        if (targetInvestedBps_ > 10_000 || hysteresisBps_ > targetInvestedBps_) revert Err.BadConfig();
        targetInvestedBps = targetInvestedBps_;
        hysteresisBps = hysteresisBps_;
    }

    function setMaxHarvestCreditBps(uint16 bps_) external {
        if (msg.sender != AccessControl(AC).owner()) revert Ownable.Unauthorized();
        if (bps_ > 10_000) revert Err.BadConfig();
        maxHarvestCreditBps = bps_;
    }

    function setIncentivesReceiver(address receiver_) external {
        if (msg.sender != AccessControl(AC).owner()) revert Ownable.Unauthorized();
        incentivesReceiver = receiver_;
    }

    // ── IPoolHooks ─────────────────────────────────────────────────────────

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
        uint256 highInv = (reserves * _hiBps()) / 10_000;
        if (inv > highInv) _trimToTarget(reserves, inv);
        else _deploy(reserves, inv, minLiq);
    }

    // ── Incentives → Treasury (no in-hook swaps) ───────────────────────────

    /// @notice Venue-specific claim (Aave RewardsController, Turtle, etc.). Default no-op.
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

    // ── Venue hooks (subclass) ─────────────────────────────────────────────

    function _venueDeposit(uint256 assets) internal virtual;
    function _venueWithdraw(uint256 assets) internal virtual returns (uint256 received);
    function _navAssets() internal view virtual returns (uint256);
    function _maxWithdrawable() internal view virtual returns (uint256);
    function _claimVenueIncentives(bytes calldata) internal virtual {}

    /// @notice Venue position ERC20 held by this hook (aToken, cToken, vault shares). address(0) if none.
    function _positionToken() internal view virtual returns (address) {
        return address(0);
    }

    // ── Buffer internals ───────────────────────────────────────────────────

    function _incentivesTo() internal view returns (address) {
        address override_ = incentivesReceiver;
        if (override_ != address(0)) return override_;
        return IHasTreasury(pool).treasury();
    }

    /// @dev Capped invested hysteresis ceiling (BPS). Shared by deploy/trim/rebalance.
    function _hiBps() private view returns (uint256 hi) {
        hi = uint256(targetInvestedBps) + hysteresisBps;
        if (hi > 10_000) hi = 10_000;
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

        uint256 targetInv = (reserves * targetInvestedBps) / 10_000;
        uint256 lowInv = targetInvestedBps > hysteresisBps
            ? (reserves * (targetInvestedBps - hysteresisBps)) / 10_000
            : 0;
        if (inv >= lowInv) return;
        uint256 keepLiq = reserves - ((reserves * _hiBps()) / 10_000);
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
        uint256 highInv = (reserves * _hiBps()) / 10_000;
        if (inv <= highInv) return;
        uint256 trim = inv - ((reserves * targetInvestedBps) / 10_000);
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
            // Sandwich/inflation bound: credit at most maxHarvestCreditBps of book per harvest.
            uint16 capBps = maxHarvestCreditBps;
            if (capBps == 0) return;
            uint256 maxCredit = (book * uint256(capBps)) / 10_000;
            if (credit > maxCredit) credit = maxCredit;
            if (credit == 0) return;
            IPool(pool).hookCreditYield(token, credit);
        } else {
            IPool(pool).hookWriteDown(token, book - nav);
        }
    }
}
