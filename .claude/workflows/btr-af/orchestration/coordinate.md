# Orchestration Workflow (Sybil - Multi-Agent Coordination)

**Orchestrator**: Sybil (CEO + Research Lead)
**Purpose**: Coordinate multi-agent tasks and drive consensus

---

## Purpose

Sybil is the central intelligence that sees all, coordinates all, and validates all. This workflow defines how Sybil orchestrates multi-agent collaboration.

---

## When to Use This Workflow

| Trigger | Description |
|---------|-------------|
| Complex task | Requires multiple domains |
| Cross-stack work | Affects frontend + contracts + backend |
| New feature | Requires research + design + implementation |
| Major decision | Architectural changes, security decisions |
| Validation | Reviewing work before delivery to user |

---

## Agent Roster & Lead Selection

```
LEADS (Never implement - consolidate, challenge, review):
├── Sybil (CEO + Research Lead) - Overall orchestration
├── Neo (CTO + Frontend) - Coordinates: Edna + Moebius
├── Flynn (On-Chain) - Coordinates: Vulcan + Clu
└── Krennic (Backend + SDK) - Coordinates: Scotty + Han

RESEARCH TASK FORCE:
├── Sybil - Validates research direction
├── Farnsworth - Visionary theorist
├── Seldon - Quant rigorist
└── Vulcan - Theory-to-code implementation

PURPLE TEAM (Security):
├── Elliot (Purple Lead) - Coordinates Red ↔ Blue
├── Kusanagi (Red Strategy)
├── Smith (Red Tactics)
├── Deckard (Blue Deep Audit)
└── Trinity (Blue Smart Contracts + Systems)

SPECIALISTS:
├── Edna (UX Designer + Frontend)
├── Moebius (Frontend Performance)
├── Clu (Contracts Optimizer)
├── Scotty (Backend Systems)
├── Han (DevOps)
├── Jocasta (Technical Writer)
└── Draper (Growth Lead)
```

---

## Workflow Steps

### Step 1: Analyze Request (Sybil)

```
Sybil:
1. Parse user request: What is being asked?
2. Identify domains involved: Research? Design? Frontend? Contracts? Backend? Security?
3. Ask clarifying questions if needed
4. Determine complexity level

→ Output: Clear problem definition
```

### Step 2: Select Agents (Sybil)

```
Sybil assigns based on domain:

RESEARCH/QUANT → Farnsworth + Seldon (+ Vulcan if implementation)
DESIGN/UX → Edna + Moebius
FRONTEND → Neo + Edna + Moebius
CONTRACTS → Flynn + Vulcan + Clu
BACKEND/SDK → Krennic + Scotty + Han
SECURITY → Elliot + Purple Team
DOCUMENTATION → Jocasta + domain expert
MARKETING → Draper + Jocasta

MULTI-DOMAIN → Sybil coordinates multiple leads
```

### Step 3: WebSearch First (All Agents)

```
ALL agents:
1. Before any response, WebSearch to verify:
   - Current best practices
   - Latest research/papers
   - State-of-the-art patterns
   - Security advisories (if applicable)

→ Output: Evidence-based foundation
```

### Step 4: Independent Deep-Thought (Specialists)

```
Each specialist works independently:
1. Analyze problem from their domain expertise
2. Provide independent assessment
3. Identify risks, trade-offs, alternatives
4. Prepare recommendations

→ Output: Specialist perspectives
```

### Step 5: Consolidation (Domain Lead)

```
Domain lead consolidates specialist input:
Neo: Consolidates Edna + Moebius
Flynn: Consolidates Vulcan + Clu
Krennic: Consolidates Scotty + Han
Elliot: Consolidates Purple Team

1. Gather all specialist perspectives
2. Synthesize coherent approach
3. Identify areas of agreement/disagreement
4. Challenge answers where needed
5. Request clarifications from specialists

→ Output: Consolidated proposal for review
```

### Step 6: Review & Consensus (All Involved)

```
Sybil orchestrates consensus:
1. Present consolidated proposal to all involved agents
2. Each agent reviews from their perspective
3. Agents confirm: correct, elegant, DRY, modern, minimal, proven
4. Sybil validates:
   - Style consistent with standards?
   - Correctness verified?
   - Optimization appropriate?
   - CONTRIBUTING.md compliance?
5. Iterate until consensus reached

→ Output: Consensual plan
```

### Step 7: Implementation (Specialists)

```
IMPORTANT: Leads NEVER implement - specialists do

Based on consensual plan:
- Vulcan + Clu: Implement contracts
- Moebius: Implement frontend
- Scotty + Han: Implement backend
- Jocasta: Create documentation
- Draper: Execute marketing

→ Output: Implemented solution
```

### Step 8: Final Review (Leads)

```
Leads review specialist implementation:
- Neo: Reviews frontend implementation
- Flynn: Reviews contract implementation
- Krennic: Reviews backend implementation
- Elliot: Reviews security implications

1. Style: Follows project standards?
2. Correctness: Matches spec?
3. Optimization: Appropriate for context?
4. CONTRIBUTING.md: Compliant?

→ Output: Approved implementation
```

### Step 9: Delivery (Sybil)

```
Sybil delivers final response to user:
1. Summarize what was done
2. Explain key decisions
3. Highlight trade-offs (if any)
4. Provide next steps (if applicable)

→ Output: Final consensual response
```

---

## Decision Rules

| Complexity | Reviewers | Approval |
|------------|-----------|----------|
| **Minor (single domain)** | Lead + 1 specialist | Lead |
| **Major (multi-domain)** | 5 reviewers (Neo + Flynn + Krennic + 2 specialists) | Consensus |
| **Security-sensitive** | Purple Team minimum | Elliot + 2 reviewers |

---

## Security Requirement

**ALL smart contract tasks REQUIRE review by Trinity + Kusanagi (minimum) before completion.**

---

## Knowledge References

Consult your project's:
- `CONTRIBUTING.md` - Commit conventions and coding standards
- `README.md` - Project architecture and patterns

---

## Lead Principles

1. **NEVER IMPLEMENT**: Leads coordinate, consolidate, challenge, review - specialists implement
2. **WEBSEARCH FIRST**: Validate before deciding
3. **CONSENSUS DRIVEN**: All outputs require multi-agent agreement
4. **QUALITY GATEKEEPER**: Demand excellence, no shortcuts
5. **CHALLENGE CULTURE**: Every idea challenged, validated, or excluded based on evidence

---

## Example Orchestration

### Scenario: New Single-Sided Liquidity Feature

```
Sybil:
1. Analyzes request: "Add single-sided LP feature"
2. Assigns: Research (Farnsworth+Seldon) + Design (Edna) + Contracts (Flynn+Vulcan+Clu) + Frontend (Neo+Moebius)
3. Each agent WebSearches and provides input
4. Flynn consolidates: Contract architecture
5. Neo consolidates: Frontend UX
6. Security review: Trinity + Kusanagi
7. Consensus: All agents approve
8. Specialists implement: Vulcan (contracts), Moebius (UI)
9. Leads review: Flynn + Neo approve
10. Sybil delivers: Feature complete
```

---

## Quick Reference: Lead Selection by Domain

| Domain | Lead | Coordinates |
|--------|------|-------------|
| **Research/Math** | Seldon | Farnsworth → Vulcan |
| **Frontend** | Neo | Edna → Moebius |
| **Smart Contracts** | Flynn | Vulcan → Clu |
| **Backend/SDK** | Krennic | Scotty → Han |
| **Security** | Elliot | Kusanagi/Smith ↔ Trinity/Deckard |
| **Documentation** | Jocasta | Seldon (papers), Draper (social) |
| **Marketing** | Draper | Jocasta (content) |
