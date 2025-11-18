// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "./IBAMM.sol";
import {IInternalOracle} from "./IInternalOracle.sol";

/// @title IBAMMCore
/// @notice Core interface for lean BAMMCore contract
/// @dev Includes only hot-path user-facing functions
interface IBAMMCore {

    // ========== LP TOKEN ORACLE FUNCTIONS ==========
    /// @notice Get LP token balance for account (rebased)
    function lpBalanceOf(address asset, address account) external view returns (uint256);

    /// @notice Get total LP token supply (rebased)
    function lpTotalSupply(address asset) external view returns (uint256);

    /// @notice Transfer LP tokens internally (called by LP token contract)
    function lpTransfer(address asset, address from, address to, uint256 amount) external;

    /// @notice Mint LP tokens (called by deposit)
    function lpMint(address asset, address to, uint256 amount) external;

    /// @notice Burn LP tokens (called by withdraw)
    function lpBurn(address asset, address from, uint256 amount) external;

    // ========== VIEW FUNCTIONS ==========
    function getAsset(address token) external view returns (IBAMM.Asset memory);
    function getLPState(address token) external view returns (IBAMM.LPState memory);
    function getOracleSnapshot(address token) external view returns (
        uint64 fastEMA,
        uint64 slowEMA,
        uint32 fastVolEMA,
        uint32 slowVolEMA,
        uint32 updatedAt
    );
}
