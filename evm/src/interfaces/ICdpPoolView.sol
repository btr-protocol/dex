// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @dev Minimal pool surface for CDP valuation.
interface ICdpPoolView {
  function previewWithdrawFresh(address token, uint256 lp)
    external
    view
    returns (uint256 amountOut, uint256 haircut);

  function getAssetHook(address token) external view returns (address target, uint32 flags);

  function getRiskFlags(address token) external view returns (uint16);

  function liquidityIndex(address token) external view returns (uint256);

  function maxRedeem(address holder, address token) external view returns (uint256);

  function markFeed(address token)
    external
    view
    returns (address primary, bytes32 feedId, uint8 mode);

  function assetDecimals(address token) external view returns (uint8);
}
