// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IBAMMHooks} from "../interfaces/IBAMMHooks.sol";
import {IERC3156FlashBorrower} from "../interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "../interfaces/IERC3156FlashLender.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {BAMMErrors as E} from "./BAMMEvents.sol";
import {BAMMEvents as Events} from "./BAMMEvents.sol";
import {LibStorage} from "../libraries/LibStorage.sol";
import {LibMaths as M} from "../libraries/LibMaths.sol";

/// @title BAMMFlashLender
/// @notice ERC-3156 compliant flash loan provider with multi-token support
/// @dev Extends ERC-3156 to support multiple tokens in a single flash loan
abstract contract BAMMFlashLender is IERC3156FlashLender, ReentrancyGuard {
    using SafeTransferLib for address;

    // ========== CONSTANTS ==========

    /// @dev keccak256("ERC3156FlashBorrower.onFlashLoan")
    bytes32 internal constant FLASH_LOAN_CALLBACK_SUCCESS = 0x439148f0bbc682ca079e46d6e2c2f0c1e3b820f1a291b069d8882abf8cf18dd9;

    // ========== STORAGE ACCESS (must be implemented by child) ==========

    /// @notice Get full storage struct (implemented by BAMM)
    function _s() internal pure virtual returns (LibStorage.BAMMStorage storage);

    /// @notice Get asset storage for given token (implemented by BAMM)
    function _getAsset(address token) internal view virtual returns (IBAMM.Asset storage);

    /// @notice Check if pool is paused (implemented by BAMM)
    function _isPoolPaused() internal view virtual returns (bool);

    // ========== ERC-3156 INTERFACE ==========

    /// @notice Maximum flash loan amount available for a token (ERC-3156)
    /// @param token Token address
    /// @return Maximum amount that can be borrowed (equals available reserves if enabled)
    function maxFlashLoan(address token) public view override returns (uint256) {
        IBAMM.Asset storage asset = _getAsset(token);

        // Return 0 if asset not registered, frozen, or flash loans disabled
        if (asset.segmentCount == 0) return 0;
        if (asset.isFrozen) return 0;
        if (!asset.flashLoanEnabled) return 0;

        // Maximum flash loan is the available reserve
        return asset.reserves;
    }

    /// @notice Flash loan fee for a given amount (ERC-3156)
    /// @param token Token address
    /// @param amount Loan amount
    /// @return Fee amount in token units
    function flashFee(address token, uint256 amount) public view override returns (uint256) {
        IBAMM.Asset storage asset = _getAsset(token);

        // Revert if flash loans not available
        if (asset.segmentCount == 0) revert E.AssetNotFound();
        if (asset.isFrozen) revert E.AssetFrozen();
        if (!asset.flashLoanEnabled) revert E.Unauthorized();
        if (amount > asset.reserves) revert E.InsufficientReserves();

        // Calculate fee: amount * flashFeeBps / BPS_PRECISION
        return (amount * asset.flashFeeBps) / M.BPS_PRECISION;
    }

    /// @notice Extended flash fee with custom borrower (non-standard, for compatibility)
    /// @param token Token address
    /// @param borrower Borrower address (unused in current implementation)
    /// @param amount Loan amount
    /// @return Fee amount in token units
    function flashFee(
        address token,
        address borrower,
        uint256 amount
    ) public view override returns (uint256) {
        // Borrower parameter ignored - all borrowers pay same fee
        borrower;
        return flashFee(token, amount);
    }

    /// @notice Execute a flash loan (ERC-3156)
    /// @param receiver Contract receiving the flash loan
    /// @param token Token to flash loan
    /// @param amount Amount to flash loan
    /// @param data Arbitrary data passed to receiver
    /// @return True if flash loan succeeds
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override nonReentrant returns (bool) {
        if (_isPoolPaused()) revert E.PoolPaused();

        IBAMM.Asset storage asset = _getAsset(token);

        // Validate flash loan is available
        if (asset.segmentCount == 0) revert E.AssetNotFound();
        if (asset.isFrozen) revert E.AssetFrozen();
        if (!asset.flashLoanEnabled) revert E.Unauthorized();
        if (amount == 0) revert E.ZeroAmount();
        if (amount > asset.reserves) revert E.InsufficientReserves();

        uint256 fee = flashFee(token, amount);
        uint128 reservesBefore = asset.reserves;

        // Call pre-flash loan hook if configured
        if (asset.hooks != address(0)) {
            IBAMMHooks(asset.hooks).preFlashLoan(token, address(receiver), amount, fee, data);
        }

        // Transfer tokens to receiver
        token.safeTransfer(address(receiver), amount);

        // Call receiver's callback
        bytes32 response = receiver.onFlashLoan(msg.sender, token, amount, fee, data);
        if (response != FLASH_LOAN_CALLBACK_SUCCESS) {
            revert E.FlashLoanCallbackFailed();
        }

        // Pull back principal + fee
        token.safeTransferFrom(address(receiver), address(this), amount + fee);

        // Ensure reserves increased by at least the fee
        uint256 balanceAfter = token.balanceOf(address(this));
        uint256 expectedBalance = uint256(reservesBefore) + fee;

        if (balanceAfter < expectedBalance) {
            revert E.InsufficientReserves();
        }

        // Update reserves to include fee
        asset.reserves = uint128(balanceAfter);

        // Call post-flash loan hook if configured
        if (asset.hooks != address(0)) {
            IBAMMHooks(asset.hooks).postFlashLoan(token, address(receiver), amount, fee, data);
        }

        emit FlashLoan(msg.sender, amount, fee);

        return true;
    }

    /// @notice Set maximum flash loan amount for a token (owner only, implemented by BAMM)
    function setMaxLoan(uint256) external pure override {
        // Not needed - max loan is always equal to reserves
        // This function exists for interface compatibility but does nothing
        revert E.InvalidParameter();
    }

    // ========== MULTI-TOKEN FLASH LOANS (EXTENSION) ==========

    /// @notice Execute a multi-token flash loan (non-standard extension)
    /// @dev Allows borrowing multiple tokens in a single transaction
    /// @param receiver Contract receiving the flash loan
    /// @param tokens Array of token addresses
    /// @param amounts Array of amounts (parallel to tokens)
    /// @param data Arbitrary data passed to receiver
    /// @return True if flash loan succeeds
    function batchFlashLoan(
        IERC3156FlashBorrower receiver,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes calldata data
    ) external nonReentrant returns (bool) {
        if (_isPoolPaused()) revert E.PoolPaused();
        if (tokens.length == 0) revert E.InvalidParameter();
        if (tokens.length != amounts.length) revert E.InvalidParameter();
        if (tokens.length > 16) revert E.InvalidParameter(); // Max 16 tokens per flash loan

        uint256 length = tokens.length;
        uint128[] memory reservesBefore = new uint128[](length);
        uint256[] memory fees = new uint256[](length);
        uint256 totalFeeValue = 0;

        // Phase 1: Validate and transfer all tokens
        for (uint256 i = 0; i < length; i++) {
            address token = tokens[i];
            uint256 amount = amounts[i];

            IBAMM.Asset storage asset = _getAsset(token);

            // Validate flash loan is available
            if (asset.segmentCount == 0) revert E.AssetNotFound();
            if (asset.isFrozen) revert E.AssetFrozen();
            if (!asset.flashLoanEnabled) revert E.Unauthorized();
            if (amount == 0) revert E.ZeroAmount();
            if (amount > asset.reserves) revert E.InsufficientReserves();

            // Calculate fee and store reserves
            fees[i] = flashFee(token, amount);
            reservesBefore[i] = asset.reserves;

            // Call pre-flash loan hook if configured
            if (asset.hooks != address(0)) {
                IBAMMHooks(asset.hooks).preFlashLoan(token, address(receiver), amount, fees[i], data);
            }

            // Transfer tokens to receiver
            token.safeTransfer(address(receiver), amount);

            totalFeeValue += fees[i];
        }

        // Phase 2: Call receiver's callback with first token (ERC-3156 compatible)
        bytes32 response = receiver.onFlashLoan(msg.sender, tokens[0], amounts[0], fees[0], data);
        if (response != FLASH_LOAN_CALLBACK_SUCCESS) {
            revert E.FlashLoanCallbackFailed();
        }

        // Phase 3: Pull back all tokens and verify reserves
        for (uint256 i = 0; i < length; i++) {
            address token = tokens[i];
            uint256 amount = amounts[i];
            uint256 fee = fees[i];

            // Pull back principal + fee
            token.safeTransferFrom(address(receiver), address(this), amount + fee);

            // Ensure reserves increased by at least the fee
            uint256 balanceAfter = token.balanceOf(address(this));
            uint256 expectedBalance = uint256(reservesBefore[i]) + fee;

            if (balanceAfter < expectedBalance) {
                revert E.InsufficientReserves();
            }

            // Update reserves to include fee
            IBAMM.Asset storage asset = _getAsset(token);
            asset.reserves = uint128(balanceAfter);

            // Call post-flash loan hook if configured
            if (asset.hooks != address(0)) {
                IBAMMHooks(asset.hooks).postFlashLoan(token, address(receiver), amount, fee, data);
            }

            emit FlashLoan(msg.sender, amount, fee);
        }

        return true;
    }

    /// @notice Get maximum flash loan amounts for multiple tokens
    /// @param tokens Array of token addresses
    /// @return amounts Array of maximum amounts (parallel to tokens)
    function maxBatchFlashLoan(address[] calldata tokens) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = maxFlashLoan(tokens[i]);
        }
    }

    /// @notice Get flash loan fees for multiple tokens
    /// @param tokens Array of token addresses
    /// @param amounts Array of loan amounts (parallel to tokens)
    /// @return fees Array of fee amounts (parallel to tokens)
    function batchFlashFee(
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external view returns (uint256[] memory fees) {
        if (tokens.length != amounts.length) revert E.InvalidParameter();

        fees = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            fees[i] = flashFee(tokens[i], amounts[i]);
        }
    }
}
