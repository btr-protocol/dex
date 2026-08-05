// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Err} from "@btr-shared/Errors.sol";
import {ICdp} from "./interfaces/ICdp.sol";
import {IDebtToken} from "./interfaces/IDebtToken.sol";

contract DebtToken is ERC20, IDebtToken {
  address public immutable engine;
  ICdp.Denom public immutable override denom;

  string private _name;
  string private _symbol;

  constructor(string memory name_, string memory symbol_, ICdp.Denom denom_, address engine_) {
    if (engine_ == address(0)) revert Err.ZeroAddr();
    _name = name_;
    _symbol = symbol_;
    denom = denom_;
    engine = engine_;
  }

  function name() public view override returns (string memory) {
    return _name;
  }

  function symbol() public view override returns (string memory) {
    return _symbol;
  }

  function decimals() public pure override returns (uint8) {
    return 18;
  }

  function mint(address to, uint256 amount) external override {
    if (msg.sender != engine) revert Err.NotAuth();
    _mint(to, amount);
  }

  function burn(address from, uint256 amount) external override {
    if (msg.sender != engine) revert Err.NotAuth();
    _burn(from, amount);
  }
}
