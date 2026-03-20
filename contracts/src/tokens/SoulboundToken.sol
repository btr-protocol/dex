// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {IErrors} from "../interfaces/IErrors.sol";

/// @title SoulboundToken
/// @notice Non-transferable ERC20-like token for points campaigns
/// @dev All transfer/approve operations revert. Only minter (DistributorV1) can mint/burn.
contract SoulboundToken is ERC20 {
    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error NonTransferable();

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    string private _name;
    string private _symbol;
    address public immutable minter;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploy soulbound token
    /// @param name_ Token name (e.g., "Pre-BTR Points")
    /// @param symbol_ Token symbol (e.g., "pBTR")
    /// @param minter_ Address authorized to mint/burn (DistributorV1, immutable)
    constructor(string memory name_, string memory symbol_, address minter_) {
        _name = name_;
        _symbol = symbol_;
        minter = minter_;
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

    // ═══════════════════════════════════════════════════════════════════════════
    // NON-TRANSFERABLE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Transfer is disabled (soulbound)
    function transfer(address, uint256) public pure override returns (bool) {
        revert NonTransferable();
    }

    /// @notice TransferFrom is disabled (soulbound)
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert NonTransferable();
    }

    /// @notice Approve is disabled (soulbound)
    function approve(address, uint256) public pure override returns (bool) {
        revert NonTransferable();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MINTING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Mint points to a user (minter only)
    /// @param to Recipient address
    /// @param amount Amount to mint
    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert Ownable.Unauthorized();
        _mint(to, amount);
    }

    /// @notice Burn points from a user (minter only)
    /// @param from Address to burn from
    /// @param amount Amount to burn
    function burn(address from, uint256 amount) external {
        if (msg.sender != minter) revert Ownable.Unauthorized();
        _burn(from, amount);
    }
}
