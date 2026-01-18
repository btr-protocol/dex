// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseV1} from "./BaseV1.sol";
import {IErrors} from "../interfaces/IErrors.sol";
import {IFlashV1} from "../interfaces/modules/IFlashV1.sol";
import {IPoolV1} from "../interfaces/IPoolV1.sol";
import {IPoolHooks} from "../interfaces/IPoolHooks.sol";
import {IERC3156FlashBorrower} from "../interfaces/external/IERC3156FlashBorrower.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {LibPricing as Pricing} from "../libraries/LibPricing.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";
import {LibConstants as C} from "../libraries/LibConstants.sol";

/// @title Flash
/// @notice Flash loan operations (ERC-3156 compliant)
contract FlashV1 is BaseV1, IFlashV1 {
    using SafeTransferLib for address;


    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override nonReentrant whenInitialized returns (bool) {
        IPoolV1.PoolStorage storage $ = _s();

        // Normalize NATIVE to WETH for internal storage
        address tokenNorm = _wrap($, token);

        IPoolV1.Asset storage asset = $.assets[tokenNorm];
        IPoolV1.RiskConfig storage risk = $.riskConfigs[tokenNorm];

        // Apply decay
        _applyDecay($, tokenNorm, asset);

        if ((risk.flags & C.FLASH_ENABLED_BIT) == 0) revert IErrors.FeatureDisabled(IErrors.Resource.FLASH);
        if ((risk.flags & C.FROZEN_BIT) != 0) revert IErrors.FeatureDisabled(IErrors.Resource.ASSET);
        if (amount == 0) revert IErrors.ZeroValue();
        if (asset.reserves < amount || asset.reserves - amount < asset.minLiquidity) {
            revert IErrors.InsufficientAmount(asset.reserves, amount);
        }

        uint256 fee = (amount * uint256($.feeParams.flashFeeBps)) / 1_000_000;
        uint8 protoShare = $.feeParams.protoShare;
        (uint256 protoFee, uint256 lpFee) = Pricing.splitFee(fee, protoShare);

        // Pre-flash loan hook (use normalized address for storage)
        address hook = _hook($, tokenNorm, C.HOOK_PRE_FLASH_LOAN);
        if (hook != address(0)) {
            IPoolHooks(hook).preFlashLoan(address(this), msg.sender, tokenNorm, amount, fee, data);
        }

        uint256 balanceBefore = _balanceOf(token);

        // Send loan (use original address for wrap/unwrap)
        _push(token, address(receiver), amount);

        // Callback with ERC-3156 magic value check (use original address)
        bytes32 result = receiver.postFlashLoan(msg.sender, token, amount, fee, data);
        if (result != keccak256("ERC3156FlashBorrower.postFlashLoan")) {
            revert IErrors.OperationFailed();
        }

        // Verify repayment: must return amount + fee
        uint256 balanceAfter = _balanceOf(token);
        if (balanceAfter < balanceBefore + amount + fee) revert IErrors.OperationFailed();

        // Update reserves (use normalized address for storage)
        asset.reserves = uint128(balanceAfter - protoFee);
        $.protocolFees[tokenNorm] += protoFee;

        // Post-flash loan hook (use normalized address for storage)
        hook = _hook($, tokenNorm, C.HOOK_POST_FLASH_LOAN);
        if (hook != address(0)) {
            IPoolHooks(hook).postFlashLoan(address(this), msg.sender, tokenNorm, amount, fee, data);
        }

        emit IFlashV1.FlashLoanExecuted(msg.sender, address(receiver), token, amount, fee);
        return true;
    }

    function maxFlashLoan(address token) external view override returns (uint256) {
        IPoolV1.PoolStorage storage $ = _s();
        // Normalize NATIVE to WETH for internal storage
        address tokenNorm = _wrap($, token);
        IPoolV1.Asset storage asset = $.assets[tokenNorm];
        IPoolV1.RiskConfig storage risk = $.riskConfigs[tokenNorm];

        // Return 0 if flash loans disabled or asset frozen
        if ((risk.flags & C.FLASH_ENABLED_BIT) == 0) return 0;
        if ((risk.flags & C.FROZEN_BIT) != 0) return 0;

        // Max is reserves - minLiquidity
        if (asset.reserves <= asset.minLiquidity) return 0;
        return uint256(asset.reserves - asset.minLiquidity);
    }

    function flashFee(address token, uint256 amount) external view override returns (uint256) {
        IPoolV1.PoolStorage storage $ = _s();
        return (amount * uint256($.feeParams.flashFeeBps)) / 1_000_000;
    }

    // Asset management functions (duplicated from Core - Flash needs _applyDecay)
}
