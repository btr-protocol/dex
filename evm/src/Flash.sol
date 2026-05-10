// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IFlash} from "./interfaces/IFlash.sol";
import {IPool} from "./interfaces/IPool.sol";
import {IPoolHooks} from "./interfaces/IPoolHooks.sol";
import {IERC3156FlashBorrower} from "./interfaces/external/IERC3156FlashBorrower.sol";
import {Err} from "@btr-shared/Errors.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Pricing} from "./libraries/Pricing.sol";
import {Constants as C} from "./libraries/Constants.sol";

/// @title Flash
/// @notice Standalone singleton ERC-3156 flash-loan provider.
/// @dev Phase 42H.B.3c — Flash no longer delegatecalls into Pool. It calls Pool's
///      restricted `flashSend` (push tokens) + `flashAccount` (credit fee ledgers)
///      via standard external calls. Each public fn takes `address pool` as the first
///      arg. Reserves + protocolFees accounting deltas semantically match the prior
///      module logic (R13 fix preserved — see Pool.flashAccount).
contract Flash is IFlash, ReentrancyGuardTransient {
    using SafeTransferLib for address;

    function flashLoan(
        address pool,
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override nonReentrant returns (bool) {
        // Read pool state via views.
        IPool.Asset memory asset = IPool(pool).getAsset(token);
        if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, token);
        uint16 flags = IPool(pool).getRiskFlags(token);
        if ((flags & C.FLASH_ENABLED_BIT) == 0) revert Err.FeatureDisabled(Err.Resource.FLASH);
        if ((flags & C.FROZEN_BIT) != 0) revert Err.FeatureDisabled(Err.Resource.ASSET);
        if (amount == 0) revert Err.ZeroValue();
        if (asset.reserves < amount || asset.reserves - amount < asset.minLiquidity) {
            revert Err.InsufficientAmount(asset.reserves, amount);
        }

        IPool.FeeParams memory fp = IPool(pool).getFeeParams();
        uint256 fee = (amount * uint256(fp.flashFeeBps)) / 1_000_000;
        (uint256 protoFee, ) = Pricing.splitFee(fee, fp.protoShare);

        address hook = IPool(pool).getHookForFlag(token, C.HOOK_PRE_FLASH_LOAN);
        if (hook != address(0)) IPoolHooks(hook).preFlashLoan(pool, msg.sender, token, amount, fee, data);

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

        hook = IPool(pool).getHookForFlag(token, C.HOOK_POST_FLASH_LOAN);
        if (hook != address(0)) IPoolHooks(hook).postFlashLoan(pool, msg.sender, token, amount, fee, data);

        emit FlashLoanExecuted(pool, msg.sender, address(receiver), token, amount, fee);
        return true;
    }

    function maxFlashLoan(address pool, address token) external view override returns (uint256) {
        IPool.Asset memory asset = IPool(pool).getAsset(token);
        uint16 flags = IPool(pool).getRiskFlags(token);
        if ((flags & C.FLASH_ENABLED_BIT) == 0) return 0;
        if ((flags & C.FROZEN_BIT) != 0) return 0;
        if (asset.reserves <= asset.minLiquidity) return 0;
        return uint256(asset.reserves - asset.minLiquidity);
    }

    function flashFee(address pool, address /*token*/, uint256 amount) external view override returns (uint256) {
        IPool.FeeParams memory fp = IPool(pool).getFeeParams();
        return (amount * uint256(fp.flashFeeBps)) / 1_000_000;
    }
}
