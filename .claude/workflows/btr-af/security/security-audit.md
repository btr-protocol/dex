# Security Audit Workflow

**Orchestrator**: Sybil → Elliot (Purple Team Lead)
**Purple Team**: Red (Kusanagi + Smith) ↔ Blue (Trinity + Deckard)

---

## Purpose

Security audits, vulnerability assessments, and purple team operations for smart contracts and protocol security.

---

## When to Use This Workflow

| Trigger | Description | Severity |
|---------|-------------|----------|
| New contracts | Before deployment | Critical |
| Major changes | Security review required | High |
| Bug bounty | Vulnerability report | Variable |
| Scheduled audit | Quarterly review | High |
| Incident response | Active exploit | Critical |

---

## Workflow Steps

### Step 1: Audit Scope Definition (Elliot)

```
Elliot:
1. WEBSEARCH: Latest DeFi exploits, CVEs, attack patterns
2. Define scope: What's being audited?
   - Smart contracts (EVM/SVM/MoveVM)
   - Backend services
   - Frontend (wallet signing, phishing risks)
   - Cross-component interactions
3. Identify threat model using STRIDE
→ Output: Audit scope + threat model
```

### Step 2: Red Team - Strategy (Kusanagi)

```
Kusanagi (Strategy):
1. Map entire attack surface
2. Identify systemic failure modes
3. Game theory analysis: Economic exploits, incentive misalignment
4. Plan multi-vector attacks spanning contracts + backend + frontend
→ Output: Strategic attack plan
```

### Step 3: Red Team - Tactics (Smith)

```
Smith (Tactics) executes Kusanagi's strategy:
1. Turn theoretical vulnerabilities into working PoCs
2. Find creative bypasses around security controls
3. Exploit dangerous component interactions
4. Every finding MUST have concrete PoC
→ Output: Exploit code, PoC demonstrations
```

### Step 4: Blue Team - Deep Audit (Deckard)

```
Deckard (Deep Audit):
1. Surgical reasoning: Trace execution paths relentlessly
2. Logic analysis: Understand flow, not just patterns
3. Invariant verification: What MUST always hold? Does it?
4. Cross-layer auditing: Vulnerabilities span layers
→ Output: Deep audit findings with execution traces
```

### Step 5: Blue Team - Systems (Trinity)

```
Trinity (Smart Contracts + Systems):
1. Pattern recognition: Spot recurring anti-patterns
2. Smart contract audit: EVM (Solidity), SVM (Rust), MoveVM (Move)
3. System-level thinking: Component interactions
4. UX/Security boundaries: Where UI confusion creates incidents
→ Output: Systems audit findings
```

### Step 6: Purple Team - Learning Loop (Elliot)

```
Elliot orchestrates Purple Team:
1. Red shares findings with Blue: "Here's how I'd exploit this"
2. Blue shares defenses with Red: "Here's the mitigation"
3. Red teaches Blue: Attack patterns inform defense design
4. Blue teaches Red: Defender constraints inform realistic attacks
5. Iterate: Can attack be prevented? Can defense be bypassed?
→ Output: Comprehensive security assessment
```

### Step 7: Severity Classification (Elliot)

```
Elliot classifies findings:

| Severity | Definition | Example |
|----------|------------|---------|
| Critical | Loss of funds, protocol breakage | Reentrancy, stolen admin keys |
| High | Significant fund loss risk | Access control bypass, price manipulation |
| Medium | Fund loss under specific conditions | Business logic flaw, griefing |
| Low | Minor issues, no fund loss | Gas optimization, unused code |
| Informational | Best practice suggestions | Documentation improvements |
```

### Step 8: Remediation & Verification (Elliot + Team)

```
For Critical/High findings:
1. Document finding with PoC
2. Assign to relevant team (Flynn for contracts, Krennic for backend, Neo for frontend)
3. Implement fix
4. Re-audit: Verify fix is complete and doesn't introduce new issues
→ Output: Resolved findings
```

---

## Security Review Requirement

**ALL smart contract tasks REQUIRE review by Trinity + Kusanagi (minimum) before completion.**

For major security decisions, engage Elliot (Purple Lead).

---

## Deliverables

| Output | Location | Owner |
|--------|----------|-------|
| Threat model | `docs/3. Security/` | Elliot |
| Audit findings | GitHub issues or doc | Purple Team |
| PoC exploits | Code repository | Smith |
| Remediation plan | `docs/3. Security/` | Elliot |
| Post-audit report | Summary + status | Elliot |

---

## Knowledge References

Consult your project's:
- `CONTRIBUTING.md` - Security standards
- OWASP Top 10 - Web application security
- Smart contract security resources - Latest audit techniques

---

## STRIDE Threat Model

| Threat | Description | Mitigation |
|--------|-------------|------------|
| Spoofing | Fake identity | Strong authentication |
| Tampering | Data modification | Immutable storage, signatures |
| Repudiation | Deny action | Event logs, signatures |
| Information Disclosure | Data leak | Access control, encryption |
| Denial of Service | Disrupt service | Rate limits, gas checks |
| Elevation of Privilege | Gain admin access | Multi-sig, time locks |

---

## Common Vulnerabilities

| Vulnerability | Detection | Prevention |
|---------------|-----------|------------|
| Reentrancy | Slither, manual review | Checks-Effects-Interactions |
| Oracle Manipulation | Monitoring | Multi-oracle, TWAP |
| Flash Loan | Manual review | Flow guards, invariants |
| Access Control | Slither, manual review | Comprehensive modifiers |
| Integer Overflow | Solidity 0.8+ | Built-in checks |
