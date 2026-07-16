// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {YieldHook} from "./YieldHook.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

interface IERC4626Minimal {
  function asset() external view returns (address);
  function deposit(uint256 assets, address receiver) external returns (uint256 shares);
  function withdraw(uint256 assets, address receiver, address owner)
    external
    returns (uint256 shares);
  function convertToAssets(uint256 shares) external view returns (uint256);
  function maxWithdraw(address owner) external view returns (uint256);
  function balanceOf(address account) external view returns (uint256);
}

/// @title ERC4626YieldHook — Morpho Vaults (Base/Robinhood/Felix Vanilla), Fluid fToken, sUSDS, Spark Savings.
contract ERC4626YieldHook is YieldHook {
  using SafeTransferLib for address;

  uint16 public constant MAX_DEPOSIT_LOSS_BPS = 1;

  IERC4626Minimal public immutable vault;

  constructor(address ac_, address pool_, address token_, address vault_)
    YieldHook(ac_, pool_, token_)
  {
    if (vault_ == address(0)) revert Err.ZeroAddr();
    if (IERC4626Minimal(vault_).asset() != token_) revert Err.BadConfig();
    vault = IERC4626Minimal(vault_);
  }

  function _venueDeposit(uint256 assets) internal override {
    uint256 sharesBefore = vault.balanceOf(address(this));
    token.safeApproveWithRetry(address(vault), assets);
    uint256 reportedShares = vault.deposit(assets, address(this));
    token.safeApproveWithRetry(address(vault), 0);
    uint256 sharesAfter = vault.balanceOf(address(this));
    if (sharesAfter <= sharesBefore) revert Err.ZeroValue();
    uint256 mintedShares = sharesAfter - sharesBefore;
    if (reportedShares != mintedShares) revert Err.BadConfig();
    uint256 minValue = (assets * (10_000 - MAX_DEPOSIT_LOSS_BPS)) / 10_000;
    uint256 valued = vault.convertToAssets(mintedShares);
    if (valued < minValue) revert Err.ThresholdViolation(valued, minValue);
  }

  function _venueWithdraw(uint256 assets) internal override returns (uint256) {
    vault.withdraw(assets, address(this), address(this));
    return assets;
  }

  function _navAssets() internal view override returns (uint256) {
    uint256 shares = vault.balanceOf(address(this));
    if (shares == 0) return 0;
    return vault.convertToAssets(shares);
  }

  function _maxWithdrawable() internal view override returns (uint256) {
    return vault.maxWithdraw(address(this));
  }

  function _positionToken() internal view override returns (address) {
    return address(vault);
  }
}
