# Backend Development Workflow

**Orchestrator**: Sybil → Krennic (Backend Tech Lead)
**Implementation**: Scotty (Systems Craft) + Han (DevOps)

---

## Purpose

Backend development: fix, feature, or refactor for Bun + TypeScript services.

---

## When to Use This Workflow

| Type | Description | Example |
|------|-------------|---------|
| **Fix** | Bug fix, critical issue | WebSocket connection drops |
| **Feat** | New feature, enhancement | Add price collector service |
| **Refac** | Code improvement, optimization | Reduce memory usage |
| **Ops** | CI/CD, deployment, infrastructure | Add monitoring alerts |

---

## Workflow Steps

### Step 1: Task Definition (Sybil)

```
Sybil:
1. Define task: fix/feat/refac/ops
2. Identify scope: Which services? Which endpoints?
3. Assign to Krennic + team (Scotty + Han)
4. Set acceptance criteria
```

### Step 2: Architecture Review (Krennic)

```
Krennic:
1. WEBSEARCH: Backend patterns, Bun best practices, security standards
2. Review SDK as source of truth: Tokens, chains, contracts metadata in sdk/
3. Design API endpoints, data flow, error handling
4. Identify edge cases: What can fail? How do we handle it?
→ Output: Architecture spec approved by Neo (if cross-stack)
```

### Step 3: Implementation (Scotty)

```
Scotty:
1. WEBSEARCH: Backend security, authentication, resilience patterns
2. Implement in back/ using:
   - Bun (not npm)
   - TypeScript + tsgo for type checking
   - WebSocket for real-time
   - SQLite for data (bun:sqlite)
3. Security baseline:
   - Authentication on every endpoint
   - Rate limiting
   - Parameterized queries (SQL injection prevention)
   - Private keys never touch disk (HSM/KMS only)
4. Resilience:
   - Circuit breakers for external services
   - Proper error handling and logging
5. Correctness over cleverness
→ Output: Working backend code
```

### Step 4: CI/CD & Deployment (Han)

```
Han:
1. WEBSEARCH: CI/CD patterns, deployment strategies
2. Implement/update pipelines:
   - Fast feedback loops
   - One-command reproducible deployments
   - Environment parity (dev/staging/prod)
3. Release automation: Versioning, changelog, rollback procedures
→ Output: Automated deployment pipeline
```

### Step 5: Review (Krennic)

```
Krennic reviews Scotty + Han's work:
1. Robustness: Edge cases handled? Error paths tested?
2. Security: Authentication, rate limiting, audit trails?
3. SDK alignment: Does this use sdk/ as source of truth?
4. Delivery: Is this production-ready?
→ Approve or request changes
```

### Step 6: Testing (Scotty + Han)

```
Scotty + Han:
1. Unit tests: All functions covered
2. Integration tests: End-to-end flows
3. Load testing: Performance under stress
4. Security testing: Auth bypass, SQL injection attempts
→ Output: Test results
```

---

## Decision Rules

| Decision | Reviewers |
|----------|-----------|
| **Minor** (backend-only) | Scotty + Han (2 reviewers) |
| **Major** (cross-stack) | Neo + Flynn + Krennic + 2 specialists (5 reviewers) |

---

## Deliverables

| Output | Location |
|--------|----------|
| Implementation code | `back/` |
| Tests | `back/**/*.test.ts` |
| CI/CD config | `.github/workflows/`, `Dockerfile` |
| Updated SDK (if needed) | `sdk/` |
| Commit | `[feat]` / `[fix]` / `[refac]` / `[ops]` |

---

## Knowledge References

Consult your project's:
- `CONTRIBUTING.md` - Backend standards and conventions
- Security documentation - Security patterns and practices

---

## Commands

```bash
cd <your-project-root>

bun run dev          # Start front + back
bun run build        # Build all modules
bun run typecheck    # Type check all
bun run lint         # Lint all
```

---

## SDK = Source of Truth

| Data | SDK File | Frontend Usage |
|------|----------|----------------|
| Tokens/addresses | `sdk/src/eth/tokens.ts` | Import, never duplicate |
| Chain configs | `sdk/src/eth/chains.ts` | Import, never duplicate |
| Contract addresses | `sdk/src/eth/contracts.ts` | Import, never duplicate |
