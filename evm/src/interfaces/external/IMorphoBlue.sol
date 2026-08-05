// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @notice Morpho Blue singleton — supply loan asset only (idle farm).
interface IMorphoBlue {
  struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
  }

  function supply(
    MarketParams memory marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes calldata data
  ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);

  function withdraw(
    MarketParams memory marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver
  ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

  function accrueInterest(MarketParams memory marketParams) external;

  function position(bytes32 id, address user)
    external
    view
    returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);

  function market(bytes32 id)
    external
    view
    returns (
      uint128 totalSupplyAssets,
      uint128 totalSupplyShares,
      uint128 totalBorrowAssets,
      uint128 totalBorrowShares,
      uint128 lastUpdate,
      uint128 fee
    );

  function idToMarketParams(bytes32 id) external view returns (MarketParams memory);
}

/// @notice Morpho Blue market id = keccak256 over packed memory (5×32), not abi.encode.
/// @dev Matches morpho-blue MarketParamsLib / IdLib.
library MorphoId {
  uint256 internal constant MARKET_PARAMS_BYTES_LENGTH = 5 * 32;

  function id(IMorphoBlue.MarketParams memory marketParams)
    internal
    pure
    returns (bytes32 marketParamsId)
  {
    assembly ("memory-safe") {
      marketParamsId := keccak256(marketParams, MARKET_PARAMS_BYTES_LENGTH)
    }
  }
}
