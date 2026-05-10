// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {InternalOracle} from "./InternalOracle.sol";
import {Err} from "@btr-shared/Errors.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IPoolHooks} from "../interfaces/IPoolHooks.sol";
import {IPoolModule} from "../interfaces/modules/IPool.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Pricing as Pricing} from "../libraries/Pricing.sol";
import {Maths as M} from "../libraries/Maths.sol";
import {Constants as C} from "../libraries/Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {AnchorTree} from "../libraries/AnchorTree.sol";

/// @title Pool — merged Liquidity + Exchange module
/// @notice deposit/withdraw/donate/swapLiability + swap/batchSwap/quotes/views
/// @dev Single module replaces former Liquidity + Exchange. Internal calls
///      replace the prior IExchangeQuote delegatecall shim.
contract Pool is InternalOracle {
    using SafeTransferLib for address;
    using {M.b64To1e18} for uint64;

    /// @notice Phase 42H.B.3a — singleton Admin contract gating restricted setters.
    /// @dev Admin no longer delegatecalls; it CALLS Pool via standard external calls.
    ///      Immutable lives in Pool's bytecode (set at Pool deployment), identical for
    ///      all proxies sharing this Pool impl. Same pattern as `AC` from B.1.
    address public immutable admin;

    /// @notice Phase 42H.B.3b — singleton Staking contract.
    /// @dev Staking calls Pool's restricted `stakingAdjustLpBalance` via standard external calls.
    ///      Immutable; identical for all proxies sharing this Pool impl.
    address public immutable staking;

    /// @notice Phase 42H.B.3c — singleton Flash contract.
    /// @dev Flash calls Pool's restricted `flashSend` + `flashAccount` via standard external calls.
    ///      Immutable; identical for all proxies sharing this Pool impl.
    address public immutable flash;

    constructor(address ac_, address admin_, address staking_, address flash_) InternalOracle(ac_) {
        if (admin_ == address(0) || staking_ == address(0) || flash_ == address(0)) revert Err.ZeroAddr();
        admin = admin_;
        staking = staking_;
        flash = flash_;
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

    /// @dev Initial liquidity index (1e12 → ~18M× growth before uint64 overflow).
    /// @dev F-LOW-R10 NOT FIXED (intentional): `asset.liquidityIndex` is uint64. Truncation horizon
    ///      is ~18M× growth from initial 1e12 — accepted constraint per design.
    /// @dev F-A1-R14-2 (R14 LOW, doc) update: prior wording ("sustained donate-rebases") under-stated
    ///      the threshold. A SINGLE donate against `liabBefore == 1` (1-wei first deposit) followed
    ///      by `donate(amt)` produces `idx_new = idx * (1 + amt) / 1` and silently truncates to
    ///      uint64 once `idx*(1+amt) >= 2^64` (≈ 1.8e7 amount at INIT_INDEX=1e12). The depositor-
    ///      seeded factory pattern (deploy + immediate seed-deposit by deployer) is the canonical
    ///      mitigation; in normal operation the index grows linearly with yield. Widen this slot
    ///      append-only if a future asset class warrants higher dynamic range.
    uint256 private constant INIT_LIQUIDITY_INDEX = 1e12;

    // ── Liquidity events (mirrored from ICore to avoid import) ──
    event Deposited(address indexed sender, address indexed token, uint256 amount, uint256 lpAmount);
    event Withdrawn(address indexed sender, address indexed token, uint256 amount, uint256 lpAmount);
    event LiabilitySwapped(address indexed sender, address indexed tokenIn, address indexed tokenOut, uint256 lpAmountIn, uint256 lpAmountOut, uint256 haircut);
    event Donated(address indexed sender, address indexed token, uint256 amount);

    // ─────────────────────────────────────────────────────────────────
    // LIQUIDITY DOMAIN
    // ─────────────────────────────────────────────────────────────────

    function deposit(
        address token,
        uint256 amount
    ) external payable nonReentrant whenInitialized returns (IPool.DepositResult memory result) {
        if (amount == 0) revert Err.ZeroValue();

        IPool.PoolStorage storage $ = _s();
        address tkn = _wrap($, token);
        IPool.Asset storage asset = _asset($, tkn);

        _applyDecay($, tkn, asset);
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

        IPool.PoolStorage storage $ = _s();
        address tkn = _wrap($, token);
        IPool.Asset storage asset = _asset($, tkn);

        _applyDecay($, tkn, asset);
        _checkRisk($, tkn, 0);

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

        IPool.PoolStorage storage $ = _s();
        address fromTk = _wrap($, tokenFrom);
        address toTk = _wrap($, tokenTo);

        _checkWithdrawCooldown(msg.sender, fromTk);
        if ($.lpBalances[msg.sender][fromTk] < lpAmount) {
            revert Err.InsufficientAmount($.lpBalances[msg.sender][fromTk], lpAmount);
        }

        IPool.Asset storage assetFrom = _asset($, fromTk);
        IPool.Asset storage assetTo = _asset($, toTk);
        _applyDecay($, fromTk, assetFrom);
        _applyDecay($, toTk, assetTo);

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
            // Direct internal quote — replaces former IExchangeQuote delegatecall shim
            IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, fromTk, toTk, withdrawValue);
            (amt, haircut) = _applyHaircut(q.amountOut, assetTo.reserves, assetTo.liabilities, assetTo.haircutSuppressor);
            // F-A4-2 (LOW, R9 carry-over): floor must include q.protoFee since reserves are debited
            // by `amt + q.protoFee` below; check against `amt` alone allowed silent underflow on
            // edge when reserves ∈ [amt, amt+protoFee).
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

        IPool.PoolStorage storage $ = _s();
        address inTk = _wrap($, tokenIn);
        address outTk = _wrap($, tokenOut);
        if (inTk == outTk) revert Err.InvalidInput();

        IPool.Asset storage assetIn = $.assets[inTk];
        IPool.Asset storage assetOut = $.assets[outTk];
        if (assetIn.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, inTk);
        if (assetOut.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, outTk);

        _applyDecay($, inTk, assetIn);
        _applyDecay($, outTk, assetOut);
        _checkRisk($, inTk, C.LIABILITY_SWAP_ENABLED_BIT);
        _checkRisk($, outTk, C.LIABILITY_SWAP_ENABLED_BIT);

        if ($.lpBalances[msg.sender][inTk] < lpAmountIn) {
            revert Err.InsufficientAmount($.lpBalances[msg.sender][inTk], lpAmountIn);
        }

        uint256 liabIn = (lpAmountIn * (assetIn.liquidityIndex == 0 ? INIT_LIQUIDITY_INDEX : assetIn.liquidityIndex)) / SC.WAD;
        if (liabIn > assetIn.liabilities) revert Err.InsufficientAmount(assetIn.liabilities, liabIn);

        IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, inTk, outTk, liabIn);
        // F-INFO (R10): q.protoFee is INTENTIONALLY DROPPED on this path. swapLiability is a
        // pure LP-share rebalance across token buckets — no actual swap, no token push, no
        // reserves debit. Both sides of the trade are LP-owned, so there is no protocol cut to
        // collect. q.protoFee is computed by getAnchorPathQuote but discarded. Conservation
        // holds (no balance flow). If a future change adds a real fee transfer here, this
        // omission becomes load-bearing — re-evaluate.
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

    /// @dev Linear haircut w/ suppression: deficit × (1 - suppression/20000), capped 100%.
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

    // ─────────────────────────────────────────────────────────────────
    // EXCHANGE DOMAIN
    // ─────────────────────────────────────────────────────────────────

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external payable nonReentrant whenInitialized returns (uint256 out) {
        IPool.PoolStorage storage $ = _s();
        address[2] memory tk = [_wrap($, tokenIn), _wrap($, tokenOut)];

        if (tk[0] == tk[1]) revert Err.InvalidInput();
        if (amountIn == 0) revert Err.ZeroValue();

        _checkRisk($, tk[0], C.SWAP_ENABLED_BIT);
        _checkRisk($, tk[1], C.SWAP_ENABLED_BIT);
        _applyDecay($, tk[0], $.assets[tk[0]]);
        _applyDecay($, tk[1], $.assets[tk[1]]);

        uint256 actualIn = _pull(tokenIn, amountIn);
        IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, tk[0], tk[1], actualIn);

        out = _processSwap($, tk, actualIn, q);

        // Post-exec floor check (hooks can mutate reserves via _postSwap)
        if ($.assets[tk[1]].reserves < $.assets[tk[1]].minLiquidity) {
            revert Err.ThresholdViolation($.assets[tk[1]].reserves, $.assets[tk[1]].minLiquidity);
        }

        _oracle(q);
        if (out < minAmountOut) revert Err.ThresholdViolation(out, minAmountOut);

        _push(tokenOut, recipient, out);
        emit IPoolModule.Swapped(msg.sender, recipient, tk[0], tk[1], actualIn, out, q.spreadBps, q.protoFee, q.lpFee);
    }

    function _processSwap(
        IPool.PoolStorage storage $,
        address[2] memory tk,
        uint256 actualIn,
        IPool.SwapQuote memory q
    ) internal returns (uint256 out) {
        (uint256 extraFee, uint16 feeOverride) = _preSwap($, tk[0], tk[1], actualIn, q.amountOut);
        out = q.amountOut;

        if (feeOverride > 0) {
            uint256 raw = out + q.protoFee + q.lpFee;
            uint256 fee = (raw * feeOverride) / 1_000_000;
            (q.protoFee, q.lpFee) = Pricing.splitFee(fee, $.feeParams.protoShare);
            q.spreadBps = feeOverride;
            q.amountOut = raw - fee;
            out = q.amountOut;
        }

        out = _applyHookFee($, extraFee, q, out);
        _exec($, tk[0], tk[1], actualIn, q);

        int256 delta = _postSwap($, tk[0], tk[1], actualIn, out);
        uint256 protoDelta = 0;
        if (delta > 0) {
            uint256 protoBefore = q.protoFee;
            out = _applyHookFee($, uint256(delta), q, out);
            // Phase 42D R4-A1-1: persist post-swap hook proto-fee delta to ledger
            // (was: silently donated to LP reserves; event over-reported vs storage).
            protoDelta = q.protoFee - protoBefore;
            if (protoDelta != 0) {
                $.protocolFees[tk[1]] += protoDelta;
            }
        } else if (delta < 0) {
            out += uint256(-delta);
        }

        _reconcile($.assets[tk[1]], out, q.amountOut);

        // Phase 42C R6: explicit reserves debit AFTER _reconcile.
        // R5 attempted `out += protoDelta` BEFORE _reconcile, but `out` is the named return
        // propagated to swap()'s `_push(tokenOut, recipient, out)` (Pool.sol:269) — this leaked
        // protoDelta of tokenOut to the swap user. Correct flow: leave `out` at the user-facing
        // value; _reconcile over-credits reserves by (q.amountOut - out) = (LP-fee + protoDelta);
        // subtract protoDelta here so reserves capture only the LP-fee portion. Ledger entry above
        // retains protoDelta for Treasury collection. Pool balance == Σreserves + Σprotocolfees.
        if (protoDelta != 0) {
            $.assets[tk[1]].reserves -= uint128(protoDelta);
        }
    }

    function getSwapQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external returns (IPool.SwapQuote memory) {
        IPool.PoolStorage storage $ = _s();
        return Pricing.getAnchorPathQuote($, _wrap($, tokenIn), _wrap($, tokenOut), amountIn);
    }

    function batchSwap(
        bytes calldata inputs,
        bytes calldata outputs,
        address recipient
    ) external payable nonReentrant whenInitialized returns (uint256[] memory amountsOut) {
        IPool.PoolStorage storage $ = _s();
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
            tk = _wrap($, tk);
            IPool.Asset storage a = $.assets[tk];
            if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tk);

            _checkRisk($, tk, C.SWAP_ENABLED_BIT);
            _applyDecay($, tk, a);

            uint256 amt = _pull(tk == $.wnative ? SC.NATIVE : tk, M.decodeB64(amtB64, a.decimals));

            if (tk == base) {
                baseTotal += amt;
            } else {
                IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, tk, base, amt);
                _exec($, tk, base, amt, q);
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
            tk = _wrap($, tk);
            IPool.Asset storage a = $.assets[tk];
            if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tk);

            wSum += w;
            uint256 baseIn = (baseTotal * w) / 10000;

            _checkRisk($, tk, C.SWAP_ENABLED_BIT);
            _applyDecay($, tk, a);

            if (tk == base) {
                amountsOut[j] = baseIn;
            } else {
                IPool.SwapQuote memory q = Pricing.getAnchorPathQuote($, base, tk, baseIn);
                _exec($, base, tk, baseIn, q);
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
            tk = _wrap($, tk);
            _push(tk == $.wnative ? SC.NATIVE : tk, recipient, amountsOut[j]);
            unchecked { ++j; }
        }

        emit IPoolModule.BatchSwapped(msg.sender, recipient, inLen, outLen, baseTotal);
    }

    // ── Views ──
    function owner() external view returns (address) { return _owner(); }
    function baseToken() external view returns (address) { return _s().baseToken; }
    function wnative() external view returns (address) { return _s().wnative; }
    function treasury() external view returns (address) { return _s().treasury; }

    function getAsset(address tk) external view returns (IPool.Asset memory) {
        IPool.PoolStorage storage $ = _s(); return $.assets[_wrap($, tk)];
    }
    function getLPBalance(address u, address tk) external view returns (uint256) {
        IPool.PoolStorage storage $ = _s(); return $.lpBalances[u][_wrap($, tk)];
    }
    function getProtocolFees(address tk) external view returns (uint256) {
        IPool.PoolStorage storage $ = _s(); return $.protocolFees[_wrap($, tk)];
    }
    function getRiskFlags(address tk) external view returns (uint16) {
        IPool.PoolStorage storage $ = _s(); return $.riskConfigs[_wrap($, tk)].flags;
    }
    function getFeeParams() external view returns (IPool.FeeParams memory) { return _s().feeParams; }
    function getHookForFlag(address tk, uint32 flag) external view returns (address) {
        IPool.PoolStorage storage $ = _s();
        return _hook($, _wrap($, tk), flag);
    }
    function getMidPrice(address tk) external returns (uint256) {
        IPool.PoolStorage storage $ = _s();
        return _readOracle($, _wrap($, tk)).lastPriceB64.b64To1e18();
    }

    // ── Internal swap helpers ──

    function _exec(
        IPool.PoolStorage storage $,
        address tkIn,
        address tkOut,
        uint256 amtIn,
        IPool.SwapQuote memory q
    ) private {
        IPool.Asset storage aIn = $.assets[tkIn];
        IPool.Asset storage aOut = $.assets[tkOut];

        // Pre-exec reserve check (protects against hook drains in _postSwap/_reconcile).
        // Phase 42C R8: include q.protoFee in the check ∵ both q.amountOut and q.protoFee
        // are debited from reserves below.
        uint256 minReq = q.amountOut + q.protoFee + aOut.minLiquidity;
        if (aOut.reserves < minReq) revert Err.InsufficientAmount(aOut.reserves, minReq);

        // A1-1 fix: route IN-side half-spread to protocolFees[tkIn] (was silently dropped).
        // Phase 42D A4-3 DISCARD: floor-rounding on odd PBPS — 1-PBPS impact, ceil-rounding
        // would add complexity for negligible LP gain. Rounding favors user by ≤ 1 wei.
        uint256 inFee = (amtIn * q.spreadBps / 2) / 1_000_000;
        aIn.reserves += uint128(amtIn - inFee);
        $.protocolFees[tkIn] += inFee;
        // Phase 42C R8 A1-R8-1 (HIGH) + A1-R8-2 (LOW): carve all quote-time + pre-hook
        // protoFee from LP-owned reserves into protocol-owned escrow. Prior code debited only
        // q.amountOut; the q.protoFee credit to $.protocolFees[tkOut] silently inflated the
        // ledger relative to actual reserves backing it (HIGH: drains LP on Treasury collect).
        // q.protoFee at this site equals pf₀ (quote-time) + pf_pre (pre-hook); both must be
        // carved here because _processSwap invokes _applyHookFee(extraFee, ...) BEFORE _exec,
        // so the pre-hook proto increment is already folded into q.protoFee. The post-hook
        // increment (pf_post) is handled separately at the R6 debit site after _reconcile.
        // Conservation post-fix: B(t) = ΣR(t) + ΣP(t) over all swaps.
        aOut.reserves -= uint128(q.amountOut + q.protoFee);
        $.protocolFees[tkOut] += q.protoFee;

        uint64 floor = aOut.reservationPrice;
        if (floor != 0) {
            uint64 price = _readOracle($, tkOut).lastPriceB64;
            if (price < floor) revert Err.PriceBelowReservation(price, floor);
        }
    }

    function _oracle(IPool.SwapQuote memory q) private {
        if (q.routeHops.length < 2 || q.hopPrices.length == 0) return;
        address base = _s().baseToken;

        for (uint256 i; i < q.routeHops.length - 1;) {
            address a = q.routeHops[i];
            address b = q.routeHops[i + 1];
            uint64 p = q.hopPrices[i];

            // Phase 42H.B.2: direct internal call (was: external self-call → Diamond fallback
            // → delegatecall → InternalOracle module). Pool now inherits InternalOracle.
            if (a == base) _pushFeedInternal(b, address(0), p, 0);
            else if (b == base) _pushFeedInternal(a, address(0), p, 0);
            else _pushFeedInternal(a, b, p, p);

            unchecked { ++i; }
        }
    }

    function _runHook(
        IPool.PoolStorage storage $,
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
        IPool.PoolStorage storage $,
        address tkIn,
        address tkOut,
        uint256 amtIn,
        uint256 amtOut
    ) private returns (uint256 extraFee, uint16 feeOverride) {
        (uint256 f1, uint16 o1, ) = _runHook($, tkIn, address(0), C.HOOK_PRE_SWAP, true, tkIn, tkOut, amtIn, amtOut);
        extraFee += f1;
        if (o1 > 0) feeOverride = o1;
        (uint256 f2, uint16 o2, ) = _runHook($, tkOut, $.hooks[tkIn], C.HOOK_PRE_SWAP, true, tkIn, tkOut, amtIn, amtOut);
        extraFee += f2;
        if (o2 > 0) feeOverride = o2;
    }

    function _postSwap(
        IPool.PoolStorage storage $,
        address tkIn,
        address tkOut,
        uint256 amtIn,
        uint256 amtOut
    ) private returns (int256 delta) {
        (, , int256 d1) = _runHook($, tkIn, address(0), C.HOOK_POST_SWAP, false, tkIn, tkOut, amtIn, amtOut);
        (, , int256 d2) = _runHook($, tkOut, $.hooks[tkIn], C.HOOK_POST_SWAP, false, tkIn, tkOut, amtIn, amtOut);
        return d1 + d2;
    }

    function _applyHookFee(
        IPool.PoolStorage storage $,
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

    // ─────────────────────────────────────────────────────────────────
    // ADMIN DOMAIN — restricted setters gated by `admin` singleton (42H.B.3a)
    // ─────────────────────────────────────────────────────────────────

    function adminFreezeAsset(address token) external onlyAdmin {
        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        _asset($, t);
        $.riskConfigs[t].flags |= C.FROZEN_BIT;
    }

    function adminUnfreezeAsset(address token) external onlyAdmin {
        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        _asset($, t);
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

        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        if ($.assets[t].decimals != 0) revert Err.AlreadyConfigured(Err.Resource.ASSET, t);

        _validateProfileMemory(profile);
        _validateOracleConfig(oracleCfg);
        _initAsset($, t, decimals, minFeeBps, minDispersion, maxDispersion, gamma, vega, lambda);
        _setupOracleAndConfig($, t, oracleCfg, riskCfg, profile, initialPrice, initialFastVolEMA, initialSlowVolEMA);
    }

    function adminCollectProtocolFees(address token, address recipient)
        external nonReentrant onlyAdmin returns (uint256 amount)
    {
        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        amount = $.protocolFees[t];
        if (amount > 0) {
            $.protocolFees[t] = 0;
            _push(token, recipient, amount);
        }
    }

    function adminSetGovToken(address govToken) external onlyAdmin {
        if (govToken == address(0)) revert Err.ZeroValue();
        IPool.PoolStorage storage $ = _s();
        if ($.govToken != address(0)) revert Err.AlreadyConfigured(Err.Resource.STAKING, $.govToken);
        $.govToken = govToken;
    }

    function adminSetStakedGovToken(address sGov) external onlyAdmin {
        if (sGov == address(0)) revert Err.ZeroValue();
        IPool.PoolStorage storage $ = _s();
        if ($.sGovToken != address(0)) revert Err.AlreadyConfigured(Err.Resource.STAKING, $.sGovToken);
        $.sGovToken = sGov;
    }

    function adminSetFlowCooldown(uint16 cooldownSeconds) external onlyAdmin {
        _s().flowCooldownSeconds = cooldownSeconds;
    }

    function adminSetAnchor(address token, address anchor) external onlyAdmin {
        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
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
        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
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
        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        _asset($, t);
        $.riskConfigs[t] = cfg;
    }

    function adminSetOracleConfig(address token, IPool.OracleConfig calldata cfg) external onlyAdmin {
        _validateOracleConfig(cfg);
        _s().oracleConfigs[token] = cfg;
    }

    function adminSetFeeParams(IPool.FeeParams calldata params) external onlyAdmin {
        if (params.protoShare > 100) revert Err.InvalidInput();
        _s().feeParams = params;
    }

    function adminSetOwner(address newOwner) external onlyAdmin {
        if (newOwner == address(0)) revert Err.ZeroValue();
        _s().owner = newOwner;
    }

    function adminSetBridge(address newBridge) external onlyAdmin {
        _s().bridge = newBridge;
    }

    function adminSetTreasury(address newTreasury) external onlyAdmin {
        if (newTreasury == address(0)) revert Err.ZeroValue();
        _s().treasury = newTreasury;
    }

    function adminSetBaseToken(address newBase) external onlyAdmin {
        _s().baseToken = newBase;
    }

    // ─────────────────────────────────────────────────────────────────
    // STAKING DOMAIN — restricted setters gated by `staking` singleton (42H.B.3b)
    // ─────────────────────────────────────────────────────────────────

    /// @notice Adjust LP balance on behalf of the singleton Staking contract.
    /// @dev Conservation invariant: stake → debit; unstake → credit.
    ///      Only the singleton staking address may invoke. delta sign carries direction.
    function stakingAdjustLpBalance(address user, address token, int256 delta) external onlyStaking {
        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        if (delta > 0) {
            $.lpBalances[user][t] += uint256(delta);
        } else if (delta < 0) {
            uint256 d = uint256(-delta);
            uint256 cur = $.lpBalances[user][t];
            if (cur < d) revert Err.InsufficientAmount(cur, d);
            $.lpBalances[user][t] = cur - d;
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // FLASH DOMAIN — restricted setters gated by `flash` singleton (42H.B.3c)
    // ─────────────────────────────────────────────────────────────────

    /// @notice Push `amount` of `token` to `to` on behalf of the singleton Flash contract.
    /// @dev Applies decay + risk/min-liquidity gating; transfers tokens out of the Pool.
    ///      Reserves are NOT decremented here: the balance-delta accounting in Flash +
    ///      flashAccount() preserves the invariant `tokenBalance == Σreserves + Σprotocolfees`
    ///      across the loan window (R13 fix preserved).
    function flashSend(address token, uint256 amount, address to) external onlyFlash whenInitialized nonReentrant {
        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        IPool.Asset storage asset = _asset($, t);

        _applyDecay($, t, asset);

        if (amount == 0) revert Err.ZeroValue();
        if (asset.reserves < amount || asset.reserves - amount < asset.minLiquidity) {
            revert Err.InsufficientAmount(asset.reserves, amount);
        }

        _push(token, to, amount);
    }

    /// @notice Credit reserves with LP-portion of fee + protocolFees with proto-portion.
    /// @dev R13 fix preserved (F-A1-R12-2): delta-credit ONLY (no balance overwrite). Flash
    ///      verifies the borrower repaid `amount + fee` to Pool before invoking this.
    function flashAccount(address token, uint256 fee, uint256 protoFee) external onlyFlash {
        if (protoFee > fee) revert Err.InvalidInput();
        IPool.PoolStorage storage $ = _s();
        address t = _wrap($, token);
        IPool.Asset storage asset = _asset($, t);
        unchecked { asset.reserves += uint128(fee - protoFee); }
        $.protocolFees[t] += protoFee;
    }

    // ── helpers (relocated from former Admin module) ──

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
        IPool.PoolStorage storage $,
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
        IPool.PoolStorage storage $,
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
            try InternalOracle(address(this)).updateFeed(t, initialPrice, accDec, initialFastVolEMA, initialSlowVolEMA) {} catch {
                revert Err.OperationFailed();
            }
        }
    }
}
