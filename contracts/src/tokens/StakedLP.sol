// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StakedToken} from "./StakedToken.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {IErrors} from "../interfaces/IErrors.sol";

/// @title StakedLP (sLP)
/// @notice Non-transferable ERC20 receipt token for staked LP positions
/// @dev Cloneable via Solady's LibClone for gas-efficient per-asset deployment
///      Balances managed by Staking module
///      Cannot be bridged - LP staking is chain-specific
contract StakedLP is StakedToken {
    /// @notice Initialize sLP token
    /// @param _staking Staking module address
    /// @param _underlying Underlying LP token address
    constructor(address _staking, address _underlying, address /* _pool */) StakedToken(_staking, _underlying) {
        // Pool parameter kept for compatibility with existing CREATE3 deployments
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERC20 METADATA (Dynamic based on underlying)
    // ═══════════════════════════════════════════════════════════════════════════

    function name() public view override returns (string memory) {
        try ERC20(UNDERLYING).name() returns (string memory underlyingName) {
            return string(abi.encodePacked("Staked ", underlyingName));
        } catch {
            return "Staked LP";
        }
    }

    function symbol() public view override returns (string memory) {
        try ERC20(UNDERLYING).symbol() returns (string memory underlyingSymbol) {
            return string(abi.encodePacked("s", underlyingSymbol));
        } catch {
            return "sLP";
        }
    }

    function decimals() public view override returns (uint8) {
        try ERC20(UNDERLYING).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }
}
