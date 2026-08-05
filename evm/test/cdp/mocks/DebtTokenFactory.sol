// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Err} from "@btr-shared/Errors.sol";
import {ICdp} from "../../../src/interfaces/ICdp.sol";
import {DebtToken} from "../../../src/DebtToken.sol";

contract DebtTokenFactory {
  function deploySuite(address engine)
    external
    returns (address btrUSD, address btrBTC, address btrETH, address btrGOLD)
  {
    if (engine == address(0)) revert Err.ZeroAddr();
    btrUSD = address(new DebtToken("BTR USD", "btrUSD", ICdp.Denom.USD, engine));
    btrBTC = address(new DebtToken("BTR BTC", "btrBTC", ICdp.Denom.BTC, engine));
    btrETH = address(new DebtToken("BTR ETH", "btrETH", ICdp.Denom.ETH, engine));
    btrGOLD = address(new DebtToken("BTR GOLD", "btrGOLD", ICdp.Denom.GOLD, engine));
  }
}
