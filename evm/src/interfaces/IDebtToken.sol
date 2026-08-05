// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {ICdp} from "./ICdp.sol";

interface IDebtToken {
  function mint(address to, uint256 amount) external;
  function burn(address from, uint256 amount) external;
  function denom() external view returns (ICdp.Denom);
}
