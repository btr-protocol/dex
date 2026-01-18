# Brand & UX Design Workflow

**Orchestrator**: Sybil (CEO) → Neo (CTO + Frontend Lead)
**Design Team**: Edna (UX/Brand) + Moebius (Frontend Design)

---

## Purpose

Translate conceptual research into visual identity, user journeys, and UI/UX design that align with BTR's capital efficiency mission.

---

## When to Use This Workflow

| Trigger | Description |
|---------|-------------|
| New feature | Designing UX for new protocol features |
| Rebrand | Visual identity updates, design system evolution |
| User journey | Mapping theoretical user flows to concrete UI |
| Optimization | Improving conversion, clarity, accessibility |

---

## Workflow Steps

### Step 1: Design Brief (Sybil + Research Task Force)

```
Sybil with Farnsworth + Seldon:
1. Define feature: What are we building? (e.g., single-sided LP)
2. Identify user: Who is this for? (institutional, retail, both)
3. User value proposition: Why does this matter?
4. Constraints: Technical, regulatory, brand
→ Output: Design brief with user stories
```

### Step 2: User Journey Mapping (Edna)

```
Edna:
1. WEBSEARCH: UX patterns for DeFi, DEX best practices, accessibility standards
2. Map user journey: Discovery → Understanding → Action → Confirmation
3. Identify pain points: Where do users drop off? What confuses them?
4. Design for both audiences:
   - Institutional: Trust, clarity, gas in USD, pre-transaction simulation
   - Retail: Simplicity, mobile-first, clear error messages
→ Output: User journey map + wireframes
```

### Step 3: Visual Design (Edna + Moebius)

```
Edna (UX focus) + Moebius (visuals):
1. Design system consistency: Colors, typography, components
2. Transaction clarity: Gas, slippage, price impact visualization
3. Error states: Actionable messages (never "transaction failed")
4. Accessibility: WCAG AA, keyboard nav, screen readers
→ Output: Figma designs / Component specs
```

### Step 4: Performance Review (Moebius)

```
Moebius:
1. Challenge designs: "This adds 47KB. Here's a 2KB alternative that looks better."
2. Bundle target: <400KB gzipped - every KB earns its place
3. Core Web Vitals: LCP < 2.5s, FID < 100ms, CLS < 0.1
→ Output: Performance budget + implementation notes
```

### Step 5: Design Review (Neo + Team)

```
Neo with Edna + Moebius:
1. Review: UX clarity, visual polish, performance trade-offs
2. Validate: Does this match design brief? User stories met?
3. Approve: Ready for frontend implementation
→ Output: Approved design + implementation spec
```

### Step 6: Handoff to Frontend (Moebius)

```
Moebius implements (Edna reviews):
1. Atomic components in Preact + Signals
2. Idiomatic code: signals > useState, computed > useMemo
3. Tailwind CSS for styling (no component library bloat)
→ Output: Production-ready frontend code
```

---

## Deliverables

| Output | Template | Owner |
|--------|----------|-------|
| Design brief | Markdown with user stories | Sybil + Research |
| User journey map | Flowchart/diagram | Edna |
| Wireframes | Figma / Markdown specs | Edna |
| Component specs | Props, signals, behavior | Edna + Moebius |
| Performance budget | KB targets, Core Web Vitals | Moebius |
| Implemented code | Preact components | Moebius |

---

## Knowledge References

Consult your project's:
- `CONTRIBUTING.md` - Frontend standards and conventions
- Design system documentation - Visual identity guidelines

---

## Design Principles

| Principle | Description |
|-----------|-------------|
| **Dual audience** | Institutional (trust) AND retail (simplicity) |
| **Transaction safety** | Gas in USD, slippage as range, pre-simulation |
| **Accessibility** | WCAG AA, keyboard nav, screen readers |
| **Performance** | <400KB bundle, 60fps UI, instant feedback |
| **No bloat** | Every component earns its bytes |
