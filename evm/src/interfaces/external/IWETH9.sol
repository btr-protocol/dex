// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

interface IWETH9 {
  function deposit() external payable;
  function withdraw(uint256) external;
  function balanceOf(address) external view returns (uint256);
  function transfer(address to, uint256 amount) external returns (bool);
}
