// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title ChainMeta — base for chain-specific metadata
abstract contract ChainMeta {
    struct TokenMeta {
        address gov;   // Governance token
        address wgas;  // Wrapped native gas token
        address usdt;
        address usdc;
        address weth;
        address wbtc;
        address bnb;
    }

    function __id() public pure virtual returns (string memory);
    function __expectedChainIds() public pure virtual returns (uint256[] memory);
    function __tokens() public pure virtual returns (TokenMeta memory);
}
