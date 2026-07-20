// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IAaveV4Spoke} from "../../src/interfaces/external/IAaveV4.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title MockAaveV4Spoke - minimal reserveId supply stub for AaveV4YieldHook tests.
contract MockAaveV4Spoke is IAaveV4Spoke {
  using SafeTransferLib for address;

  mapping(uint256 => Reserve) internal _reserves;
  mapping(uint256 => mapping(address => uint256)) public suppliedAssets;

  function setReserve(uint256 reserveId, address underlying) external {
    _reserves[reserveId] = Reserve({
      underlying: underlying,
      hub: address(0),
      assetId: 0,
      decimals: 18,
      collateralRisk: 0,
      flags: 0,
      dynamicConfigKey: 0
    });
  }

  function getReserve(uint256 reserveId) external view override returns (Reserve memory) {
    return _reserves[reserveId];
  }

  function getUserSuppliedAssets(uint256 reserveId, address user)
    external
    view
    override
    returns (uint256)
  {
    return suppliedAssets[reserveId][user];
  }

  function supply(uint256 reserveId, uint256 amount, address onBehalfOf)
    external
    override
    returns (uint256 shares, uint256 assets)
  {
    address u = _reserves[reserveId].underlying;
    u.safeTransferFrom(msg.sender, address(this), amount);
    suppliedAssets[reserveId][onBehalfOf] += amount;
    return (amount, amount);
  }

  function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf)
    external
    override
    returns (uint256 shares, uint256 assets)
  {
    uint256 bal = suppliedAssets[reserveId][onBehalfOf];
    if (amount > bal) amount = bal;
    suppliedAssets[reserveId][onBehalfOf] = bal - amount;
    _reserves[reserveId].underlying.safeTransfer(msg.sender, amount);
    return (amount, amount);
  }
}
