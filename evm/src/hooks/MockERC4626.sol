// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title MockERC4626 — fixed-rate vault stub (Morpho Vault / sUSDS / Euler EVK tests).
/// @dev Default rate 1e18 (1:1). `setRate` scales convertToAssets = shares * rate / 1e18.
contract MockERC4626 {
    using SafeTransferLib for address;

    address public immutable asset;
    uint256 public rate = 1e18;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    error InsufficientLiquidity();

    constructor(address asset_) {
        if (asset_ == address(0)) revert Err.ZeroAddr();
        asset = asset_;
    }

    function setRate(uint256 rate_) external {
        if (rate_ == 0) revert Err.ZeroValue();
        rate = rate_;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        asset.safeTransferFrom(msg.sender, address(this), assets);
        shares = (assets * 1e18) / rate;
        balanceOf[receiver] += shares;
        totalSupply += shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = (assets * 1e18 + rate - 1) / rate; // ceil
        uint256 bal = balanceOf[owner];
        if (shares > bal) revert Err.InsufficientAmount(bal, shares);
        if (SafeTransferLib.balanceOf(asset, address(this)) < assets) revert InsufficientLiquidity();
        balanceOf[owner] = bal - shares;
        totalSupply -= shares;
        asset.safeTransfer(receiver, assets);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * rate) / 1e18;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        uint256 byShares = (balanceOf[owner] * rate) / 1e18;
        uint256 cash = SafeTransferLib.balanceOf(asset, address(this));
        return byShares < cash ? byShares : cash;
    }
}
