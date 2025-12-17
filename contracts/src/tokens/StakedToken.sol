// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {IErrors} from "../interfaces/IErrors.sol";
import {IStakingV1} from "../interfaces/modules/IStakingV1.sol";

/// @title StakedToken
/// @notice Abstract base for staked tokens (sGov, sLP)
/// @dev Balances managed by Staking module, token queries them
///      Non-transferable (soulbound) receipt tokens
///      Tokens can only be staked on their native chain (no bridging)
abstract contract StakedToken is ERC20 {
    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Staking module that manages balances
    address public immutable STAKING;

    /// @notice Underlying token address (BTR or LP asset)
    address public immutable UNDERLYING;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════
    // Using Unauthorized() (from Solady's Ownable) and IErrors.InvalidState() for error handling

    error Unauthorized();

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address _staking, address _underlying) {
        STAKING = _staking;
        UNDERLYING = _underlying;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BALANCE QUERIES (Delegated to Staking module)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Get balance from Staking module via typed interface
    function balanceOf(address account) public view virtual override returns (uint256) {
        try IStakingV1(STAKING).getStakedBalance(account, UNDERLYING) returns (uint256 balance) {
            return balance;
        } catch {
            return 0;
        }
    }

    /// @notice Get total supply from Staking module via typed interface
    function totalSupply() public view virtual override returns (uint256) {
        try IStakingV1(STAKING).getTotalStaked(UNDERLYING) returns (uint256 supply) {
            return supply;
        } catch {
            return 0;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TRANSFER RESTRICTIONS (Soulbound Receipt Tokens)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Transfers are disabled - staked tokens are non-transferable receipts
    /// @dev Users must unstake via StakingV1 to move underlying assets
    function transfer(address, uint256) public pure override returns (bool) {
        revert IErrors.FeatureDisabled(IErrors.Resource.TRANSFER);
    }

    /// @notice Transfers are disabled - staked tokens are non-transferable receipts
    /// @dev Users must unstake via StakingV1 to move underlying assets
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert IErrors.FeatureDisabled(IErrors.Resource.TRANSFER);
    }

    /// @notice Allowances are disabled since transfers are disabled
    function approve(address, uint256) public pure override returns (bool) {
        revert IErrors.FeatureDisabled(IErrors.Resource.TRANSFER);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL OVERRIDES (Balance tracking delegated)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Update balances (delegated to Staking module)
    /// @dev Only mint/burn operations are allowed (from/to == address(0))
    ///      Regular transfers are blocked at public function level
    function _update(address from, address to, uint256 amount) internal virtual {
        // Only Staking module can trigger mint/burn
        if (msg.sender != STAKING) revert Unauthorized();

        // Enforce mint/burn only (no transfers)
        if (from != address(0) && to != address(0)) {
            revert IErrors.FeatureDisabled(IErrors.Resource.TRANSFER);
        }

        // Emit Transfer event for ERC20 compliance
        // Actual balances are managed by StakingV1
        emit Transfer(from, to, amount);
    }
}
