# Components Architecture

## Domain-Driven Atomic Design

This folder follows a 4-tier component organization for consistency, maintainability, and clear separation of concerns.

### Tier 1: `ui/` - Pure Design Atoms

**Purpose:** Stateless, domain-agnostic UI components. Zero business logic.

**Examples:**
- `Button/` - Generic button with variants
- `Input/` - Form input
- `Dialog.tsx` - Modal dialog base
- `Icon.tsx` - Icon renderer
- `Tooltip.tsx` - Tooltip primitive

**Guidelines:**
- No signals, context, or API calls
- No domain knowledge (doesn't know about "tokens" or "chains")
- Focused on styling and interaction
- Fully typed with Props interfaces
- Use `ui/index.ts` for barrel export

**Import Pattern:**
```tsx
import { Button, Icon } from '@components/ui';
```

---

### Tier 2: `shared/` - Domain-Aware Atoms

**Purpose:** Reusable components that know about domain concepts (Tokens, Chains, Metrics) but don't own business logic. Used across multiple features.

**Subfolders:**
- `token/` - TokenRow, TokenSelector, PairSelector
- `chain/` - ChainBadge
- `metrics/` - CoverageGauge, Sparkline, HealthPopover
- `ui-utilities/` - ViewEmptyState, ParameterShaper

**Guidelines:**
- Can import from `ui/` freely
- Can use signals for local state (styling/visibility)
- No API calls (data passed as props)
- Represent reusable patterns across features
- Each subfolder has its own `index.ts` for public API

**Import Pattern:**
```tsx
import { TokenRow } from '@components/shared/token';
import { ChainBadge } from '@components/shared/chain';
import { CoverageGauge } from '@components/shared/metrics';
```

---

### Tier 3: `features/` - Logic-Heavy Modules

**Purpose:** Feature-specific, logic-heavy organisms. Each feature owns its state, hooks, and sub-components.

**Current Features:**
- `swap/` - Swap interface (SwapForm + sub-components + store)
- `liquidity/` - Liquidity management
- `chart/` - Price chart & trading tools
- `docs/` - Documentation & navigation
- `search/` - Global search modal
- `modals/` - Modal dialogs (Settings, Disclaimer, etc.)
- `wallet/` - Wallet connection UI

**Mandatory Submodule Pattern:**

Each feature folder MUST follow this structure:

```
features/swap/
├── index.ts              # Public API (ONLY export the main component)
├── SwapForm.tsx          # Main component (View)
├── DirectionToggle.tsx   # Private sub-component
├── AddTokenButton.tsx    # Private sub-component
├── TokenList.tsx         # Private sub-component
└── PlusSeparator.tsx     # Private sub-component
```

**Key Rules:**
1. **Main component in `index.ts`** - Export ONLY the public-facing component
2. **Sub-components are private** - Not exported, not imported directly
3. **Signals for state** - Use Preact signals (no useState)
4. **No generic props** - Create specific implementations instead
5. **Extract pure logic** - Move utilities to `.utils.ts` files if logic > 30 lines

**Import Pattern:**
```tsx
// ✅ CORRECT - Import from feature root
import { SwapForm } from '@components/features/swap';

// ❌ WRONG - Don't import internals
import { DirectionToggle } from '@components/features/swap/DirectionToggle';
```

---

### Tier 4: `layout/` - App Shell

**Purpose:** Static page templates and structural components.

**Components:**
- `Header.tsx` - Top navigation bar
- `Footer.tsx` - Bottom footer
- `PageContainer.tsx` - Page layout wrapper

**Guidelines:**
- Router-aware (can use useRouter)
- Highest-level composition
- Usually wrap multiple features

**Import Pattern:**
```tsx
import { Header, Footer, PageContainer } from '@components/layout';
```

---

## Import Organization

### ✅ Preferred Imports

```tsx
// From top-level barrel (ui, layout)
import { Button, Icon } from '@components/ui';
import { Header, Footer } from '@components/layout';

// From shared subfolders
import { TokenRow } from '@components/shared/token';
import { ChainBadge } from '@components/shared/chain';

// From specific features (not barrel)
import { SwapForm } from '@components/features/swap';
import { DocsLayout } from '@components/features/docs';
```

### ❌ Avoid These

```tsx
// Don't import sub-components
import { DirectionToggle } from '@components/features/swap/DirectionToggle';

// Don't barrel everything
import * from '@components/features';
```

---

## Guidelines & Best Practices

### 1. Component Size Limits

- **ui/ atoms:** < 100 lines
- **shared/ components:** < 150 lines
- **features/:** No limit, but split large features into sub-components
- If a file exceeds limits, break it into smaller pieces

### 2. Signals Over Props

Use Preact signals for local state:

```tsx
// shared/token/TokenRow.tsx
import { signal } from '@preact/signals';

export function TokenRow({ token, onSelect }: Props) {
  const isHovered = signal(false);

  return (
    <div onMouseEnter={() => isHovered.value = true}>
      {/* ... */}
    </div>
  );
}
```

### 3. Extract Pure Functions

If logic exceeds 30 lines, extract to `.utils.ts`:

```
features/docs/
├── index.ts
├── DocsLayout.tsx
├── NavPanel.tsx
├── search.utils.ts       # Pure functions for search logic
└── markdown.utils.ts     # Markdown helpers
```

### 4. No Index.ts Overuse

Only create `index.ts` if:
- Folder has 2+ exported components, OR
- Components are part of a cohesive module

**Don't do this:**
```
features/swap/
├── index.ts    (exports only one thing)
└── SwapForm.tsx
```

Instead, import directly:
```tsx
import { SwapForm } from '@components/features/swap/SwapForm';
```

### 5. Generic Component Anti-Pattern

❌ **Bad:** 20-prop generic "SelectionModal" used for everything

✅ **Good:** Specific implementations
```
ui/SelectionModal.tsx        # Base component (4 props)
shared/token/TokenSelectorModal.tsx  # Specific (uses SelectionModal)
```

---

## Moving Files

When adding a new component, ask:

1. **Is it purely presentational?** → `ui/`
2. **Is it domain-aware but reusable?** → `shared/{domain}/`
3. **Is it logic-heavy or feature-specific?** → `features/{feature}/`
4. **Is it structural/layout?** → `layout/`

---

## Cleanup Rules

- Delete `index.ts` if folder has only 1 component
- Don't export internals from `features/` modules
- Keep components close to where they're used
- Move domain-aware atoms to `shared/` when used in 2+ features
