# Agent Guidelines

## Documentation
- **Root**: README.md only
- **Docs**: All in `./docs/` (user-facing)
- **Code**: Implementation = spec

---

## Package Manager
**⚠️ Use `bun` EXCLUSIVELY**
- ❌ NEVER npm/yarn
- ✅ `bun install|add|run`

---

## Communication
**Keep responses SHORT**
- ❌ NO long summaries/verbose explanations
- ✅ Brief status (1-2 lines), ask when needed

---

## SDK = Source of Truth
**All token/chain/contract metadata in SDK, NOT frontend**

| Data | SDK File |
|------|----------|
| Tokens/addresses/metadata | `sdk/src/eth/tokens.ts` |
| Chain configs | `sdk/src/eth/chains.ts` |
| Contract addresses | `sdk/src/eth/contracts.ts` |

**Rules**: Never duplicate in frontend; always import from `@sdk/eth`

---

## Frontend Stack
**Pure Preact + Signals + UnoCSS ONLY**

### Core Deps (Keep Lean)
- ✅ Framework: Preact (no compat)
- ✅ State: @preact/signals
- ✅ Styling: UnoCSS w/ Wind preset
- ✅ Components: Custom headless (no Radix)
- ✅ Charts: TradingView Lightweight + SVG
- ✅ Markdown/Math/Mermaid: Backend-compiled

### Forbidden
- ❌ React/preact-compat/React types
- ❌ Radix UI or React component libs
- ❌ Tailwind/chart.js/frontend markdown parsers (marked, markdown-wasm, prismjs, mermaid)
- ❌ LaTeX (use AsciiMath + MathML, rendered at build-time)

### Bundle Target
- Final: <500KB gzipped (target <400KB)

---

## Preact Signals & Reactivity
**Philosophy: Signal-first, zero synthetic events**

### Core Patterns

**1. Direct Signal Rendering** (Preact binds directly to DOM, no VDOM diffing)
```tsx
export const btcPrice = signal('$45,000');
export function PriceDisplay() {
  return <div>BTC: {btcPrice}</div>; // Renders once, updates without re-render
}
```

**2. Global Stores** (Module exports, no Context plumbing)
```tsx
export const direction = signal<'buy'|'sell'>('buy');
export const orderType = signal<OrderType>('market');
// Import anywhere: import { direction, orderType } from '@lib/swap/SwapStore'
```

**3. Derived State** (Auto-memoized computed signals)
```tsx
export const orderLabel = computed(() =>
  orderType.value === 'market' ? 'Market Order' : 'Limit Order'
);
```

**4. Batch Updates** (Coalesce multi-signal writes)
```tsx
batch(() => {
  direction.value = 'buy';
  orderType.value = 'market';
  primaryTokens.value = newTokens;
}); // DOM updates once
```

**5. Effects** (Auto-track dependencies, optional cleanup)
```tsx
effect(() => {
  console.log(`Direction: ${direction.value}`);
  return () => console.log('Cleanup');
});
```

**6. Non-Reactive Reads** (Break reactive cycles)
```tsx
effect(() => {
  if (shouldLog.value) {
    console.log(`Latest: ${priceHistory.peek()}`); // Won't re-run
  }
});
```

### Store Pattern
```tsx
export class LiquidityStore {
  searchQuery = signal('');
  assets = signal<AssetData[]>([]);

  filteredAssets = computed(() =>
    this.assets.value.filter(a => a.symbol.includes(this.searchQuery.value))
  );
}

export const liquidityStore = new LiquidityStore();
```

### Optimization Checklist
- [ ] Global state: exported signals, not Context
- [ ] Text nodes: pass signals `{signal}`, not `{signal.value}`
- [ ] Derived: use `computed()` not `useMemo()`
- [ ] Multi-writes: wrap in `batch()`
- [ ] Effects: `effect()` not `useEffect()`
- [ ] Forms: `onInput`/`onDblClick` (not `onChange`/`onDoubleClick`)
- [ ] Events: native browser events only
- [ ] Renders: "render once" + signal updates

---

## UnoCSS
**Why**: 10x smaller, faster HMR, Tailwind v3 syntax
- **Config**: `front/uno.config.ts`
- **Preset**: `@unocss/preset-wind`
- **Import**: `virtual:uno.css`

---

## Build-Time Compilation
**Zero runtime deps for content: markdown → HTML, AsciiMath → MathML, Mermaid → SVG at build time**

### Markdown Compilation
- **Script**: `scripts/precompile-markdown.ts` (backend only)
- **Process**:
  - Parses markdown with `marked`
  - Syntax highlights with `prismjs` (JS/TS/JSX/TSX/JSON/Bash/SQL/Markdown/Solidity)
  - Converts inline math ($...$) and block math ($$...$$) to MathML using `asciimath2ml`
  - Renders mermaid diagrams to themed SVG (light/dark) via Playwright
  - Generates heading anchors with IDs
- **Output**: `/front/public/compiled-docs/docs.json` (pre-rendered HTML)
- **Frontend**: Uses `MarkdownRenderer` component that loads pre-compiled HTML from JSON (NO parsing)

### Frontend Markdown Usage
```tsx
// Load by slug from pre-compiled docs
<MarkdownRenderer slug="overview" />

// Or pass pre-rendered HTML directly
<MarkdownRenderer content="<p>...</p>" />
```
**Key**: Frontend has ZERO markdown dependencies (`marked`, `prismjs`, `asciimath2ml`, `mermaid` only in backend)

### Search Index
- **Script**: `scripts/build-search-index.ts`
- **What**: Extracts frontmatter, strips markdown, builds full-text search index
- **Output**: Searchable JSON metadata

### Build Chain
```bash
bun run build
# Runs: build:markdown → build:search-index → vite build
```

**Dependencies**:
- ✅ Backend (`package.json`): marked, prismjs, asciimath2ml, playwright, mermaid
- ❌ Frontend (`front/package.json`): NONE of the above (pre-compiled only)

---

## SVG Charts
**SVG, NOT chart.js**
- **Types**: Sparklines ✅, other charts 🔲
- **Location**: `src/components/charts/`
- **Size**: <100 lines each
- **Price**: TradingView Lightweight Charts (only external for price data)

---

## Python (`./sim`)
**Use `uv` ONLY**
- ❌ NEVER pip/pip3
- ✅ `uv pip install -e .`
- ✅ `uv run python3 script.py`

**Cython**: All AMM code `.pyx` (10-100x faster); rebuild: `uv pip install -e . --reinstall`

---

## Doc Link Schema
**Format**: `/docs/slug#anchor`

✅ `[Coverage Ratio](/docs/1.1.1-Inventory-Management#2.4-coverage-ratio)`
❌ `[Coverage Ratio](./1.1.1. Inventory Management.md#2.4-coverage-ratio)`

---

## Code Philosophy
**Performance. Elegant. Signal-Driven. DRY. Concise.**

**Signal-First Ethos**:
- `signal()` > `useState()` for shared/reactive state
- `computed()` > `useMemo()` for derived values
- `effect()` > `useEffect()` for side-effects
- Pass signals to JSX (not `.value`)
- `batch()` for multi-signal updates
- `.peek()` sparingly (break reactive cycles)

**Best Practices**: Performance first; lean; minimize re-renders; DRY; no over-abstraction; consistent formatting; silent (no emojis/verbose)

---

## Dev Stack

**Start**: `bun run dev`

**Services**:
- `front`: Port 3000 (Vite + Preact)
- `back/collector`: Port 3001 (HTTP + WS)

**PWA**: `cd front && bun run pwa-assets`

---

## Agent Checklist
1. Root clean (README.md only)
2. Bun exclusively
3. Frontend: Preact + Signals + UnoCSS
4. Backend compilation: markdown → HTML, math → MathML, Mermaid → SVG
5. Doc links: `/docs/slug#anchor`
6. Concise responses
