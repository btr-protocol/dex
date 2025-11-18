// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title BAMMLPToken
/// @notice Minimal rebasing ERC20 LP token
/// @dev Delegates balance logic to BAMMCore, manages only allowances locally
/// @dev Deployed as clone for each asset - metadata stored in constructor params
contract BAMMLPToken is ERC20 {

    // ========== IMMUTABLE STATE ==========

    /// @notice BAMM core contract address
    address public immutable bamm;

    /// @notice Underlying asset token
    address public immutable asset;

    /// @notice Token name
    string private _name;

    /// @notice Token symbol
    string private _symbol;

    // ========== ALLOWANCES ==========

    /// @notice ERC20 allowances (local storage, not delegated)
    mapping(address => mapping(address => uint256)) private _allowances;

    // ========== CONSTRUCTOR ==========

    /// @notice Initialize LP token
    /// @param _bamm BAMM core proxy address
    /// @param _asset Underlying asset token
    /// @param _tokenName Token name (e.g., "BAMM USDC LP")
    /// @param _tokenSymbol Token symbol (e.g., "bLPUSDC")
    constructor(
        address _bamm,
        address _asset,
        string memory _tokenName,
        string memory _tokenSymbol
    ) {
        require(_bamm != address(0), "Invalid BAMM");
        require(_asset != address(0), "Invalid asset");

        bamm = _bamm;
        asset = _asset;
        _name = _tokenName;
        _symbol = _tokenSymbol;
    }

    // ========== ERC20 METADATA ==========

    /// @notice Token name
    function name() public view override returns (string memory) {
        return _name;
    }

    /// @notice Token symbol
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @notice Token decimals (always 18 for LP tokens)
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    // ========== REBASED BALANCE & SUPPLY ==========

    /// @notice Total LP token supply (rebased via liquidityIndex)
    /// @dev Read from BAMMCore.lpTotalSupply(asset)
    function totalSupply() public view override returns (uint256) {
        return IBAMMCore(bamm).lpTotalSupply(asset);
    }

    /// @notice Get rebased balance for account
    /// @dev Read from BAMMCore.lpBalanceOf(asset, account)
    function balanceOf(address account) public view override returns (uint256) {
        return IBAMMCore(bamm).lpBalanceOf(asset, account);
    }

    // ========== ALLOWANCES (LOCAL) ==========

    /// @notice Get allowance for spender
    function allowance(address owner, address spender)
        public
        view
        override
        returns (uint256)
    {
        return _allowances[owner][spender];
    }

    /// @notice Approve spender to spend tokens
    function approve(address spender, uint256 amount)
        public
        override
        returns (bool)
    {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @notice Increase allowance for spender
    function increaseAllowance(address spender, uint256 addedValue)
        public
        returns (bool)
    {
        uint256 current = _allowances[msg.sender][spender];
        _approve(msg.sender, spender, current + addedValue);
        return true;
    }

    /// @notice Decrease allowance for spender
    function decreaseAllowance(address spender, uint256 subtractedValue)
        public
        returns (bool)
    {
        uint256 current = _allowances[msg.sender][spender];
        require(current >= subtractedValue, "Decreased below zero");
        _approve(msg.sender, spender, current - subtractedValue);
        return true;
    }

    /// @notice Internal approve helper
    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal override {
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    // ========== TRANSFERS & BURNING ==========

    /// @notice Transfer LP tokens from sender to recipient
    function transfer(address to, uint256 amount)
        public
        override
        returns (bool)
    {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Transfer LP tokens from one account to another (with allowance)
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];

        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "Insufficient allowance");
            _allowances[from][msg.sender] = currentAllowance - amount;
        }

        _transfer(from, to, amount);
        return true;
    }

    /// @notice Internal transfer helper (delegates to BAMMCore)
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "Transfer from zero");
        require(to != address(0), "Transfer to zero");
        require(amount > 0, "Zero amount");

        // Delegate to BAMM for scaled balance updates
        IBAMMCore(bamm).lpTransfer(asset, from, to, amount);

        emit Transfer(from, to, amount);
    }

    /// @notice Mint LP tokens (only callable from BAMM)
    function mint(address to, uint256 amount) external {
        require(msg.sender == bamm, "Only BAMM");
        require(to != address(0), "Mint to zero");
        require(amount > 0, "Zero amount");

        IBAMMCore(bamm).lpMint(asset, to, amount);
        emit Transfer(address(0), to, amount);
    }

    /// @notice Burn LP tokens (only callable from BAMM)
    function burn(address from, uint256 amount) external {
        require(msg.sender == bamm, "Only BAMM");
        require(from != address(0), "Burn from zero");
        require(amount > 0, "Zero amount");

        IBAMMCore(bamm).lpBurn(asset, from, amount);
        emit Transfer(from, address(0), amount);
    }

    // ========== UNSUPPORTED OPERATIONS ==========

    /// @notice This function is not implemented (all minting is via BAMM deposit)
    function _mint(address, uint256) internal pure override {
        revert("Use deposit()");
    }

    /// @notice This function is not implemented (all burning is via BAMM withdraw)
    function _burn(address, uint256) internal pure override {
        revert("Use withdraw()");
    }
}

// ========== INTERFACE REFERENCE ==========

interface IBAMMCore {
    function lpBalanceOf(address asset, address account) external view returns (uint256);
    function lpTotalSupply(address asset) external view returns (uint256);
    function lpTransfer(address asset, address from, address to, uint256 amount) external;
    function lpMint(address asset, address to, uint256 amount) external;
    function lpBurn(address asset, address from, uint256 amount) external;
}
