# Documentation Workflow

**Orchestrator**: Sybil → Jocasta (Technical Writer + DeFi Education)
**Support**: Seldon (Research papers), Draper (Marketing content)

---

## Purpose

Maintain and improve public documentation: user guides, API docs, research papers, and consistency checks with code.

---

## When to Use This Workflow

| Trigger | Description |
|---------|-------------|
| Code change | Documentation must match implementation |
| New feature | User guides, API docs needed |
| Research complete | Research paper, technical write-up |
| Inconsistency | Docs don't match code reality |
| Campaign | Marketing content, educational material |

---

## Workflow Steps

### Step 1: Documentation Request (Sybil)

```
Sybil:
1. Identify documentation need: What changed? What needs docs?
2. Assign to Jocasta + relevant domain expert
3. Set scope: User guide, API doc, research paper, or all
```

### Step 2: Content Planning (Jocasta)

```
Jocasta:
1. WEBSEARCH: Documentation best practices, Diátaxis framework
2. Plan content structure:
   - Concepts: Explain WHY
   - Tutorials: Step-by-step learning
   - How-to guides: Task-oriented goals
   - Reference: Technical lookup
3. Identify diagrams needed (Mermaid, rendered at build time)
4. Plan math notation (AsciiMath with WHERE blocks)
→ Output: Content outline
```

### Step 3: Draft Content (Jocasta + Domain Expert)

```
Jocasta works with relevant expert:
- Farnsworth/Seldon: Research papers, quant concepts
- Vulcan: Smart contract docs, API references
- Neo/Moebius: Frontend guides, integration docs
- Krennic: Backend API docs
- Draper: Marketing content, social posts

1. Write content following Diátaxis framework
2. Use proper formatting:
   - /docs/slug#anchor links (no file extensions)
   - AsciiMath for math with WHERE blocks
   - Mermaid diagrams (rendered to SVG)
   - Code examples with syntax highlighting
3. Ensure frontmatter for SEO (title, description, slug, tags)
→ Output: Draft documentation
```

### Step 4: Code Consistency Check (Jocasta + Domain Expert)

```
Jocasta with domain expert:
1. Verify docs match current code implementation
2. Check all code examples are accurate and runnable
3. Validate all cross-references work
4. Update if code has changed
→ Output: Consistent documentation
```

### Step 5: Review (Sybil + Jocasta)

```
Sybil reviews:
1. Accuracy: Is content technically correct?
2. Clarity: Can target audience understand?
3. Completeness: What's missing?
4. Style: Follows DOCUMENTATION.md standards

Approve or request revisions
→ Output: Approved documentation
```

### Step 6: Build-Time Compilation (Automated)

```
Backend compiles at build time:
1. Markdown → HTML (via marked)
2. AsciiMath → MathML (via asciimath2ml)
3. Mermaid → SVG (via Playwright)
4. Output: /front/public/compiled-docs/docs.json
```

---

## Deliverables

| Output | Location | Owner |
|--------|----------|-------|
| User guides | `docs/4. User Guides/` | Jocasta |
| API docs | `docs/` or auto-generated | Jocasta + Vulcan |
| Research papers | `docs/1. AIMM/` | Jocasta + Seldon |
| Marketing content | Social media, blog posts | Jocasta + Draper |
| Code docs | NatSpec in contracts/ | Vulcan |

---

## Knowledge References

Consult your project's:
- `CONTRIBUTING.md` - Documentation standards
- Diátaxis Framework - Documentation best practices

---

## Diátaxis Framework

| Type | Purpose | Example |
|------|---------|---------|
| **Concepts** | Explain WHY | How AMMs work, capital efficiency theory |
| **Tutorials** | Step-by-step learning | First swap, providing liquidity |
| **How-to guides** | Task-oriented goals | Integrate SDK, deploy contracts |
| **Reference** | Technical lookup | API endpoints, function signatures |

---

## Link Format

```markdown
✅ CORRECT
[Inventory Management](/docs/1.1.1-inventory-management)
[Spread & Fees §3](/docs/1.1.4-spread-fees#3-spread-calculation)

❌ WRONG
[Inventory Management](./1.1.1.%20Inventory%20Management.md)
```

---

## Math Notation

```asciimath
S_v = 100 + {sigma_p * nu}/{100M}

WHERE
S_v = "volatility band (basis points)"
sigma_p = "path volatility"
nu = max(nu_i, nu_o) "vega, endpoint-only"
```

---

## NatSpec Requirements

All public contract functions must have:

```solidity
/// @notice Clear one-line description
/// @dev Implementation details (if non-trivial)
/// @param asset Address of asset to deposit
/// @param amount Amount of asset to deposit (with decimals)
/// @return lpTokens Number of LP tokens minted
function deposit(address asset, uint256 amount)
    external returns (uint256 lpTokens)
```
