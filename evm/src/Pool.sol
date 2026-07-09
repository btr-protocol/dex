// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "./interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Pricing} from "./libraries/Pricing.sol";
import {Constants as C} from "./libraries/Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {PoolBatch} from "./libraries/PoolBatch.sol";
import {PoolLiquidity} from "./libraries/PoolLiquidity.sol";
import {PoolSwap} from "./libraries/PoolSwap.sol";
import {PoolView} from "./libraries/PoolView.sol";

/// @dev Wave-3 deferral: Solady `Ownable` retained on 10 dex contracts pre-deploy
///      (Bridge, Distributor, PoolFactory, Router, Treasury, Admin, Staking,
///      ExternalOracle, StakedToken, GovToken). Full migration to Err.NotOwner
///      planned post-deployment. See Phase 42K.10D-Wave3 carve-out.
/// @title Pool -standalone AIMM (no proxy, no modules, no ERC-7201 indirection)
/// @notice Phase 42H.B.3d -drops ERC-7201, deletes Base.sol, collapses PoolProxy.
///         Each pool instance is a direct EIP-1167 minimal-proxy clone of this impl
///         (deployment via PoolFactory). Per-clone state is initialized via initialize().
/// @dev Wave-3a (EIP-170): cold-path selectors (all admin*/staking/flash) routed via
///      `fallback()` DELEGATECALL to the PoolAux singleton.
///      Hot-path entries (swap, deposit, withdraw, frequently-called views) remain
///      explicit. ABI surface unchanged from callers' perspective — fallback forwards
///      msg.data transparently.
/// @dev STORAGE LAYOUT (Phase 42H.B.3d intentional decision):
///      `IPool.PoolStorage $` lives at slot 0 of every clone. PoolAux mirrors the
///      same layout so delegatecalls hit the right slots.
contract Pool is ReentrancyGuardTransient {
    // ────────────────────────────────────────────────────────────────
    // STORAGE (slot 0; mirrored in PoolAux)
    // ────────────────────────────────────────────────────────────────

    IPool.PoolStorage internal $;

    // ────────────────────────────────────────────────────────────────
    // IMMUTABLES
    // ────────────────────────────────────────────────────────────────

    /// @notice Shared singleton AccessControl.
    address public immutable AC;
    /// @notice Singleton Admin contract gating restricted setters.
    address public immutable admin;
    /// @notice Singleton Flash contract.
    address public immutable flash;
    /// @notice Singleton PoolAux contract (cold-path dispatcher target).
    address public immutable poolAux;

    constructor(address ac_, address admin_, address flash_, address poolAux_) {
        if (ac_ == address(0) || admin_ == address(0) || flash_ == address(0) || poolAux_ == address(0)) {
            revert Err.ZeroAddr();
        }
        AC = ac_;
        admin = admin_;
        flash = flash_;
        poolAux = poolAux_;
    }

    // ────────────────────────────────────────────────────────────────
    // CONSTANTS
    // ────────────────────────────────────────────────────────────────

    uint256 private constant INIT_LIQUIDITY_INDEX = 1e12;

    // Cohort-3 Finding 1 -Deposited/Withdrawn/LiabilitySwapped/Donated event
    // declarations dropped: emitted only from PoolLiquidity (declared there +
    // in IPool canonical surface). ABI unchanged.

    // ────────────────────────────────────────────────────────────────
    // MODIFIERS
    // ────────────────────────────────────────────────────────────────

    modifier whenInitialized() {
        if (!$.initialized) revert Err.InvalidState();
        _;
    }

    // ────────────────────────────────────────────────────────────────
    // INITIALIZE (per-clone)
    // ────────────────────────────────────────────────────────────────

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
    // HELPERS
    // ────────────────────────────────────────────────────────────────

    function _owner() internal view returns (address) {
        return AccessControl(AC).owner();
    }

    function _wrap(address token) internal view returns (address) {
        return token == SC.NATIVE ? $.wnative : token;
    }

    /// @notice ERC7802 bridge auth -bridgeable tokens query this.
    function getAuthorizedBridge() external view returns (address) {
        return $.bridge;
    }

    // ────────────────────────────────────────────────────────────────
    // LIQUIDITY DOMAIN (hot)
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
    ) external nonReentrant whenInitialized returns (IPool.WithdrawResult memory) {
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
    // EXCHANGE DOMAIN (hot)
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
    ) external view returns (IPool.SwapQuote memory) {
        return Pricing.getAnchorPathQuoteView($, _wrap(tokenIn), _wrap(tokenOut), amountIn);
    }

    function batchSwap(
        bytes calldata inputs,
        bytes calldata outputs,
        address recipient
    ) external payable nonReentrant whenInitialized returns (uint256[] memory amountsOut) {
        return PoolBatch.batchSwap($, inputs, outputs, recipient);
    }

    // ── Views (hot) ──
    function owner() external view returns (address) { return _owner(); }
    function baseToken() external view returns (address) { return $.baseToken; }
    function wnative() external view returns (address) { return $.wnative; }
    function treasury() external view returns (address) { return $.treasury; }

    function getAsset(address tk) external view returns (IPool.Asset memory) {
        return $.assets[_wrap(tk)];
    }
    function previewWithdraw(address tk, uint256 lp) external view returns (uint256, uint256) {
        return PoolView.previewWithdraw($, tk, lp);
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
    function getCoverageRatio(address tk) external view returns (uint256) {
        return PoolView.getCoverageRatio($, tk);
    }

    // ────────────────────────────────────────────────────────────────
    // FALLBACK DISPATCHER (cold paths → PoolAux)
    // ────────────────────────────────────────────────────────────────

    /// @notice Forwards any unhandled selector to PoolAux via DELEGATECALL.
    /// @dev    PoolAux storage layout mirrors Pool ($ at slot 0); auth + reentrancy
    ///         checks live in PoolAux. msg.sender is preserved transparently.
    fallback() external payable {
        address target = poolAux;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            let size := returndatasize()
            returndatacopy(0, 0, size)
            switch result
            case 0 { revert(0, size) }
            default { return(0, size) }
        }
    }

    receive() external payable {}
}
