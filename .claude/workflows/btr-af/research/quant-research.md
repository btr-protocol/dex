# Quant Research Workflow

**Orchestrator**: Sybil (CEO + Research Lead)
**Research Task Force**: Farnsworth (Visionary) → Seldon (Rigorist) → Vulcan (Implementation)

---

## Purpose

Conceptual and quantitative research for AMM comparisons, capital efficiency formalization, DEX design, liquidity pool mechanics, and simulations.

---

## When to Use This Workflow

| Trigger | Description |
|---------|-------------|
| New theory | Proposed AMM innovation, capital efficiency model |
| Comparison | AMM vs AMM, AMM vs order books, protocol comparisons |
| Design | Multi-asset pools, single-sided deposits, liability management |
| Formalization | Mathematical proofs, invariants, parameter optimization |
| Simulation | Backtesting, Monte Carlo, stress testing |

---

## Workflow Steps

### Step 1: Research Initiation (Sybil)

```
Sybil:
1. Clarify research question/objective
2. Identify relevant domain (AMM, pricing, risk, capital efficiency)
3. Assign Research Task Force: Farnsworth + Seldon (+ Vulcan if implementation needed)
4. Set deliverable: theory spec, math proof, simulation, or all
```

### Step 2: Visionary Exploration (Farnsworth)

```
Farnsworth:
1. WEBSEARCH: Latest research, unconventional approaches, cross-domain innovations
2. Question consensus: "Why do DEXs use pairs?" "What if liquidity flows dynamically?"
3. Propose radical theory from first principles
4. Document conceptual framework with clear assumptions
```

### Step 3: Mathematical Validation (Seldon)

```
Seldon:
1. WEBSEARCH: Mathematical foundations, latest papers, stress test methodologies
2. Formalize Farnsworth's theory: definitions, axioms, theorems
3. Prove claims mathematically or empirically
4. Stress test: edge cases, black swans, adversarial conditions
5. Document: AIMM_FORMULA_SPEC.md, parameters, invariants
```

### Step 4: Implementation Feasibility (Vulcan)

```
Vulcan (if implementation required):
1. WEBSEARCH: Implementation patterns, gas optimization, simulation frameworks
2. Assess feasibility: Can this be implemented on-chain/off-chain?
3. Specify data structures, algorithms, performance characteristics
4. Coordinate with Seldon on spec alignment
```

### Step 5: Research Review (Sybil + Task Force)

```
Sybil convenes Research Task Force:
1. Farnsworth presents: Visionary theory
2. Seldon presents: Mathematical validation + stress test results
3. Vulcan presents: Implementation feasibility (if applicable)
4. Sybil validates: Strategic alignment with BTR goals
5. Consensus: Approve, revise, or reject
```

### Step 6: Documentation (Jocasta)

```
Jocasta:
1. Work with Seldon on research paper format
2. Document in docs/1. AIMM/ or appropriate section
3. Include: motivation, theory, proofs, simulations (if applicable)
4. Ensure AsciiMath syntax with WHERE blocks
```

---

## Deliverables

| Output | Template | Owner |
|--------|----------|-------|
| Theory spec | `docs/1. AIMM/[topic].md` | Farnsworth |
| Math proof | `docs/1. AIMM/[topic]-proof.md` | Seldon |
| Simulation | `sim/[topic].py` or Zig | Seldon + Vulcan |
| Research paper | Peer-reviewable format | Jocasta + Seldon |

---

## Knowledge References

Consult your project's:
- `CONTRIBUTING.md` - Quant research standards
- Academic resources - Latest papers, mathematical foundations

---

## Example Research Topics

- **AMM Comparisons**: Uniswap vs Curve vs Balancer vs AIMM
- **Single-Sided Deposits**: Asset-liability management framework
- **Anchor Path Pricing**: Multi-asset routing efficiency
- **Capital Efficiency**: Formal optimization of LP returns
- **Toxic Flow Mitigation**: Adverse selection protection mechanisms
