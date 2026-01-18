# Smart Contract Development Workflow

**Orchestrator**: Sybil → Flynn (On-Chain Tech Lead)
**Implementation**: Vulcan (Theory-to-Code) + Clu (Optimization)
**Security Review**: Trinity (Blue Systems) + Kusanagi (Red Strategy)

---

## Purpose

Smart contract development: fix, feature, or refactor for Solidity/SVM/MoveVM contracts.

---

## When to Use This Workflow

| Type | Description | Example |
|------|-------------|---------|
| **Fix** | Bug fix, critical issue | Rounding error in fee calc |
| **Feat** | New feature, enhancement | Add single-sided deposits |
| **Refac** | Code improvement, optimization | Reduce gas by 10% |

---

## Workflow Steps

### Step 1: Task Definition (Sybil)

```
Sybil:
1. Define task: fix/feat/refac
2. Identify scope: Which contracts? Which modules?
3. Assign to Flynn + team (Vulcan + Clu)
4. Set acceptance criteria
```

### Step 2: Architecture Review (Flynn)

```
Flynn:
1. WEBSEARCH: Latest Solidity patterns, security advisories
2. Review module architecture: Diamond pattern, CREATE3, <24KB limit
3. Identify dependencies: Which modules are affected?
4. Design contract structure or identify changes needed
→ Output: Architecture spec approved by Neo (if cross-stack)
```

### Step 3: Security Pre-Review (Trinity)

```
For NEW features or HIGH-RISK changes:
Trinity:
1. Review architecture for security implications
2. Identify attack surfaces: reentrancy, access control, oracle manipulation
3. Recommend security patterns before implementation
→ Output: Security requirements document
```

### Step 4: Implementation (Vulcan)

```
Vulcan:
1. WEBSEARCH: Implementation patterns, gas optimization techniques
2. Implement in contracts/ using:
   - Solidity ^0.8.33 (EVM) / Rust (SVM) / Move (MoveVM)
   - Foundry for testing
   - NatSpec for all public functions
3. TDD approach: Write test first, implement to satisfy test
4. Correctness first, optimization second (Clu optimizes after)
→ Output: Working code with tests
```

### Step 5: Optimization (Clu)

```
Clu reviews Vulcan's code:
1. WEBSEARCH: Gas optimization techniques, assembly patterns
2. Optimize storage layout: Pack structs, use tight mappings
3. Optimize calldata: Pack function arguments
4. Run forge test --gas-report
5. Balance readability with gas savings
→ Output: Gas-optimized code
```

### Step 6: Security Review (REQUIRED)

```
ALL smart contract tasks REQUIRE review by:
- Trinity (Blue Systems): Pattern analysis, VM expertise
- Kusanagi (Red Strategy): Economic exploits, invariant breaking

Reviewers:
1. Review code for vulnerabilities
2. Run Slither, other static analysis tools
3. Test with fuzzing and invariant tests
4. Provide findings or approval
→ Output: Security approval (or fix requests)
```

### Step 7: Final Review (Flynn)

```
Flynn:
1. Review final implementation for:
   - Correctness (matches spec)
   - Gas optimization (<24KB where applicable)
   - Security (all findings addressed)
   - NatSpec completeness
2. Verify all tests pass
→ Approve or request changes
```

### Step 8: Documentation (Jocasta)

```
Jocasta:
1. Update docs/ if user-facing feature
2. Ensure NatSpec complete (Vulcan should have done this)
→ Output: Updated documentation
```

---

## Security Review Requirement

**ALL smart contract tasks REQUIRE review by Trinity + Kusanagi (minimum) before completion.**

| Reviewer | Focus |
|----------|-------|
| **Trinity** | Smart contracts + systems, EVM/SVM/MoveVM patterns |
| **Kusanagi** | Economic exploits, game theory, incentive analysis |
| **Elliot** | Purple Lead (optional for major security decisions) |

---

## Decision Rules

| Decision | Reviewers |
|----------|-----------|
| **Minor** (contract-only) | Vulcan + Clu (2 reviewers) |
| **Major** (cross-stack) | Neo + Flynn + Krennic + 2 specialists (5 reviewers) |

---

## Deliverables

| Output | Location |
|--------|----------|
| Implementation code | `contracts/src/` |
| Tests | `contracts/test/` |
| Gas report | `contracts/.gas-snapshot` |
| Updated docs (if needed) | `docs/` |
| Commit | `[feat]` / `[fix]` / `[refac]` |

---

## Knowledge References

Consult your project's:
- `CONTRIBUTING.md` - Contract development standards
- Security documentation - Security standards and patterns

---

## Commands

```bash
cd <your-contracts-directory>

forge build              # Compile
forge test               # Run tests
forge test --gas-report  # Gas report
forge fmt                # Format
```

---

## Solidity Version

**ALL contracts MUST use Solidity 0.8.33**
- `foundry.toml`: `solc_version = "0.8.33"`
- All `.sol` files: `pragma solidity ^0.8.33`
