# Agent Guidelines

## Documentation

- **Root**: README.md only
- **Docs**: All documentation in `./docs/` (user-facing)
- **Code**: Implementation is the spec

---

## Package Manager - BUN ONLY

**⚠️ CRITICAL: Use `bun` EXCLUSIVELY.**
- ❌ NEVER use `npm` or `yarn`
- ✅ `bun install`, `bun add`, `bun run`

---

## Communication Style

**CRITICAL: Keep responses SHORT and CONCISE.**
- ❌ NO long summaries after tasks
- ❌ NO verbose explanations unless requested
- ✅ Brief status updates (1-2 lines)
- ✅ Ask questions when needed

---

## SDK as Source of Truth

**CRITICAL: All token/chain/contract metadata lives in SDK, not frontend.**

| Data | SDK File |
|------|----------|
| Token metadata | `sdk/src/eth/tokens.ts` |
| Token addresses | `sdk/src/eth/tokens.ts` |
| Chain configs | `sdk/src/eth/chains.ts` |
| Contract addresses | `sdk/src/eth/contracts.ts` |

**Rules:**
1. NEVER duplicate metadata in frontend
2. Always import from `@sdk/eth`
3. Add new tokens/chains/contracts to SDK only

---

## Frontend Stack

**CRITICAL: Pure Preact + Signals + UnoCSS ONLY**

### Core Dependencies (Keep Lean)
- ✅ **Framework**: Preact (pure, no compat layer)
- ✅ **State**: @preact/signals (fine-grained reactivity)
- ✅ **Styling**: UnoCSS with Wind preset (Tailwind syntax)
- ✅ **Components**: Custom headless UI (no Radix)
- ✅ **Charts**: TradingView Lightweight Charts + custom SVG charts
- ✅ **Markdown**: Backend-rendered (snarkdown, build-time)
- ✅ **Math**: asciimath2ml (~15KB) - AsciiMath → native MathML

### Forbidden Dependencies
- ❌ NO React (pure Preact only, zero compat)
- ❌ NO preact/compat (compile-time incompatibilities)
- ❌ NO React types or React DOM
- ❌ NO Radix UI or any React component libs
- ❌ NO Tailwind CSS (use UnoCSS)
- ❌ NO chart.js (use custom SVG)
- ❌ NO frontend markdown parsers (backend only)
- ❌ NO LaTeX renderers (use AsciiMath + MathML)

### Bundle Size
- Keep dependencies minimal
- Final bundle: <500KB gzipped
- Target: <400KB with aggressive Signal optimization

---

## Preact Signals & Reactivity

**Philosophy: Signal-first, performance-obsessed, zero synthetic events**

### Core Patterns

**1. Direct Signal Rendering (The Killer Feature)**
```tsx
import { signal } from '@preact/signals';

export const btcPrice = signal('$45,000');

export function PriceDisplay() {
  // Renders ONCE; text updates on signal change without re-render
  return <div>BTC: {btcPrice}</div>;
}
```
✅ **Why**: Preact binds directly to DOM text node, no VDOM diffing.
- Ideal for tickers, real-time quotes, streaming data
- Never pass `signal.value` to JSX—pass the signal itself

**2. Global Stores (Module Exports)**
```tsx
// lib/swap/SwapStore.ts - NO class, just signals
export const direction = signal<'buy' | 'sell'>('buy');
export const orderType = signal<OrderType>('market');
export const primaryTokens = signal<TokenData[]>([]);

// components/SwapForm.tsx
import { direction, orderType } from '@lib/swap/SwapStore';

export function SwapForm() {
  return (
    <select value={orderType}>
      <option>Market</option>
    </select>
  );
}
```
✅ **Why**: Avoids Context plumbing, keeps imports lean, signals are stable refs.

**3. Derived State (computed)**
```tsx
import { computed } from '@preact/signals';

// Recomputes only when `orderType` changes
export const orderLabel = computed(() => {
  return orderType.value === 'market' ? 'Market Order' : 'Limit Order';
});
```
✅ **Use instead of**: `useMemo`, helper functions in render.
✅ **Why**: Auto-tracked, auto-memoized, doesn't cause re-renders.

**4. Batch Updates (Multi-Signal Changes)**
```tsx
import { batch } from '@preact/signals';

function handleSwap() {
  batch(() => {
    direction.value = 'buy';
    orderType.value = 'market';
    primaryTokens.value = newTokens;
  });
  // DOM updates once after all three changes
}
```
✅ **Why**: Prevents partial UI flushes in tight loops (WebSocket handlers, tickers).

**5. Effects (Side-Effects from Signals)**
```tsx
import { effect } from '@preact/signals';

// Runs when direction changes, auto-cleanup on unmount
effect(() => {
  console.log(`Direction changed to: ${direction.value}`);
  // Return cleanup function if needed
  return () => console.log('Cleanup');
});
```
✅ **Use instead of**: `useEffect([direction])`.
✅ **Why**: Automatically tracks dependencies, no stale closures.

**6. Non-Reactive Reads (.peek())**
```tsx
// Read without subscribing (rare cases to prevent loops)
effect(() => {
  if (shouldLog.value) {
    // This won't re-run when priceHistory changes
    console.log(`Latest 10: ${priceHistory.peek()}`);
  }
});
```
✅ **Use for**: Preventing infinite effect loops, ref reads.

### Store Pattern (Recommended for DeFi)

```tsx
// lib/liquidity/LiquidityStore.ts
import { signal, computed } from '@preact/signals';

export class LiquidityStore {
  searchQuery = signal('');
  timeframe = signal<Timeframe>('24h');
  assets = signal<AssetData[]>([]);

  // Derived state—auto-memoized
  filteredAssets = computed(() =>
    this.assets.value.filter(a =>
      a.symbol.toLowerCase().includes(this.searchQuery.value.toLowerCase())
    )
  );

  setSearchQuery = (q: string) => {
    this.searchQuery.value = q;
  };
}

// Singleton instance
export const liquidityStore = new LiquidityStore();

// In components
import { liquidityStore } from '@lib/liquidity/LiquidityStore';

export function AssetList() {
  return (
    <div>
      {liquidityStore.filteredAssets.value.map(a => (
        <div key={a.id}>{a.symbol}: {a.price}</div>
      ))}
    </div>
  );
}
```

### Component Rendering (Zero Boilerplate)

**❌ BAD: Extract .value first (defeats reactivity)**
```tsx
const tokenIn = store.primaryTokens.value[0]?.symbol;
return <div>{tokenIn}</div>; // Re-renders when signal changes
```

**✅ GOOD: Pass signal or use direct .value in JSX**
```tsx
// Option 1: Pass signal (if component expects it)
return <TokenDisplay token={store.primaryTokens.value[0]} />;

// Option 2: Read .value inline where used
return <div>{store.primaryTokens.value[0]?.symbol}</div>;
```

### Optimization Checklist

- [ ] Global state: exported signals, not Context
- [ ] Text nodes: pass signals directly `{signal}`, never `{signal.value}`
- [ ] Derived state: use `computed()` for derived values
- [ ] Multi-writes: wrap in `batch()` for high-frequency streams
- [ ] Effects: use `effect()` instead of `useEffect()`
- [ ] Form inputs: `onInput` not `onChange`; `onDblClick` not `onDoubleClick`
- [ ] Event handlers: use native browser events (no synthetic)
- [ ] Store methods: keep simple, avoid closures in signals
- [ ] Component renders: aim for "render once" + signal updates

---

## UnoCSS Usage

**Why UnoCSS:**
- 10x smaller, faster HMR
- Tailwind v3 syntax compatibility
- On-demand CSS generation

**Config:** `front/uno.config.ts`
**Preset:** `@unocss/preset-wind`
**Import:** `virtual:uno.css` in `main.tsx`

Same Tailwind syntax works:
```tsx
<div className="flex items-center gap-2 px-4 py-2 bg-bg-1 border rounded-sm">
```

---

## Documentation Rendering

**CRITICAL: Markdown rendering in BACKEND, not frontend.**

- **Backend**: snarkdown (lightweight JS parser)
- **Build-time**: Compiled to HTML via `scripts/precompile-markdown.ts`
- **Frontend**: Receives pre-rendered HTML (zero parsing)

**Math Rendering:**
- AsciiMath ONLY (NOT LaTeX)
- asciimath2ml (~15KB) → native MathML
- Browser native rendering, zero overhead

**Build:**
```bash
bun run build:markdown      # Compile markdown
bun run build:search-index  # Build search index
```

---

## Custom Charts (SVG)

**CRITICAL: SVG charts, NOT chart.js**

**Types:** Sparklines ✅, Doughnuts 🔲, Bars 🔲, Heatmaps 🔲
**Location:** `src/components/charts/`
**Format:** SVG (easier to style)
**Size:** <100 lines each

Price charts: TradingView Lightweight Charts only

---

## Python Development (`./sim`)

**CRITICAL: Use `uv` ONLY**
- ❌ NEVER use pip/pip3 directly
- ✅ `uv pip install -e .`
- ✅ `uv run python3 script.py`

**Cython:**
- All AMM code uses `.pyx` (10-100x faster)
- Rebuild after changes: `uv pip install -e . --reinstall`

---

## Documentation Link Schema

**CRITICAL: Use canonical `/docs/slug#anchor` format**

✅ Correct:
```markdown
[Coverage Ratio](/docs/1.1.1-Inventory-Management#2.4-coverage-ratio)
```

❌ Incorrect:
```markdown
[Coverage Ratio](./1.1.1. Inventory Management.md#2.4-coverage-ratio)
```

---

## Code Philosophy

**Performance First. Elegant. Signal-Driven. DRY. Concise.**

- **Performance**: Signals > hooks; direct DOM > VDOM diffing
- **Lean**: Minimize re-renders; batch updates; computed derived state
- **DRY**: Extract common patterns; reuse computed signals
- **Minimal**: No unnecessary abstractions or helper wrappers
- **Generic**: Configurable solutions; avoid one-off utilities
- **Clean**: Consistent formatting; compact variable names
- **Silent**: No emojis; no verbose output unless errors

**Signal-First Ethos:**
- Prefer `signal()` over `useState()` for shared/reactive state
- Prefer `computed()` over `useMemo()` for derived values
- Prefer `effect()` over `useEffect()` for side-effects
- Pass signals to JSX (not `.value`), let Preact handle subscriptions
- Use `batch()` for multi-signal updates in event handlers
- Use `.peek()` sparingly (only to break reactive cycles)

---

## Development Stack

**Start:**
```bash
bun run dev  # From monorepo root
```

**Services:**
- `front`: Port 3000 (Vite + Preact)
- `back/collector`: Port 3001 (HTTP API + WebSocket)

**PWA Assets:**
```bash
cd front && bun run pwa-assets  # Regenerate from logo-b.svg
```

---

## Guidelines for Agents

1. Keep root clean (README.md only)
2. Use bun exclusively
3. Frontend: UnoCSS + Radix + Preact only
4. Doc links: `/docs/slug#anchor` format
5. Keep responses concise
