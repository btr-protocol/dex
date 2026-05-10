// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {StakedToken} from "./StakedToken.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/// @title StakedLP (sLP)
/// @notice Soulbound receipt for staked LP positions; cloneable; chain-local
contract StakedLP is StakedToken {
    constructor(address _staking, address _underlying, address _pool) StakedToken(_staking, _underlying, _pool) {}

    function name() public view override returns (string memory) {
        try ERC20(UNDERLYING).name() returns (string memory n) { return string(abi.encodePacked("Staked ", n)); } catch { return "Staked LP"; }
    }

    function symbol() public view override returns (string memory) {
        try ERC20(UNDERLYING).symbol() returns (string memory s) { return string(abi.encodePacked("s", s)); } catch { return "sLP"; }
    }

    function decimals() public view override returns (uint8) {
        try ERC20(UNDERLYING).decimals() returns (uint8 d) { return d; } catch { return 18; }
    }
}
