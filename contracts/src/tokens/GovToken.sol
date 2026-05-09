// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BridgeableERC20} from "./BridgeableERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Err} from "../Errors.sol";

/// @title GovToken
/// @notice Generic governance token with mint/burn and crosschain capabilities
/// @dev Owner should be set to Treasury module
///      Implements ERC7802 for standardized crosschain bridging
///      Name and symbol are parameterized for reusability
contract GovToken is BridgeableERC20, Ownable {
    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════
    // NB: Unauthorized() inherited from Solady's Ownable
    // NB: ZeroValue() will be used from IErrors if needed

    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Treasury module that defines the bridge
    address public immutable TREASURY;

    /// @notice Token name
    string private _name;

    /// @notice Token symbol
    string private _symbol;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Initialize governance token
    /// @param owner Treasury module address (also used for bridge lookup)
    /// @param tokenName Token name (e.g., "BTR Governance Token")
    /// @param tokenSymbol Token symbol (e.g., "BTR")
    constructor(address owner, string memory tokenName, string memory tokenSymbol) {
        if (owner == address(0)) revert Err.ZeroValue();
        if (bytes(tokenName).length == 0) revert Err.ZeroValue();
        if (bytes(tokenSymbol).length == 0) revert Err.ZeroValue();
        _initializeOwner(owner);
        TREASURY = owner;
        _name = tokenName;
        _symbol = tokenSymbol;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BRIDGEABLE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc BridgeableERC20
    function _getBridge() internal view override returns (address) {
        (bool success, bytes memory data) = TREASURY.staticcall(
            abi.encodeWithSignature("getBridge()")
        );
        if (success && data.length >= 32) {
            return abi.decode(data, (address));
        }
        return address(0);
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

    // ═══════════════════════════════════════════════════════════════════════════
    // MINT / BURN
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Mint governance tokens (owner only)
    /// @dev Owner should be Treasury module which enforces max supply
    /// @param to Recipient address
    /// @param amount Amount to mint
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Burn governance tokens
    /// @dev Anyone can burn their own tokens
    ///      If burning from another address, requires allowance
    /// @param from Address to burn from
    /// @param amount Amount to burn
    function burn(address from, uint256 amount) external {
        if (from != msg.sender) {
            _spendAllowance(from, msg.sender, amount);
        }
        _burn(from, amount);
    }
}
