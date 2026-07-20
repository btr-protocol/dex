// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IFlash} from "./interfaces/IFlash.sol";
import {IPool} from "./interfaces/IPool.sol";
import {IERC3156FlashBorrower} from "./interfaces/external/IERC3156FlashBorrower.sol";
import {Err} from "@btr-shared/Errors.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Pricing} from "./libraries/Pricing.sol";
import {Constants as C} from "./libraries/Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";

/// @title Flash
/// @notice Standalone singleton ERC-3156 flash-loan provider.
/// @dev Phase 42H.B.3c -Flash no longer delegatecalls into Pool. It calls Pool's
///      restricted `flashSend` (push tokens) + `flashAccount` (credit fee ledgers)
///      via standard external calls. Each public fn takes `address pool` as the first
///      arg. Reserves + protocolFees accounting deltas semantically match the prior
///      module logic (R13 fix preserved -see Pool.flashAccount).
contract Flash is IFlash, ReentrancyGuardTransient {
  using SafeTransferLib for address;

  function flashLoan(
    address pool,
    IERC3156FlashBorrower receiver,
    address token,
    uint256 amount,
    bytes calldata data
  ) external override nonReentrant returns (bool) {
    // FLS-01: reject the EIP-7528 native sentinel (0xEeee…). It has no code, so `balanceOf(sentinel,
    // pool)` reads 0 both before AND after the loan — the repay check `balanceAfter < balanceBefore +
    // fee` then passes at fee==0 (full principal drain) and fail-closes as DoS at fee>0, while the
    // pool actually pushes/expects wnative. The pool holds wnative (ERC-20) as the asset, so a flash
    // borrower MUST request wnative directly (correct ERC-20 balanceOf accounting).
    if (token == SC.NATIVE) revert Err.FeatureDisabled(Err.Resource.FLASH);
    // Existence rides the flags read: an unlisted token has flags 0 ⇒ FLASH bit unset ⇒ fail-closed.
    uint16 flags = IPool(pool).getRiskFlags(token);
    if ((flags & C.FLASH_ENABLED_BIT) == 0) revert Err.FeatureDisabled(Err.Resource.FLASH);
    if ((flags & C.HALT_MASK) != 0) revert Err.FeatureDisabled(Err.Resource.ASSET);
    if (amount == 0) revert Err.ZeroValue();

    IPool.FeeParams memory fp = IPool(pool).getFeeParams();
    uint256 fee = (amount * uint256(fp.flashFeePbps)) / SC.PBPS;
    (uint256 protoFee,) = Pricing.splitFee(fee, fp.protoShare);

    // Pool-side recall (books invested via balance-delta) before liquid check / send.
    // Recall target = amount + minLiquidity so post-send floor holds.
    IPool(pool).flashPrepare(token, amount, msg.sender);
    // Liquidity floor (liq − amount >= minLiquidity) is enforced pool-side in flashSend — the sole
    // authoritative copy; a Flash-side pre-check would be a third restatement of the same invariant.

    // Capture pool's token balance pre-debit; Pool.flashSend will push `amount` to receiver.
    uint256 balanceBefore = SafeTransferLib.balanceOf(token, pool);
    IPool(pool).flashSend(token, amount, address(receiver));

    bytes32 result = receiver.postFlashLoan(msg.sender, token, amount, fee, data);
    if (result != keccak256("ERC3156FlashBorrower.postFlashLoan")) revert Err.OperationFailed();

    // Borrower repays `amount + fee` to Pool. Post-callback pool balance must be at least
    // balanceBefore + fee (R13 fix: balanceBefore was captured BEFORE flashSend debited
    // `amount`; net Δ = +fee).
    uint256 balanceAfter = SafeTransferLib.balanceOf(token, pool);
    if (balanceAfter < balanceBefore + fee) revert Err.OperationFailed();

    // Credit reserves with LP-portion of fee + protocolFees with proto-portion (R13 fix).
    IPool(pool).flashAccount(token, fee, protoFee);

    emit FlashLoanExecuted(pool, msg.sender, address(receiver), token, amount, fee);
    return true;
  }

  function maxFlashLoan(address pool, address token) external view override returns (uint256) {
    if (token == SC.NATIVE) return 0; // FLS-01: native sentinel is not loanable (request wnative)
    uint16 flags = IPool(pool).getRiskFlags(token);
    if ((flags & C.FLASH_ENABLED_BIT) == 0) return 0;
    if ((flags & C.HALT_MASK) != 0) return 0;
    // Honest executable capacity = R_liq − minLiquidity (getBuffer: 1 call vs full 4-slot getAsset).
    (uint256 reserves, uint256 invested, uint256 minLiquidity) = IPool(pool).getBuffer(token);
    uint256 liq = reserves - invested;
    if (liq <= minLiquidity) return 0;
    return liq - minLiquidity;
  }

  function flashFee(address pool, address token, uint256 amount)
    external
    view
    override
    returns (uint256)
  {
    if (token == SC.NATIVE) revert Err.FeatureDisabled(Err.Resource.FLASH); // FLS-01: unsupported token
    IPool.FeeParams memory fp = IPool(pool).getFeeParams();
    return (amount * uint256(fp.flashFeePbps)) / SC.PBPS;
  }
}
