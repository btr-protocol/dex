// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {YieldHook} from "./YieldHook.sol";
import {IAaveV4Spoke, IAaveV4Rewards} from "../interfaces/external/IAaveV4.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title AaveV4YieldHook - EXPERIMENTAL Aave V4 Spoke supply-only (official reserveId ABI).
/// @dev Experimental: no mainnet Spoke / reserveId pin. Not production-ready. Positions are
///      share-ledger on Spoke (no aToken ERC20). Quarantine until pins land.
contract AaveV4YieldHook is YieldHook {
  using SafeTransferLib for address;

  IAaveV4Spoke public immutable spoke;
  uint256 public immutable reserveId;
  IAaveV4Rewards public immutable rewards; // optional

  constructor(
    address ac_,
    address pool_,
    address token_,
    address spoke_,
    uint256 reserveId_,
    address rewards_
  ) YieldHook(ac_, pool_, token_) {
    if (spoke_ == address(0)) revert Err.ZeroAddr();
    spoke = IAaveV4Spoke(spoke_);
    reserveId = reserveId_;
    if (spoke.getReserve(reserveId_).underlying != token_) revert Err.BadConfig();
    rewards = IAaveV4Rewards(rewards_);
  }

  function _venueDeposit(uint256 assets) internal override {
    token.safeApproveWithRetry(address(spoke), assets);
    spoke.supply(reserveId, assets, address(this));
    token.safeApproveWithRetry(address(spoke), 0);
  }

  function _venueWithdraw(uint256 assets) internal override returns (uint256) {
    (, uint256 withdrawn) = spoke.withdraw(reserveId, assets, address(this));
    return withdrawn;
  }

  function _navAssets() internal view override returns (uint256) {
    return spoke.getUserSuppliedAssets(reserveId, address(this));
  }

  function _maxWithdrawable() internal view override returns (uint256) {
    return spoke.getUserSuppliedAssets(reserveId, address(this));
  }

  function _claimVenueIncentives(bytes calldata data) internal override {
    if (address(rewards) == address(0)) return;
    address[] memory assets;
    if (data.length == 0) {
      assets = new address[](1);
      assets[0] = token;
    } else {
      assets = abi.decode(data, (address[]));
    }
    rewards.claimAllRewards(assets, address(this));
  }
}
