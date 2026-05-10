// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {StakedToken} from "./StakedToken.sol";

/// @title StakedGov
/// @notice Soulbound receipt for staked gov tokens; chain-local; earns 5% emissions
contract StakedGov is StakedToken {
    string private _name;
    string private _symbol;

    constructor(
        address _staking,
        address _gov,
        address _pool,
        string memory tokenName,
        string memory tokenSymbol
    ) StakedToken(_staking, _gov, _pool) {
        _name = tokenName;
        _symbol = tokenSymbol;
    }

    function name() public view override returns (string memory) { return _name; }
    function symbol() public view override returns (string memory) { return _symbol; }
    function decimals() public pure override returns (uint8) { return 18; }
}
