// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Compound V2–family cToken / vToken / mToken / qToken / fToken (Flux) surface.
/// @dev Venus returns uint error codes; classic Compound reverts on failure. Adapters handle both.
interface ICToken {
  function mint(uint256 mintAmount) external returns (uint256);
  function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
  function exchangeRateStored() external view returns (uint256);
  function balanceOf(address account) external view returns (uint256);
  function getCash() external view returns (uint256);
  function totalReserves() external view returns (uint256);
  function underlying() external view returns (address);
}
