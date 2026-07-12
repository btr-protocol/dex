// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IVBep20} from "../interfaces/external/IVBep20.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title MockVenus — Compound-like vToken stub for Chapel / unit tests (BTR mock underlyings).
/// @dev Fixed 1:1 exchange rate. Cash = contract underlying balance. No interest unless `setRate`.
contract MockVenus is IVBep20 {
    using SafeTransferLib for address;

    address public immutable override underlying;
    uint256 public rate = 1e18; // exchangeRateStored
    mapping(address => uint256) public override balanceOf;
    uint256 public totalSupply;
    uint256 public override totalReserves;

    error InsufficientCash();

    constructor(address underlying_) {
        if (underlying_ == address(0)) revert Err.ZeroAddr();
        underlying = underlying_;
    }

    function setRate(uint256 rate_) external {
        if (rate_ == 0) revert Err.ZeroValue();
        rate = rate_;
    }

    function setTotalReserves(uint256 r) external {
        totalReserves = r;
    }

    function exchangeRateStored() external view override returns (uint256) {
        return rate;
    }

    function getCash() public view override returns (uint256) {
        return SafeTransferLib.balanceOf(underlying, address(this));
    }

    function mint(uint256 mintAmount) external override returns (uint256) {
        underlying.safeTransferFrom(msg.sender, address(this), mintAmount);
        uint256 shares = (mintAmount * 1e18) / rate;
        balanceOf[msg.sender] += shares;
        totalSupply += shares;
        return 0;
    }

    function redeem(uint256 redeemTokens) external override returns (uint256) {
        uint256 amt = (redeemTokens * rate) / 1e18;
        return _redeem(msg.sender, redeemTokens, amt);
    }

    function redeemUnderlying(uint256 redeemAmount) external override returns (uint256) {
        uint256 shares = (redeemAmount * 1e18 + rate - 1) / rate; // ceil
        return _redeem(msg.sender, shares, redeemAmount);
    }

    function _redeem(address user, uint256 shares, uint256 amt) private returns (uint256) {
        if (shares > balanceOf[user]) revert Err.InsufficientAmount(balanceOf[user], shares);
        // Venus/Compound redeemUnderlying checks getCash() only (not cash − reserves).
        if (getCash() < amt) revert InsufficientCash();
        balanceOf[user] -= shares;
        totalSupply -= shares;
        underlying.safeTransfer(user, amt);
        return 0;
    }
}
