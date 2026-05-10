// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Err} from "@btr-shared/Errors.sol";
import {IStaking} from "../interfaces/IStaking.sol";

/// @title StakedToken
/// @notice Abstract base for soulbound staked receipt tokens (sGov, sLP)
/// @dev Balances delegated to Staking singleton; non-transferable; chain-local
abstract contract StakedToken is ERC20 {
    /// @notice Staking singleton that manages balances
    address public immutable STAKING;
    /// @notice Underlying token address (BTR or LP asset)
    address public immutable UNDERLYING;
    /// @notice Pool that owns this sToken (key for the singleton's per-pool state).
    address public immutable POOL;

    constructor(address _staking, address _underlying, address _pool) {
        STAKING = _staking;
        UNDERLYING = _underlying;
        POOL = _pool;
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        try IStaking(STAKING).getStakedBalance(POOL, account, UNDERLYING) returns (uint256 b) { return b; } catch { return 0; }
    }

    function totalSupply() public view virtual override returns (uint256) {
        try IStaking(STAKING).getTotalStaked(POOL, UNDERLYING) returns (uint256 s) { return s; } catch { return 0; }
    }

    function _disabled() internal pure {
        revert Err.FeatureDisabled(Err.Resource.TRANSFER);
    }

    function transfer(address, uint256) public pure override returns (bool) { _disabled(); return false; }
    function transferFrom(address, address, uint256) public pure override returns (bool) { _disabled(); return false; }
    function approve(address, uint256) public pure override returns (bool) { _disabled(); return false; }

    /// @notice Mint sToken to user. Caller MUST be the Staking module (pool delegate).
    /// @dev F-A1-R16-3 (R16 CRITICAL): Solady ERC20 exposes _mint/_burn as `internal` only and
    ///      bypasses _update via raw assembly on _BALANCE_SLOT_SEED. Without these public surfaces
    ///      the Staking module's IMintable(sLP).mint(...) reverts on a missing selector. Gate by
    ///      STAKING immutable (pool address; sToken is owned by exactly one pool by construction).
    function mint(address to, uint256 amount) external {
        if (msg.sender != STAKING) revert Ownable.Unauthorized();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != STAKING) revert Ownable.Unauthorized();
        _burn(from, amount);
    }
}
