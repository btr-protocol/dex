// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title BTRToken
/// @notice Simple mock ERC20 token for testing
contract BTRToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;

        uint256 initialSupply = 1_000_000 * 10 ** uint256(_decimals);
        balanceOf[msg.sender] = initialSupply;
        totalSupply = initialSupply;

        emit Transfer(address(0), msg.sender, initialSupply);
    }

    function transfer(address to, uint256 value) public returns (bool) {
        require(to != address(0), "Invalid address");
        require(balanceOf[msg.sender] >= value, "Insufficient balance");

        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;

        emit Transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        require(to != address(0), "Invalid address");
        require(balanceOf[from] >= value, "Insufficient balance");
        require(allowance[from][msg.sender] >= value, "Insufficient allowance");

        balanceOf[from] -= value;
        balanceOf[to] += value;
        allowance[from][msg.sender] -= value;

        emit Transfer(from, to, value);
        return true;
    }

    /// @notice Mint tokens to an address (for testing)
    function mint(address to, uint256 amount) public {
        require(to != address(0), "Invalid address");

        balanceOf[to] += amount;
        totalSupply += amount;

        emit Transfer(address(0), to, amount);
    }

    /// @notice Burn tokens from an address (for testing)
    function burn(address from, uint256 amount) public {
        require(balanceOf[from] >= amount, "Insufficient balance");

        balanceOf[from] -= amount;
        totalSupply -= amount;

        emit Transfer(from, address(0), amount);
    }
}
