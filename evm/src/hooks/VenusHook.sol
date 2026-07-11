// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {BasePoolHook} from "./BasePoolHook.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IVBep20} from "../interfaces/external/IVBep20.sol";
import {Constants as C} from "../libraries/Constants.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title VenusHook — Venus Core yield adapter (Compound-like mint / redeemUnderlying).
/// @notice Flags v1: BEFORE_OUTFLOW | POST_DEPOSIT. Bound 1:1 to an immutable Pool.
///         Hot path never reads exchangeRate / balanceOfUnderlying — only book + getCash on recall.
/// @dev Dual ledger on Pool: recall/deploy permute invested↔liquid; harvest credits/writes via
///      hookCreditYield / hookWriteDown.
contract VenusHook is BasePoolHook {
    using SafeTransferLib for address;

    /// @dev Default buffer: target ~65% invested / 35% liquid (BPS of reserves).
    uint16 public constant DEFAULT_TARGET_INVESTED_BPS = 6500;
    uint16 public constant DEFAULT_HYSTERESIS_BPS = 500; // ±5%

    address public immutable AC;
    address public immutable pool;
    address public immutable token;
    IVBep20 public immutable vToken;

    uint16 public targetInvestedBps;
    uint16 public hysteresisBps;

    error OnlyPool();
    error VenusMintFailed(uint256 err);
    error VenusRedeemFailed(uint256 err);

    modifier onlyPool() {
        if (msg.sender != pool) revert OnlyPool();
        _;
    }

    constructor(address ac_, address pool_, address token_, address vToken_) {
        if (ac_ == address(0) || pool_ == address(0) || token_ == address(0) || vToken_ == address(0)) {
            revert Err.ZeroAddr();
        }
        if (IVBep20(vToken_).underlying() != token_) revert Err.BadConfig();
        AC = ac_;
        pool = pool_;
        token = token_;
        vToken = IVBep20(vToken_);
        targetInvestedBps = DEFAULT_TARGET_INVESTED_BPS;
        hysteresisBps = DEFAULT_HYSTERESIS_BPS;
    }

    /// @notice VenusHook v1 flag mask (informational; Admin setter is authoritative).
    function recommendedFlags() external pure returns (uint32) {
        return C.HOOK_BEFORE_OUTFLOW | C.HOOK_POST_DEPOSIT;
    }

    function setBuffer(uint16 targetInvestedBps_, uint16 hysteresisBps_) external {
        if (msg.sender != AccessControl(AC).owner()) revert Ownable.Unauthorized();
        if (targetInvestedBps_ > 10_000 || hysteresisBps_ > targetInvestedBps_) revert Err.BadConfig();
        targetInvestedBps = targetInvestedBps_;
        hysteresisBps = hysteresisBps_;
    }

    // ── Hot-path recall (no exchangeRate) ──────────────────────────────────

    function beforeOutflow(address, address, address token_, uint256 amountNeeded)
        external
        override
        onlyPool
    {
        _recall(token_, amountNeeded);
    }

    // ── Deploy on deposit (optional; keeper rebalance also OK) ─────────────

    function postDeposit(address, address, address token_, uint256, uint256)
        external
        override
        onlyPool
    {
        if (token_ != token) return;
        _deploySurplus();
    }

    // ── Keeper harvest / buffer rebalance (cold) ───────────────────────────

    /// @notice Refresh Venus NAV into pool books (gain or write-down) + re-target buffer.
    /// @dev Uses exchangeRateStored once — never on swap hot path.
    function rebalance() external {
        if (!AccessControl(AC).isKeeper(msg.sender) && msg.sender != AccessControl(AC).owner()) {
            revert Ownable.Unauthorized();
        }
        _harvest();
        _deploySurplus();
        // If over-invested vs high band, recall down to target.
        _trimToTarget();
    }

    // ── Internal ───────────────────────────────────────────────────────────

    function _recall(address token_, uint256 amountNeeded) private {
        if (token_ != token) return;
        uint256 liq = IPool(pool).getLiquidReserves(token);
        if (liq >= amountNeeded) return;

        uint256 shortfall = amountNeeded - liq;
        uint256 inv = IPool(pool).getInvested(token);
        if (shortfall > inv) shortfall = inv;
        if (shortfall == 0) return;

        uint256 maxW = _maxWithdraw();
        if (shortfall > maxW) shortfall = maxW;
        if (shortfall == 0) return;

        uint256 err = vToken.redeemUnderlying(shortfall);
        if (err != 0) revert VenusRedeemFailed(err);
        // Tokens land on this hook — forward to bound pool. Pool books invested via balance-delta.
        token.safeTransfer(pool, shortfall);
    }

    function _deploySurplus() private {
        IPool.Asset memory a = IPool(pool).getAsset(token);
        uint256 reserves = a.reserves;
        if (reserves == 0) return;
        uint256 inv = IPool(pool).getInvested(token);
        uint256 liq = reserves > inv ? reserves - inv : 0;

        uint16 hi = targetInvestedBps + hysteresisBps;
        if (hi > 10_000) hi = 10_000;
        uint256 targetInv = (uint256(reserves) * targetInvestedBps) / 10_000;
        uint256 lowInv = targetInvestedBps > hysteresisBps
            ? (uint256(reserves) * (targetInvestedBps - hysteresisBps)) / 10_000
            : 0;
        if (inv >= lowInv) return;
        uint256 keepLiq = reserves - ((uint256(reserves) * hi) / 10_000);
        // Never leave R_liq below minLiquidity.
        uint256 minLiq = a.minLiquidity;
        if (keepLiq < minLiq) keepLiq = minLiq;
        if (liq <= keepLiq) return;
        uint256 deployAmt = liq - keepLiq;
        uint256 gap = targetInv > inv ? targetInv - inv : 0;
        if (deployAmt > gap) deployAmt = gap;
        if (deployAmt == 0) return;

        if (msg.sender == pool) {
            // postDeposit: pool pre-approved liquid book; balance-delta books invested.
            token.safeTransferFrom(pool, address(this), deployAmt);
        } else {
            // Keeper rebalance: pool pushes + books invested atomically.
            IPool(pool).hookPull(token, deployAmt);
        }
        token.safeApproveWithRetry(address(vToken), deployAmt);
        uint256 err = vToken.mint(deployAmt);
        token.safeApproveWithRetry(address(vToken), 0);
        if (err != 0) revert VenusMintFailed(err);
    }

    function _trimToTarget() private {
        uint256 reserves = IPool(pool).getAsset(token).reserves;
        if (reserves == 0) return;
        uint256 inv = IPool(pool).getInvested(token);
        uint16 hi = targetInvestedBps + hysteresisBps;
        if (hi > 10_000) hi = 10_000;
        uint256 highInv = (uint256(reserves) * hi) / 10_000;
        if (inv <= highInv) return;
        uint256 trim = inv - ((uint256(reserves) * targetInvestedBps) / 10_000);
        uint256 maxW = _maxWithdraw();
        if (trim > maxW) trim = maxW;
        if (trim == 0) return;
        uint256 err = vToken.redeemUnderlying(trim);
        if (err != 0) revert VenusRedeemFailed(err);
        token.safeTransfer(pool, trim);
        // Keeper trim only (mutex + balance proof). Hot-path recall books via beforeOutflow Δbalance.
        IPool(pool).hookNotifyRecall(token, trim);
    }

    function _harvest() private {
        uint256 book = IPool(pool).getInvested(token);
        uint256 shares = vToken.balanceOf(address(this));
        // Stale book with zero vToken shares: clear fictional R_inv.
        if (shares == 0) {
            if (book > 0) IPool(pool).hookWriteDown(token, book);
            return;
        }
        uint256 rate = vToken.exchangeRateStored(); // 1e18-scaled
        uint256 nav = (shares * rate) / 1e18;
        if (nav == book) return;
        if (nav > book) {
            IPool(pool).hookCreditYield(token, nav - book);
        } else {
            IPool(pool).hookWriteDown(token, book - nav);
        }
    }

    /// @dev maxWithdraw = min(shares×exchangeRateStored, getCash−totalReserves). Cold/recall only.
    function _maxWithdraw() private view returns (uint256) {
        uint256 shares = vToken.balanceOf(address(this));
        if (shares == 0) return 0;
        uint256 byShares = (shares * vToken.exchangeRateStored()) / 1e18;
        uint256 cash = vToken.getCash();
        uint256 reserves = vToken.totalReserves();
        uint256 byCash = cash > reserves ? cash - reserves : 0;
        return byShares < byCash ? byShares : byCash;
    }
}
