// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {YieldHook} from "./YieldHook.sol";
import {ICToken} from "../interfaces/external/ICToken.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title CompoundV2YieldHook - Venus / Moonwell / Flux / Benqi (cToken family).
/// @dev Supports the standard Compound/Venus ABI whose mint/redeemUnderlying return 0 on success.
///      No-return forks are incompatible and must use a dedicated adapter.
contract CompoundV2YieldHook is YieldHook {
  using SafeTransferLib for address;

  ICToken public immutable cToken;
  /// @notice Reward controller (Comptroller / MultiRewardDistributor). address(0) = no rewards (no-op).
  address public immutable comptroller;
  /// @notice Reward-claim selector, configurable per fork (all take `(holder, cToken[])`):
  ///         Venus `claimVenus(address,address[])` 0x86df31ee · Compound `claimComp(address,address[])`
  ///         0x1c3db2e0 · Moonwell/Benqi `claimReward(address,address[])` 0x3685ffe7. bytes4(0) = no-op.
  bytes4 public immutable claimSelector;

  error CTokenMintFailed(uint256 err);
  error CTokenRedeemFailed(uint256 err);
  error ClaimFailed();

  constructor(
    address ac_,
    address pool_,
    address token_,
    address cToken_,
    address comptroller_,
    bytes4 claimSelector_
  ) YieldHook(ac_, pool_, token_) {
    if (cToken_ == address(0)) revert Err.ZeroAddr();
    if (ICToken(cToken_).underlying() != token_) revert Err.BadConfig();
    cToken = ICToken(cToken_);
    comptroller = comptroller_;
    claimSelector = claimSelector_;
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
    uint256 nav = _navAssets();
    uint256 cash = cToken.getCash();
    return nav < cash ? nav : cash;
  }

  function _positionToken() internal view override returns (address) {
    return address(cToken);
  }

  /// @notice Native Comptroller reward claim → reward token (XVS/WELL/QI/COMP) lands on the hook.
  /// @dev `data` ignored (native, no proofs). No-op when reward source unset. Selector picks the fork.
  function _claimVenueIncentives(bytes calldata) internal override {
    if (comptroller == address(0) || claimSelector == bytes4(0)) return;
    address[] memory cTokens = new address[](1);
    cTokens[0] = address(cToken);
    (bool ok,) = comptroller.call(abi.encodeWithSelector(claimSelector, address(this), cTokens));
    if (!ok) revert ClaimFailed();
  }
}
