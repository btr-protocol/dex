// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {YieldHook} from "./YieldHook.sol";
import {
  IAaveV3Pool,
  IAaveAToken,
  IAaveRewardsController,
  AaveReserveData
} from "../interfaces/external/IAaveV3.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title AaveV3YieldHook - Aave V3 / SparkLend / HyperLend (same Pool ABI).
contract AaveV3YieldHook is YieldHook {
  using SafeTransferLib for address;

  IAaveV3Pool public immutable aavePool;
  IAaveAToken public immutable aToken;
  IAaveRewardsController public immutable rewards; // optional; address(0) = none

  constructor(address ac_, address pool_, address token_, address aavePool_, address rewards_)
    YieldHook(ac_, pool_, token_)
  {
    if (aavePool_ == address(0)) revert Err.ZeroAddr();
    aavePool = IAaveV3Pool(aavePool_);
    AaveReserveData memory rd = IAaveV3Pool(aavePool_).getReserveData(token_);
    if (rd.aTokenAddress == address(0)) revert Err.BadConfig();
    aToken = IAaveAToken(rd.aTokenAddress);
    if (aToken.UNDERLYING_ASSET_ADDRESS() != token_) revert Err.BadConfig();
    rewards = IAaveRewardsController(rewards_);
  }

  function _venueDeposit(uint256 assets) internal override {
    token.safeApproveWithRetry(address(aavePool), assets);
    aavePool.supply(token, assets, address(this), 0);
    token.safeApproveWithRetry(address(aavePool), 0);
  }

  function _venueWithdraw(uint256 assets) internal override returns (uint256) {
    return aavePool.withdraw(token, assets, address(this));
  }

  function _navAssets() internal view override returns (uint256) {
    return aToken.balanceOf(address(this)); // already underlying units
  }

  function _maxWithdrawable() internal view override returns (uint256) {
    // Aave withdraw fails if liquidity insufficient; balance is upper bound.
    return aToken.balanceOf(address(this));
  }

  function _positionToken() internal view override returns (address) {
    return address(aToken);
  }

  function _claimVenueIncentives(bytes calldata data) internal override {
    if (address(rewards) == address(0)) return;
    // data = abi.encode(address[] assets) or empty → claim aToken only
    address[] memory assets;
    if (data.length == 0) {
      assets = new address[](1);
      assets[0] = address(aToken);
    } else {
      assets = abi.decode(data, (address[]));
    }
    rewards.claimAllRewards(assets, address(this));
  }
}
