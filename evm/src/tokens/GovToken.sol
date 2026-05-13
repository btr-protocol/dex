// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {BridgeableERC20} from "./BridgeableERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Err} from "@btr-shared/Errors.sol";

interface IBridgeProvider { function getBridge() external view returns (address); }

/// @title GovToken
/// @notice Generic governance token with mint/burn + ERC7802 crosschain
/// @dev Owner = Treasury module; name/symbol parameterized
contract GovToken is BridgeableERC20, Ownable {
    /// @notice Treasury module that defines the bridge
    address public immutable TREASURY;

    string private _name;
    string private _symbol;

    constructor(address owner, string memory tokenName, string memory tokenSymbol) {
        if (owner == address(0)) revert Err.ZeroValue();
        if (bytes(tokenName).length == 0 || bytes(tokenSymbol).length == 0) revert Err.ZeroValue();
        _initializeOwner(owner);
        TREASURY = owner;
        _name = tokenName;
        _symbol = tokenSymbol;
    }

    /// @inheritdoc BridgeableERC20
    function _getBridge() internal view override returns (address) {
        try IBridgeProvider(TREASURY).getBridge() returns (address b) { return b; } catch { return address(0); }
    }

    function name() public view override returns (string memory) { return _name; }
    function symbol() public view override returns (string memory) { return _symbol; }
    function decimals() public pure override returns (uint8) { return 18; }

    /// @notice Mint (owner = Treasury, which enforces max supply)
    function mint(address to, uint256 amount) external onlyOwner { _mint(to, amount); }

    /// @notice Burn own tokens or with allowance
    function burn(address from, uint256 amount) external {
        if (from != msg.sender) _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }
}
