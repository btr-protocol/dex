// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {MockERC20} from "./MockERC20.sol";

/**
 * @title MockFaucet
 * @notice Rate-limited faucet for mock tokens
 */
contract MockFaucet {
    struct TokenConfig {
        MockERC20 token;
        uint256 amount;  // per drip
    }

    TokenConfig[] public tokens;
    mapping(address user => uint256 lastDrip) public lastDripTime;

    address public owner;
    uint256 public dripInterval;  // e.g., 1 day
    uint256 public constant DRIP_AMOUNT = 50_000e18;  // $50k worth (adjustable per token decimals)

    event Dripped(address indexed user, uint256 tokenCount);
    event TokenAdded(address indexed token, uint256 amount);
    event IntervalUpdated(uint256 newInterval);

    constructor(uint256 dripInterval_, address owner_) {
        owner = owner_;
        dripInterval = dripInterval_;  // e.g., 1 days
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @notice Mint all available tokens to caller (rate limited)
    function drip() external returns (uint256) {
        if (msg.sender != owner) {
            require(block.timestamp >= lastDripTime[msg.sender] + dripInterval, "cooldown");
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

    /// @notice Add token with custom amount (overrides default)
    function addToken(MockERC20 token, uint256 amount) external onlyOwner {
        tokens.push(TokenConfig({token: token, amount: amount}));
        emit TokenAdded(address(token), amount);
    }

    /// @notice Add multiple tokens
    function addTokens(MockERC20[] calldata _tokens, uint256[] calldata amounts) external onlyOwner {
        require(_tokens.length == amounts.length, "mismatch");
        for (uint256 i = 0; i < _tokens.length; ++i) {
            tokens.push(TokenConfig({token: _tokens[i], amount: amounts[i]}));
            emit TokenAdded(address(_tokens[i]), amounts[i]);
        }
    }

    /// @notice Update drip interval
    function setInterval(uint256 newInterval) external onlyOwner {
        dripInterval = newInterval;
        emit IntervalUpdated(newInterval);
    }

    /// @notice Get all tokens
    function getTokens() external view returns (address[] memory, uint256[] memory) {
        address[] memory addrs = new address[](tokens.length);
        uint256[] memory amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            addrs[i] = address(tokens[i].token);
            amounts[i] = tokens[i].amount;
        }
        return (addrs, amounts);
    }

    /// @notice Time until next drip for user
    function timeUntilDrip(address user) external view returns (uint256) {
        if (user == owner) return 0;
        uint256 eligible = lastDripTime[user] + dripInterval;
        return block.timestamp >= eligible ? 0 : eligible - block.timestamp;
    }
}
