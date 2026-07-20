// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {PoolDecay} from "./PoolDecay.sol";
import {PoolIO} from "./PoolIO.sol";
import {PoolHooks} from "./PoolHooks.sol";

/// @title PoolEdge - flash-edge ops extracted from Pool.sol
/// @notice Wave-2 bytecode reduction. Pure refactor; behavior preserved.
///         `external` lib fns DELEGATECALL'd from Pool trampolines (auth +
///         reentrancy enforced at the trampoline).
library PoolEdge {
  function collectProtocolFees(IPool.PoolStorage storage $, address token, address recipient)
    external
    returns (uint256 amount)
  {
    address t = PoolIO.wrap($, token);
    amount = $.protocolFees[t];
    if (amount > 0) {
      $.protocolFees[t] = 0;
      PoolIO.push($, token, recipient, amount);
    }
  }

  function flashSend(IPool.PoolStorage storage $, address token, uint256 amount, address to)
    external
  {
    address t = PoolIO.wrap($, token);
    IPool.Asset storage asset = $.assets[t];
    if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
    PoolDecay.applyDecay(asset, $.riskConfigs[t]);
    if (amount == 0) revert Err.ZeroValue();
    // Executable flash capacity = R_liq (invested is not loanable without prior recall).
    uint256 liq = PoolHooks.liquidReserves($, t);
    if (liq < amount || liq - amount < asset.minLiquidity) {
      revert Err.InsufficientAmount(liq, amount);
    }
    // Block reserve-mutating entrypoints for the flash callback's duration (cleared in
    // flashAccount): a borrower must repay by plain transfer, not by deposit/swap which would
    // double-credit the principal pushed out here without a reserve debit.
    PoolIO.enterFlash();
    PoolIO.push($, token, to, amount);
  }

  function flashAccount(IPool.PoolStorage storage $, address token, uint256 fee, uint256 protoFee)
    external
  {
    if (protoFee > fee) revert Err.InvalidInput();
    address t = PoolIO.wrap($, token);
    IPool.Asset storage asset = $.assets[t];
    if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
    // ACC-05: bound the LP credit so a (proof-impossible) oversized fee cannot wrap uint128 reserves.
    uint256 lpFee = fee - protoFee;
    if (lpFee > type(uint128).max - asset.reserves) {
      revert Err.ExcessiveAmount(lpFee, type(uint128).max - asset.reserves);
    }
    // forge-lint: disable-next-line(unsafe-typecast) — bounded by the check above.
    asset.reserves += uint128(lpFee);
    $.protocolFees[t] += protoFee;
    PoolIO.exitFlash();
  }
}
