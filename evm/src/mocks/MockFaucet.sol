// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MockERC20} from "./MockERC20.sol";

/// @title MockFaucet
/// @notice Rate-limited faucet for mock tokens
contract MockFaucet {
    struct TokenConfig {
        MockERC20 token;
        uint256 amount;
    }

    TokenConfig[] public tokens;
    mapping(address user => uint256 lastDrip) public lastDripTime;

    address public owner;
    uint256 public dripInterval;
    uint256 public constant DRIP_AMOUNT = 50_000e18;

    error Unauthorized();
    error CooldownActive();
    error LengthMismatch();

    event Dripped(address indexed user, uint256 tokenCount);
    event TokenAdded(address indexed token, uint256 amount);
    event IntervalUpdated(uint256 newInterval);

    constructor(uint256 dripInterval_, address owner_) {
        owner = owner_;
        dripInterval = dripInterval_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    function drip() external returns (uint256) {
        if (msg.sender != owner) {
            if (block.timestamp < lastDripTime[msg.sender] + dripInterval) revert CooldownActive();
        }

        uint256 count;
        for (uint256 i = 0; i < tokens.length; ++i) {
            MockERC20 token = tokens[i].token;
            uint256 amount = tokens[i].amount;
            if (amount > 0) {
                token.mint(msg.sender, amount);
                unchecked { ++count; }
            }
        }

        lastDripTime[msg.sender] = block.timestamp;
        emit Dripped(msg.sender, count);
        return count;
    }

    function addTokens(MockERC20[] calldata _tokens, uint256[] calldata amounts) external onlyOwner {
        if (_tokens.length != amounts.length) revert LengthMismatch();
        for (uint256 i = 0; i < _tokens.length; ++i) {
            tokens.push(TokenConfig({token: _tokens[i], amount: amounts[i]}));
            emit TokenAdded(address(_tokens[i]), amounts[i]);
        }
    }

    function setInterval(uint256 newInterval) external onlyOwner {
        dripInterval = newInterval;
        emit IntervalUpdated(newInterval);
    }

    function getTokens() external view returns (address[] memory, uint256[] memory) {
        address[] memory addrs = new address[](tokens.length);
        uint256[] memory amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            addrs[i] = address(tokens[i].token);
            amounts[i] = tokens[i].amount;
        }
        return (addrs, amounts);
    }

    function timeUntilDrip(address user) external view returns (uint256) {
        if (user == owner) return 0;
        uint256 eligible = lastDripTime[user] + dripInterval;
        return block.timestamp >= eligible ? 0 : eligible - block.timestamp;
    }
}
