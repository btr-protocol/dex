// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Aave V4 Spoke supply surface (official ISpoke: reserveId, not asset address).
/// @dev Mirrors https://github.com/aave/aave-v4/blob/main/src/spoke/interfaces/ISpoke.sol supply path.
///      Experimental until a live Spoke + reserveId is pinned; no mainnet address here yet.
interface IAaveV4Spoke {
  struct Reserve {
    address underlying;
    address hub;
    uint16 assetId;
    uint8 decimals;
    uint24 collateralRisk;
    uint8 flags;
    uint32 dynamicConfigKey;
  }

  function supply(uint256 reserveId, uint256 amount, address onBehalfOf)
    external
    returns (uint256 shares, uint256 assets);

  function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf)
    external
    returns (uint256 shares, uint256 assets);

  function getReserve(uint256 reserveId) external view returns (Reserve memory);

  function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);
}

/// @notice Optional rewards surface; shape may change before mainnet pin.
interface IAaveV4Rewards {
  function claimAllRewards(address[] calldata assets, address to)
    external
    returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
}
