// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {TestnetERC20} from "./TestnetERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice The native leg's mock: TestnetERC20 plus the WETH9 surface `PoolIO` calls.
/// @dev The NATIVE sentinel routes through `PoolIO.wrap` to `$.wnative`, and `pull`/`push` then call
///      `deposit()` / `withdraw()` on it. A plain TestnetERC20 has neither, so a pool whose wnative
///      is one cannot take or return native ETH at all (Sepolia, until this contract). Only the
///      native leg needs this; every other mock stays a plain TestnetERC20.
/// @dev TESTNET ARTIFACT, deliberately not a real WETH9: `mint` is retained so the ceremony can seed
///      a leg far larger than the deployer's ETH, which means supply is NOT fully ETH-backed and
///      `withdraw` is only payable out of what was actually deposited. Native unwrap therefore
///      reverts once withdrawals exceed deposits. Never deploy this on a chain that settles value.
contract TestnetWETH9 is TestnetERC20 {
  constructor(string memory name_, string memory symbol_, uint8 decimals_)
    TestnetERC20(name_, symbol_, decimals_)
  {}

  function deposit() public payable {
    _mint(msg.sender, msg.value);
  }

  function withdraw(uint256 amount) external {
    _burn(msg.sender, amount);
    SafeTransferLib.safeTransferETH(msg.sender, amount);
  }

  receive() external payable {
    deposit();
  }
}
