// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {YieldHook} from "./YieldHook.sol";
import {IMorphoBlue, MorphoId} from "../interfaces/external/IMorphoBlue.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title MorphoBlueYieldHook — isolated Morpho Blue / Lista Moolah–style markets (loan asset supply).
/// @notice Felix Vanilla vaults prefer ERC4626YieldHook; use this for direct Blue market allowlists.
/// @dev NAV uses Morpho SharesMathLib virtual shares/assets (toAssetsDown). Does not simulate IRM
///      interest accrual in view (would need IIrm.borrowRateView); harvest after market interaction
///      or accept lastUpdate-stale NAV. Full expectedSupplyAssets = accrue + virtual shares.
contract MorphoBlueYieldHook is YieldHook {
  using SafeTransferLib for address;
  using MorphoId for IMorphoBlue.MarketParams;

  /// @dev Morpho SharesMathLib constants.
  uint256 internal constant VIRTUAL_SHARES = 1e6;
  uint256 internal constant VIRTUAL_ASSETS = 1;

  IMorphoBlue public immutable morpho;
  IMorphoBlue.MarketParams public marketParams;
  bytes32 public immutable marketId;

  constructor(
    address ac_,
    address pool_,
    address token_,
    address morpho_,
    IMorphoBlue.MarketParams memory params_
  ) YieldHook(ac_, pool_, token_) {
    if (morpho_ == address(0)) revert Err.ZeroAddr();
    if (params_.loanToken != token_) revert Err.BadConfig();
    morpho = IMorphoBlue(morpho_);
    marketParams = params_;
    marketId = params_.id();
    // Morpho pulls via transferFrom
    token.safeApproveWithRetry(morpho_, type(uint256).max);
  }

  function _venueDeposit(uint256 assets) internal override {
    morpho.supply(marketParams, assets, 0, address(this), "");
  }

  function _venueWithdraw(uint256 assets) internal override returns (uint256) {
    (uint256 withdrawn,) = morpho.withdraw(marketParams, assets, 0, address(this), address(this));
    return withdrawn;
  }

  function _navAssets() internal view override returns (uint256) {
    (uint256 supplyShares,,) = morpho.position(marketId, address(this));
    if (supplyShares == 0) return 0;
    (uint128 totalSupplyAssets, uint128 totalSupplyShares,,,,) = morpho.market(marketId);
    // SharesMathLib.toAssetsDown (virtual shares); no IRM accrual in this view.
    return (supplyShares * (uint256(totalSupplyAssets) + VIRTUAL_ASSETS))
      / (uint256(totalSupplyShares) + VIRTUAL_SHARES);
  }

  function _maxWithdrawable() internal view override returns (uint256) {
    uint256 nav = _navAssets();
    (uint128 totalSupplyAssets,, uint128 totalBorrowAssets,,,) = morpho.market(marketId);
    uint256 liquidity = uint256(totalSupplyAssets) > uint256(totalBorrowAssets)
      ? uint256(totalSupplyAssets) - uint256(totalBorrowAssets)
      : 0;
    return nav < liquidity ? nav : liquidity;
  }
}
