// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Whitelisted testnet drip with on-chain per-token daily caps.
/// @dev Front gates `register()` on mainnet ≥~$5 native; owner can revoke bots.
contract TestnetFaucet {
  using SafeTransferLib for address;

  address public owner;
  mapping(address => bool) public whitelisted;
  /// @dev 0 = token not claimable.
  mapping(address => uint256) public dailyCap;
  mapping(address => mapping(address => uint32)) public claimDay; // user => token => day
  mapping(address => mapping(address => uint256)) public claimedToday; // user => token => amt

  event Claimed(address indexed user, address indexed token, uint256 amount);
  event Whitelisted(address indexed user, bool ok);
  event CapSet(address indexed token, uint256 cap);

  error NotOwner();
  error NotWhitelisted();
  error NoCap();
  error CapExhausted();

  constructor(address owner_) {
    owner = owner_;
    whitelisted[owner_] = true;
    emit Whitelisted(owner_, true);
  }

  modifier onlyOwner() {
    if (msg.sender != owner) revert NotOwner();
    _;
  }

  function setOwner(address next) external onlyOwner {
    owner = next;
  }

  function setWhitelisted(address user, bool ok) public onlyOwner {
    whitelisted[user] = ok;
    emit Whitelisted(user, ok);
  }

  function setWhitelistedBatch(address[] calldata users, bool ok) external onlyOwner {
    for (uint256 i; i < users.length; ++i) {
      setWhitelisted(users[i], ok);
    }
  }

  function setCap(address token, uint256 cap) public onlyOwner {
    dailyCap[token] = cap;
    emit CapSet(token, cap);
  }

  /// @notice Uniform daily cap for every listed asset (ceremony convenience).
  function setCaps(address[] calldata assets, uint256 cap) external onlyOwner {
    for (uint256 i; i < assets.length; ++i) {
      setCap(assets[i], cap);
    }
  }

  /// @notice Self-register. Front must verify mainnet balances first; owner can revoke.
  function register() external {
    whitelisted[msg.sender] = true;
    emit Whitelisted(msg.sender, true);
  }

  function fund(address token, uint256 amount) external {
    token.safeTransferFrom(msg.sender, address(this), amount);
  }

  function remaining(address user, address token) public view returns (uint256) {
    uint256 cap = dailyCap[token];
    if (cap == 0) return 0;
    if (claimDay[user][token] != _day()) return cap;
    uint256 got = claimedToday[user][token];
    return got >= cap ? 0 : cap - got;
  }

  function claim(address token) external {
    if (!whitelisted[msg.sender]) revert NotWhitelisted();
    uint256 cap = dailyCap[token];
    if (cap == 0) revert NoCap();

    uint32 day = _day();
    if (claimDay[msg.sender][token] != day) {
      claimDay[msg.sender][token] = day;
      claimedToday[msg.sender][token] = 0;
    }
    uint256 got = claimedToday[msg.sender][token];
    if (got >= cap) revert CapExhausted();

    uint256 amt = cap - got;
    claimedToday[msg.sender][token] = cap;
    token.safeTransfer(msg.sender, amt);
    emit Claimed(msg.sender, token, amt);
  }

  function _day() internal view returns (uint32) {
    return uint32(block.timestamp / 1 days);
  }
}
