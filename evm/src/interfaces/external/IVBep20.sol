// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title IVBep20 — Venus Core / Compound-like vToken surface (mint / redeemUnderlying).
interface IVBep20 {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function getCash() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function underlying() external view returns (address);
}
