# Security & Audit Best Practices

**Focus**: EVM (Solidity) + SVM (Solana) + MoveVM (Aptos/Sui) Security

---

## Quick Reference

| Area | Critical Concerns |
|------|-------------------|
| **EVM** | Reentrancy, Arithmetic, Access Control, Front-running |
| **SVM** | PDA validation, Account confusion, CPI safety, Rent |
| **MoveVM** | Capability checks, Resource ownership, Type safety |
| **Cross-chain** | Oracle manipulation, Bridge vulnerabilities, Cross-chain replay |

---

## 1. EVM Security - Common Attack Vectors

### Reentrancy

```solidity
// ❌ VULNERABLE: State change after external call
function withdraw(uint256 amount) external {
    require(balances[msg.sender] >= amount, "Insufficient balance");
    // External call BEFORE state update
    (bool success, ) = msg.sender.call{value: amount}("");
    require(success, "Transfer failed");
    balances[msg.sender] -= amount;  // State change AFTER
}

// ✅ SECURE: Check-Effects-Interactions pattern
function withdraw(uint256 amount) external nonReentrant {
    require(balances[msg.sender] >= amount, "Insufficient balance");
    // State change BEFORE external call
    balances[msg.sender] -= amount;
    (bool success, ) = msg.sender.call{value: amount}("");
    require(success, "Transfer failed");
}

// ✅ SECURE: ReentrancyGuard with transient storage
modifier nonReentrant() {
    bytes32 slot = 0xaaa...; // transient storage slot
    assembly {
        if tload(slot) { revert(0, 0) }
        tstore(slot, 1)
    }
    _;
    assembly { tstore(slot, 0) }
}
```

### Arithmetic Issues

```solidity
// ❌ VULNERABLE: Pre-0.8 overflow
function add(uint256 a, uint256 b) public pure returns (uint256) {
    return a + b;  // Can overflow
}

// ✅ SECURE: Solidity 0.8+ built-in checks
function add(uint256 a, uint256 b) public pure returns (uint256) {
    unchecked {
        // Only use unchecked if you've verified bounds
        require(a <= type(uint256).max - b, "Overflow");
        return a + b;
    }
}

// ❌ VULNERABLE: Precision loss
uint256 result = (amount * fee) / 100;  // May lose precision

// ✅ SECURE: High-precision math
uint256 result = (amount * fee) / 10000;  // Use basis points
```

### Access Control Vulnerabilities

```solidity
// ❌ VULNERABLE: Missing protection
function emergencyWithdraw() external {
    payable(owner()).transfer(address(this).balance);
}

// ❌ VULNERABLE: tx.origin authentication
function withdraw() external {
    require(tx.origin == owner, "Not authorized");
    // Vulnerable to phishing attacks
}

// ✅ SECURE: proper modifier
modifier onlyOwner() {
    if (msg.sender != owner()) revert Unauthorized();
    _;
}

function emergencyWithdraw() external onlyOwner {
    payable(owner()).transfer(address(this).balance);
}
```

### Front-Running (MEV)

```solidity
// ❌ VULNERABLE: No deadline or slippage protection
function swap(uint256 amount) external {
    // Vulnerable to sandwich attacks
    _executeSwap(msg.sender, amount);
}

// ✅ SECURE: Deadline and slippage protection
function swap(
    uint256 amount,
    uint256 minOut,
    uint256 deadline
) external {
    require(block.timestamp <= deadline, "Expired");
    uint256 amountOut = _executeSwap(msg.sender, amount);
    require(amountOut >= minOut, "Slippage exceeded");
}
```

### Flash Loan Attack Patterns

```solidity
// ❌ VULNERABLE: No checks for instant deposit/withdraw
function deposit() external payable {
    balances[msg.sender] += msg.value;
}

function withdraw(uint256 amount) external {
    require(balances[msg.sender] >= amount, "Insufficient");
    payable(msg.sender).transfer(amount);
    balances[msg.sender] -= amount;
}

// ✅ SECURE: Flow guard (cooldown period)
struct FlowGuard {
    mapping(address => uint256) lastDeposit;
    uint256 constant COOLDOWN = 15 seconds;
}

function deposit() external payable {
    balances[msg.sender] += msg.value;
    flowGuard.lastDeposit[msg.sender] = block.timestamp;
}

function withdraw(uint256 amount) external {
    require(
        block.timestamp >= flowGuard.lastDeposit[msg.sender] + COOLDOWN,
        "Cooldown active"
    );
    // ... withdraw logic
}
```

---

## 2. SVM Security - Common Attack Vectors

### PDA Bypass Attacks

```rust
// ❌ VULNERABLE: No PDA validation
#[derive(Accounts)]
pub struct UnsafeSwap<'info> {
    pub pool: Account<'info, Pool>,
    #[account(mut)]
    pub user: AccountInfo<'info>,
}

// ✅ SECURE: Proper PDA validation
#[derive(Accounts)]
pub struct SafeSwap<'info> {
    #[account(
        seeds = [b"pool", authority.key().as_ref()],
        bump = pool.bump,
        has_one = authority
    )]
    pub pool: Account<'info, Pool>,
    pub authority: Signer<'info>,
}
```

### Account Confusion

```rust
// ❌ VULNERABLE: No ownership check
pub fn withdraw(ctx: Context<Withdraw>, amount: u64) -> Result<()> {
    let user_token = &ctx.accounts.user_token;
    token::transfer(ctx.accounts.token_program.to_account_info(), user_token, /* ... */)?;
    Ok(())
}

// ✅ SECURE: Verify ownership
#[derive(Accounts)]
pub struct Withdraw<'info> {
    #[account(mut, constraint = user_token.owner == user.key() @ ErrorCode::InvalidOwner)]
    pub user_token: Account<'info, TokenAccount>,
    pub user: Signer<'info>,
}
```

### CPI (Cross-Program Invocation) Attacks

```rust
// ❌ VULNERABLE: Unvalidated CPI
let cpi_context = CpiContext::new(
    token_program.to_account_info(),
    Transfer {
        from: source.to_account_info(),
        to: destination.to_account_info(),
        authority: authority.to_account_info(),
    },
);
transfer(cpi_context, amount)?;

// ✅ SECURE: Validate program IDs
#[account(constraint = token_program.key() == TOKEN_PROGRAM_ID @ ErrorCode::InvalidTokenProgram)]
pub token_program: Program<'info, Token>,
```

### Rent Exploitation

```rust
// ❌ VULNERABLE: Not checking rent exemption
pub fn initialize(ctx: Context<Initialize>) -> Result<()> {
    let state = &ctx.accounts.state;
    state.owner = ctx.accounts.authority.key();
    Ok(())
}

// ✅ SECURE: Ensure rent exemption
#[account(
    init,
    payer = payer,
    space = 8 + State::LEN,
)]
pub struct State {
    pub owner: Pubkey,
}
```

---

## 3. MoveVM Security - Common Attack Vectors

### Capability Bypass

```move
// ❌ VULNERABLE: No signer check
public entry fun withdraw(pool_addr: address, amount: u64) acquires Pool {
    let pool = borrow_global_mut<Pool>(pool_addr);
    // Anyone can call!
}

// ✅ SECURE: Require signer
public entry fun withdraw(account: &signer, pool_addr: address, amount: u64) acquires Pool {
    let pool = borrow_global_mut<Pool>(pool_addr);
    assert!(signer::address_of(account) == pool.owner, ENOT_AUTHORIZED);
    // Safe to proceed
}
```

### Resource Forgery

```move
// ❌ VULNERABLE: No resource existence check
public fun get_balance(pool_addr: address): u64 acquires Pool {
    let pool = borrow_global<Pool>(pool_addr);
    // Will abort if Pool doesn't exist - potential DoS
}

// ✅ SECURE: Check before borrow
public fun get_balance(pool_addr: address): u64 acquires Pool {
    assert!(exists<Pool>(pool_addr), EPOOL_NOT_FOUND);
    let pool = borrow_global<Pool>(pool_addr);
    pool.balance
}
```

### Type Confusion

```move
// Move's type system prevents this at compile time
// Resources cannot be cast to different types

// ✅ SECURE: Type safety by design
struct Coin<phantom T> has store {
    value: u64
}

// Coin<USDT> and Coin<USDC> are different types
// Cannot accidentally use wrong token type
```

---

## 4. Cross-Chain Security

### Oracle Manipulation

```solidity
// ❌ VULNERABLE: Single oracle source
function getPrice() internal view returns (uint256) {
    return IPriceOracle(oracle).getPrice(token);
}

// ✅ SECURE: Multi-oracle with deviation check
function getPrice() internal view returns (uint256) {
    uint256 price1 = oracle1.getPrice(token);
    uint256 price2 = oracle2.getPrice(token);

    uint256 diff = price1 > price2 ? price1 - price2 : price2 - price1;
    uint256 avg = (price1 + price2) / 2;

    require(diff * 100 <= avg * MAX_DEVIATION_BPS, "Price deviation too high");
    return avg;
}

// ✅ SECURE: Staleness check
function getPrice() internal view returns (uint256) {
    (uint256 price, uint256 timestamp) = oracle.getPriceAndTime(token);
    require(block.timestamp - timestamp <= MAX_STALENESS, "Price stale");
    return price;
}
```

### Bridge Vulnerabilities

```solidity
// ❌ VULNERABLE: No replay protection
mapping(bytes32 => bool) public processed;

function executeBridge(
    bytes calldata proof,
    address recipient,
    uint256 amount
) external {
    // Verify proof
    require(verifyProof(proof, recipient, amount), "Invalid proof");

    // ⚠️ No replay protection across chains
    mint(recipient, amount);
}

// ✅ SECURE: Chain-aware replay protection
mapping(uint256 => mapping(bytes32 => bool)) public processed;

function executeBridge(
    uint256 sourceChain,
    bytes32 transactionId,
    address recipient,
    uint256 amount
) external {
    require(!processed[sourceChain][transactionId], "Already processed");
    processed[sourceChain][transactionId] = true;
    // ... rest of logic
}
```

---

## 5. Security Checklist

### Pre-Deployment

#### Smart Contract Code
- [ ] All external calls use Try/Catch or low-level call with return checks
- [ ] Reentrancy guards on all state-changing functions
- [ ] Access control modifiers on privileged functions
- [ ] Input validation on all public/external functions
- [ ] Integer overflow/underflow protection
- [ ] Front-running mitigation (deadlines, slippage limits)
- [ ] Emergency pause mechanism
- [ ] Safe ERC20/ERC721 operations (custom error handling)
- [ ] No tx.origin authentication
- [ ] Proper event emission for all state changes

#### DeFi Specific
- [ ] Oracle staleness checks
- [ ] Price deviation limits
- [ ] Flash loan protection (flow guards)
- [ ] Precision loss analysis
- [ ] Rounding direction analysis
- [ ] Liquidity invariant checks
- [ ] Safe ratio calculations (always multiply before divide)
- [ ] Asset decimals handled correctly

#### Testing
- [ ] Unit tests for all functions
- [ ] Integration tests with mainnet fork
- [ ] Fuzz testing for edge cases
- [ ] Invariant tests for system properties
- [ ] Gas optimization review
- [ ] Test coverage > 90%

### Post-Audit

- [ ] All audit findings addressed or documented
- [ ] Bug bounty program launched
- [ ] Monitoring/alerting configured
- [ ] Incident response plan created
- [ ] Upgrade mechanism tested
- [ ] Time lock configured for admin actions

---

## 6. Audit Process

### Pre-Audit Preparation

```bash
# Prepare deliverables
1. NatSpec documentation complete
2. Architecture diagram
3. Threat model document
4. Test suite results
5. Gas snapshot report
6. Known issues list
```

### During Audit

```bash
# Provide to auditors
1. Complete source code
2. Test files
3. Deployment scripts
4. Documentation (README, NatSpec)
5. Architecture overview
6. Previous audits (if any)
```

### Post-Audit

- Create GitHub issues for each finding
- Categorize by severity (Critical, High, Medium, Low, Informational)
- Fix or document each finding
- Get audit confirmation for fixes
- Update documentation

---

## 7. Severity Classification

| Severity | Definition | Example |
|----------|------------|---------|
| **Critical** | Loss of funds, protocol breakage | Reentrancy, stolen admin keys |
| **High** | Significant fund loss risk | Access control bypass, price manipulation |
| **Medium** | Fund loss under specific conditions | Business logic flaw, griefing |
| **Low** | Minor issues, no fund loss | Gas optimization, unused code |
| **Informational** | Best practice suggestions | Documentation improvements |

---

## 8. Common Vulnerability Database

### EVM Vulnerabilities

| Vulnerability | Detection | Prevention |
|---------------|-----------|------------|
| Reentrancy | Slither, manual review | Checks-Effects-Interactions |
| Overflow/Underflow | Solidity 0.8+ compiler | Built-in checks |
| Access Control | Slither, manual review | Comprehensive modifiers |
| Front-running | Manual review | Deadline/slippage |
| Flash Loan | Manual review | Flow guards, invariants |
| Oracle Manipulation | Monitoring | Multi-oracle, staleness checks |
| Integer Rounding | Manual review | High-precision math |
| Default Visibility | Solhint | Explicit visibility |

### SVM Vulnerabilities

| Vulnerability | Detection | Prevention |
|---------------|-----------|------------|
| PDA Bypass | Manual review | Seeds validation |
| Account Confusion | Manual review | Ownership checks |
| CPI Attacks | Manual review | Program ID validation |
| Rent Exhaustion | Manual review | Rent exemption checks |
| Anchor Security | Anchor linter | Type-safe wrappers |

### MoveVM Vulnerabilities

| Vulnerability | Detection | Prevention |
|---------------|-----------|------------|
| Capability Leaks | Move Prover | Proper signer checks |
| Resource Forgery | Move Prover | Existence checks |
| Borrow Violations | Compiler | Follow borrow rules |
| Arithmetic Overflow | Compiler | Checked operations |

---

## 9. Security Tools

### EVM Tools

```bash
# Slither - Static analysis
pip install slither-analyzer
slither contracts/

# Foundry testing
forge test --fuzz-runs 1000
forge test --match-contract InvariantTest

# Echidna - Property testing
echidna-test contract.sol --contract MyContract

# Mythril - Symbolic execution
myth analyze contract.sol

# Solhint - Linting
solhint 'contracts/**/*.sol'
```

### SVM Tools

```bash
# Anchor testing
anchor test

# Anchor security checks
anchor verify PROGRAM_ID

# Solana program security
cargo audit
```

### MoveVM Tools

```bash
# Move prover
aptos move prove

# Move linter
aptos move lint

# Unit tests
aptos move test
```

---

## 10. Incident Response

### Incident Classification

1. **Active Exploit**: Funds currently being drained
2. **Paused**: Protocol paused, investigating
3. **Resolved**: Issue fixed, funds recovered/returned

### Response Steps

```bash
1. PAUSE: Trigger emergency pause
2. ASSESS: Determine scope and impact
3. NOTIFY: Inform team and community
4. MITIGATE: Stop bleeding (if active)
5. INVESTIGATE: Root cause analysis
6. FIX: Deploy patch
7. RECOVER: Attempt fund recovery
8. POST-MORTEM: Document and improve
```

### Emergency Contacts

- Security Team: [TODO]
- Bug Bounty: [TODO]
- Audit Firm: [TODO]
- Exchange Contacts: [TODO]

---

## 11. Threat Modeling Framework

### STRIDE Methodology

| Threat | Description | Mitigation |
|--------|-------------|------------|
| **Spoofing** | Fake identity | Strong authentication |
| **Tampering** | Data modification | Immutable storage, signatures |
| **Repudiation** | Deny action | Event logs, signatures |
| **Information Disclosure** | Data leak | Access control, encryption |
| **Denial of Service** | Disrupt service | Rate limits, gas checks |
| **Elevation of Privilege** | Gain admin access | Multi-sig, time locks |

### Asset Threat Model

| Asset | Threats | Controls |
|-------|---------|----------|
| User Funds | Reentrancy, oracle manipulation | Guards, multi-oracle |
| Protocol Fees | Admin bypass | Multi-sig admin |
| Governance | Voting manipulation | Time locks, quorum |
| Oracles | Manipulation | Staleness, deviation checks |

---

## 12. Best Practices Summary

### Always Do

- Use `nonReentrant` modifier on state-changing functions
- Implement access control on privileged functions
- Validate all inputs
- Use deadline and slippage protection
- Check oracle staleness
- Implement emergency pause
- Emit events for state changes
- Use SafeERC20/SafeERC721 patterns
- Test with mainnet forks
- Run fuzz and invariant tests

### Never Do

- Use `tx.origin` for authentication
- Change state after external calls
- Trust single oracle source without checks
- Assume token.transfer() always succeeds
- Leave unguarded privileged functions
- Deploy without audit
- Skip emergency pause mechanism
- Use floating pragma in production
- Ignore compiler warnings
- Ship without tests

---

## Internal References

- [`CONTRIBUTING.md`](../CONTRIBUTING.md) - Commit conventions
- [`SMART_CONTRACTS.md`](./SMART_CONTRACTS.md) - Smart contract development

---

*Last updated: 2025-01*
