// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Base} from "./Base.sol";
import {Err} from "../Errors.sol";
import {IFlash} from "../interfaces/modules/IFlash.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IPoolHooks} from "../interfaces/IPoolHooks.sol";
import {IERC3156FlashBorrower} from "../interfaces/external/IERC3156FlashBorrower.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {LibPricing as Pricing} from "../libraries/LibPricing.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";

/// @title Flash — ERC-3156 flash loans
contract Flash is Base, IFlash {
    using SafeTransferLib for address;

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override nonReentrant whenInitialized returns (bool) {
        IPool.PoolStorage storage $ = _s();
        address tokenNorm = _wrap($, token);

        IPool.Asset storage asset = $.assets[tokenNorm];
        IPool.RiskConfig storage risk = $.riskConfigs[tokenNorm];

        _applyDecay($, tokenNorm, asset);

        if ((risk.flags & C.FLASH_ENABLED_BIT) == 0) revert Err.FeatureDisabled(Err.Resource.FLASH);
        if ((risk.flags & C.FROZEN_BIT) != 0) revert Err.FeatureDisabled(Err.Resource.ASSET);
        if (amount == 0) revert Err.ZeroValue();
        if (asset.reserves < amount || asset.reserves - amount < asset.minLiquidity) {
            revert Err.InsufficientAmount(asset.reserves, amount);
        }

        uint256 fee = (amount * uint256($.feeParams.flashFeeBps)) / 1_000_000;
        (uint256 protoFee, ) = Pricing.splitFee(fee, $.feeParams.protoShare);

        address hook = _hook($, tokenNorm, C.HOOK_PRE_FLASH_LOAN);
        if (hook != address(0)) IPoolHooks(hook).preFlashLoan(address(this), msg.sender, tokenNorm, amount, fee, data);

        uint256 balanceBefore = _balanceOf(token);
        _push(token, address(receiver), amount);

        bytes32 result = receiver.postFlashLoan(msg.sender, token, amount, fee, data);
        if (result != keccak256("ERC3156FlashBorrower.postFlashLoan")) revert Err.OperationFailed();

        uint256 balanceAfter = _balanceOf(token);
        if (balanceAfter < balanceBefore + amount + fee) revert Err.OperationFailed();

        asset.reserves = uint128(balanceAfter - protoFee);
        $.protocolFees[tokenNorm] += protoFee;

        hook = _hook($, tokenNorm, C.HOOK_POST_FLASH_LOAN);
        if (hook != address(0)) IPoolHooks(hook).postFlashLoan(address(this), msg.sender, tokenNorm, amount, fee, data);

        emit IFlash.FlashLoanExecuted(msg.sender, address(receiver), token, amount, fee);
        return true;
    }

    function maxFlashLoan(address token) external view override returns (uint256) {
        IPool.PoolStorage storage $ = _s();
        address tokenNorm = _wrap($, token);
        IPool.Asset storage asset = $.assets[tokenNorm];
        IPool.RiskConfig storage risk = $.riskConfigs[tokenNorm];

        if ((risk.flags & C.FLASH_ENABLED_BIT) == 0) return 0;
        if ((risk.flags & C.FROZEN_BIT) != 0) return 0;
        if (asset.reserves <= asset.minLiquidity) return 0;
        return uint256(asset.reserves - asset.minLiquidity);
    }

    function flashFee(address /*token*/, uint256 amount) external view override returns (uint256) {
        return (amount * uint256(_s().feeParams.flashFeeBps)) / 1_000_000;
    }
}
