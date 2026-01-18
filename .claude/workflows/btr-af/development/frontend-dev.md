# Frontend Development Workflow

**Orchestrator**: Sybil → Neo (CTO + Frontend Lead)
**Implementation**: Edna (UX) + Moebius (Performance)

---

## Purpose

Frontend development: fix, feature, or refactor for Preact applications.

---

## When to Use This Workflow

| Type | Description | Example |
|------|-------------|---------|
| **Fix** | Bug fix, critical issue | Swap button disabled |
| **Feat** | New feature, enhancement | Add governance voting UI |
| **Refac** | Code improvement, optimization | Reduce bundle by 50KB |

---

## Workflow Steps

### Step 1: Task Definition (Sybil)

```
Sybil:
1. Define task: fix/feat/refac
2. Identify scope: Which components? Which routes?
3. Assign to Neo + team (Edna + Moebius)
4. Set acceptance criteria
```

### Step 2: Design/Spec (if feat) (Edna)

```
For NEW features:
Edna:
1. Design user journey, wireframes
2. Specify components, props, signals
3. Define success metrics
→ Output: Design spec approved by Neo
```

### Step 3: Implementation (Moebius)

```
Moebius:
1. WEBSEARCH: Latest Preact patterns, bundle optimization techniques
2. Implement in front/ using:
   - Preact (native, no compat)
   - @preact/signals for state
   - Tailwind CSS for styling
   - Custom atomic components (no Radix)
3. Follow signal-first patterns:
   - signals > useState
   - computed > useMemo
   - effect > useEffect
   - batch() for multi-updates
4. Target: <400KB gzipped bundle
```

### Step 4: Code Review (Neo)

```
Neo reviews Moebius's implementation:
1. Signal-first patterns used correctly?
2. Bundle size impact acceptable?
3. UX matches Edna's spec?
4. Type check passes (tsgo)
5. Lint passes (oxlint)
→ Approve or request changes
```

### Step 5: Testing (Edna + Moebius)

```
Edna + Moebius:
1. Manual testing: All user flows work
2. Browser testing: Chrome, Firefox, Safari, Brave
3. Mobile testing: Responsive, touch interactions
4. Accessibility: Keyboard nav, screen reader
→ Output: Test results
```

### Step 6: Documentation (Jocasta - if needed)

```
If user-facing feature:
Jocasta:
1. Document in docs/4. User Guides/
2. Include screenshots, step-by-step instructions
→ Output: Updated user guide
```

---

## Decision Rules

| Decision | Reviewers |
|----------|-----------|
| **Minor** (frontend-only) | Edna + Moebius (2 reviewers) |
| **Major** (cross-stack impact) | Neo + Flynn + Krennic + 2 specialists (5 reviewers) |

---

## Deliverables

| Output | Location |
|--------|----------|
| Implementation code | `front/src/` |
| Unit tests | `front/src/**/*.test.ts` |
| Updated docs (if needed) | `docs/4. User Guides/` |
| Commit | `[feat]` / `[fix]` / `[refac]` |

---

## Knowledge References

Consult your project's:
- `CONTRIBUTING.md` - Frontend standards and conventions
- Framework documentation for your chosen stack

---

## Commands

```bash
cd <your-frontend-directory>

bun run dev          # Development server
bun run typecheck    # Type check (tsgo)
bun run lint         # Lint (oxlint)
bun run build        # Production build
```

---

## Common Patterns

### Signal Store Pattern

```typescript
// Global store (singleton)
export class SwapStore {
  public readonly direction = signal<OrderDirection>('sell');
  public readonly amountIn = signal<string>('');
  public readonly quote = signal<Quote | null>(null);

  public readonly isValid = computed(() =>
    this.amountIn.value !== '' && this.quote.value !== null
  );
}

export const swapStore = new SwapStore();
```

### Direct Signal Rendering

```tsx
// Pass signals directly (not .value)
export function PriceDisplay() {
  return <div>BTC: {btcPrice}</div>;
}
```
