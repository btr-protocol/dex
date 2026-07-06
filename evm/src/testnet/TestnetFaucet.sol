// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Rate-limited testnet token drip. Fund via mint+transfer or `fund()` from deployer.
contract TestnetFaucet {
    using SafeTransferLib for address;

    uint256 public constant COOLDOWN = 1 hours;
    uint256 public constant DRIP = 10_000 ether;

    mapping(address user => mapping(address token => uint256)) public lastClaim;

    event Claimed(address indexed user, address indexed token, uint256 amount);

    function claim(address token) external {
        uint256 last = lastClaim[msg.sender][token];
        if (block.timestamp < last + COOLDOWN) revert("cooldown");
        lastClaim[msg.sender][token] = block.timestamp;
        token.safeTransfer(msg.sender, DRIP);
        emit Claimed(msg.sender, token, DRIP);
    }

    /// @dev Pull tokens from caller (deployer funds the faucet post-mint).
    function fund(address token, uint256 amount) external {
        token.safeTransferFrom(msg.sender, address(this), amount);
    }
}
