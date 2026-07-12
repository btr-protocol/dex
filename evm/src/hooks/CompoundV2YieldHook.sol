// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {YieldHook} from "./YieldHook.sol";
import {ICToken} from "../interfaces/external/ICToken.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title CompoundV2YieldHook — Venus / Moonwell / Flux / Benqi (cToken family).
/// @dev mint/redeemUnderlying return 0 on success (Compound/Venus). Some forks revert instead —
///      both paths work when err==0 or no return (we always check return code).
contract CompoundV2YieldHook is YieldHook {
    using SafeTransferLib for address;

    ICToken public immutable cToken;

    error CTokenMintFailed(uint256 err);
    error CTokenRedeemFailed(uint256 err);

    constructor(address ac_, address pool_, address token_, address cToken_)
        YieldHook(ac_, pool_, token_)
    {
        if (cToken_ == address(0)) revert Err.ZeroAddr();
        if (ICToken(cToken_).underlying() != token_) revert Err.BadConfig();
        cToken = ICToken(cToken_);
    }

    function _venueDeposit(uint256 assets) internal override {
        token.safeApproveWithRetry(address(cToken), assets);
        uint256 err = cToken.mint(assets);
        token.safeApproveWithRetry(address(cToken), 0);
        if (err != 0) revert CTokenMintFailed(err);
    }

    function _venueWithdraw(uint256 assets) internal override returns (uint256) {
        uint256 err = cToken.redeemUnderlying(assets);
        if (err != 0) revert CTokenRedeemFailed(err);
        return assets;
    }

    function _navAssets() internal view override returns (uint256) {
        uint256 shares = cToken.balanceOf(address(this));
        if (shares == 0) return 0;
        return (shares * cToken.exchangeRateStored()) / 1e18;
    }

    function _maxWithdrawable() internal view override returns (uint256) {
        uint256 shares = cToken.balanceOf(address(this));
        if (shares == 0) return 0;
        uint256 byShares = (shares * cToken.exchangeRateStored()) / 1e18;
        // Venus/Compound redeemUnderlying only checks getCash(), not cash − reserves.
        uint256 cash = cToken.getCash();
        return byShares < cash ? byShares : cash;
    }

    function _positionToken() internal view override returns (address) {
        return address(cToken);
    }
}
