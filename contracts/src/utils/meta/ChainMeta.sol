// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/*
 * @title Chain Metadata Base
 * @copyright 2025
 * @author BTR Team
 */

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

    /// @notice Chain identifier string (e.g., "bnb_chain", "ethereum")
    function __id() public pure virtual returns (string memory);

    /// @notice Expected chain IDs (mainnet, testnet, local fork)
    function __expectedChainIds() public pure virtual returns (uint256[] memory);

    /// @notice Standard token addresses for this chain
    function __tokens() public pure virtual returns (TokenMeta memory);
}
