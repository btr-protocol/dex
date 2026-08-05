// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IAaveV3Pool, IAaveAToken, AaveReserveData} from "../../src/interfaces/external/IAaveV3.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title MockAToken - 1:1 aToken stub (balance = underlying units).
contract MockAToken is IAaveAToken {
  using SafeTransferLib for address;

  address public immutable override UNDERLYING_ASSET_ADDRESS;
  mapping(address => uint256) public override balanceOf;
  mapping(address => uint256) public override scaledBalanceOf;

  constructor(address underlying_) {
    if (underlying_ == address(0)) revert Err.ZeroAddr();
    UNDERLYING_ASSET_ADDRESS = underlying_;
  }

  function mint(address to, uint256 amt) external {
    balanceOf[to] += amt;
    scaledBalanceOf[to] += amt;
  }

  function burn(address from, uint256 amt) external {
    uint256 bal = balanceOf[from];
    if (amt > bal) revert Err.InsufficientAmount(bal, amt);
    balanceOf[from] = bal - amt;
    scaledBalanceOf[from] = bal - amt;
  }

  /// @dev Test helper: release underlying held on this aToken (real Aave cash location).
  function pushUnderlying(address to, uint256 amt) external {
    UNDERLYING_ASSET_ADDRESS.safeTransfer(to, amt);
  }
}

  /// @title MockAavePool - Aave V3 Pool stub for supply-only tests.
  contract MockAavePool is IAaveV3Pool {
    using SafeTransferLib for address;

    mapping(address => address) public aTokenOf;

    function setAToken(address asset, address aToken) external {
      aTokenOf[asset] = aToken;
    }

    function getReserveData(address asset)
      external
      view
      override
      returns (AaveReserveData memory rd)
    {
      rd.aTokenAddress = aTokenOf[asset];
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
      address a = aTokenOf[asset];
      if (a == address(0)) revert Err.BadConfig();
      // Real Aave V3 holds underlying on the aToken; keep cash there so `_maxWithdrawable` matches.
      asset.safeTransferFrom(msg.sender, a, amount);
      MockAToken(a).mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to)
      external
      override
      returns (uint256)
    {
      address a = aTokenOf[asset];
      if (a == address(0)) revert Err.BadConfig();
      uint256 bal = MockAToken(a).balanceOf(msg.sender);
      uint256 cash = asset.balanceOf(a);
      uint256 amt = amount > bal ? bal : amount;
      if (amt > cash) amt = cash;
      MockAToken(a).burn(msg.sender, amt);
      MockAToken(a).pushUnderlying(to, amt);
      return amt;
    }
  }
