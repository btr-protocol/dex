// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StakedToken} from "./StakedToken.sol";

/// @title StakedGov
/// @notice Non-transferable ERC20 receipt token for staked governance tokens
/// @dev Single global token, balances managed by Staking module
///      Provides claim power boost and earns 5% of protocol emissions
///      Cannot be bridged - governance staking is chain-specific
///      Name and symbol are parameterized for reusability
contract StakedGov is StakedToken {
    /// @notice Token name
    string private _name;

    /// @notice Token symbol
    string private _symbol;

    /// @notice Initialize staked governance token
    /// @param _staking Staking module address
    /// @param _gov Governance token address
    /// @param tokenName Token name (e.g., "Staked BTR")
    /// @param tokenSymbol Token symbol (e.g., "sBTR")
    constructor(
        address _staking,
        address _gov,
        string memory tokenName,
        string memory tokenSymbol
    ) StakedToken(_staking, _gov) {
        _name = tokenName;
        _symbol = tokenSymbol;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERC20 METADATA
    // ═══════════════════════════════════════════════════════════════════════════

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
