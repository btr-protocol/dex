# Preact Signals Migration Guide

> **Goal:** Optimize front-end reactivity by migrating from `useState` to `@preact/signals` for better performance and fine-grained updates.

## Why Signals?

### Problems with useState
1. **Cascading Re-renders:** Multiple `setState` calls trigger multiple render cycles
2. **Object Recreation:** Map/Set state requires recreation on every update
3. **Derived State Overhead:** `useMemo` dependencies can cause unnecessary recomputations
4. **Bundle Size:** `memo()` from `preact/compat` adds overhead

### Signals Benefits
1. **Batched Updates:** `batch()` groups multiple signal updates into single render
2. **Fine-Grained Reactivity:** Components only re-render when signals they access change
3. **Computed Values:** `computed()` automatically tracks dependencies
4. **No Compat Needed:** Core Preact primitive, zero overhead

---

## Core Patterns

### Pattern 1: Store Classes with Signals

**Before (7 useState calls):**
```typescript
export function useSwap() {
  const [quote, setQuote] = useState(null);
  const [quoteLoading, setQuoteLoading] = useState(false);
  const [quoteError, setQuoteError] = useState(null);
  const [swapLoading, setSwapLoading] = useState(false);
  const [swapError, setSwapError] = useState(null);
  const [needsApproval, setNeedsApproval] = useState(false);
  const [approveLoading, setApproveLoading] = useState(false);

  // Cascading updates (4 re-renders!)
  setQuoteLoading(true);
  setQuoteError(null);
  // ... fetch ...
  setQuote(data);
  setQuoteLoading(false);
}
```

**After (QuoteStore with batched signals):**
```typescript
import { signal, computed, batch } from '@preact/signals';

export class QuoteStore {
  public quote = signal(null);
  public quoteLoading = signal(false);
  public quoteError = signal(null);
  public swapLoading = signal(false);
  public swapError = signal(null);
  public needsApproval = signal(false);
  public approveLoading = signal(false);

  // Computed signals (auto-update)
  public isQuoteValid = computed(() =>
    this.quote.value !== null &&
    this.quoteError.value === null &&
    !this.quoteLoading.value
  );

  // Batched update method (1 render!)
  public setQuoteSuccess(quote) {
    batch(() => {
      this.quote.value = quote;
      this.quoteError.value = null;
      this.quoteLoading.value = false;
    });
  }
}

// Hook usage
export function useSwap() {
  const store = useMemo(() => new QuoteStore(), []);

  return {
    quote: store.quote.value,
    quoteLoading: store.quoteLoading.value,
    // ... other signals
  };
}
```

**Impact:** 7 states → 1 store, 4 re-renders → 1 re-render

---

### Pattern 2: Computed Signals for Derived State

**Before (useMemo with dependencies):**
```typescript
const filteredAssets = useMemo(() => {
  const query = searchQuery.toLowerCase();
  return assets.filter(a => a.symbol.toLowerCase().includes(query));
}, [assets, searchQuery]); // Manual dependency tracking
```

**After (computed with automatic tracking):**
```typescript
import { signal, computed } from '@preact/signals';

const searchQuery = signal('');
const assets = signal([]);

const filteredAssets = computed(() => {
  const query = searchQuery.value.toLowerCase();
  return assets.value.filter(a => a.symbol.toLowerCase().includes(query));
}); // Auto-tracks dependencies!

// Usage in JSX - no .value needed (direct binding)
<div>{filteredAssets}</div>
```

**Impact:** Automatic dependency tracking, no manual deps array

---

### Pattern 3: Batching Multiple Updates

**Before (multiple state setters):**
```typescript
// 3 separate re-renders
setLoading(true);
setError(null);
setData(result);
```

**After (batched signal updates):**
```typescript
import { batch } from '@preact/signals';

batch(() => {
  loading.value = true;
  error.value = null;
  data.value = result;
}); // 1 render!
```

---

### Pattern 4: Signal-based Stores (Singleton)

```typescript
// src/lib/swap/QuoteStore.ts
export class QuoteStore {
  public quote = signal(null);
  // ... other signals

  public reset() {
    batch(() => {
      this.quote.value = null;
      this.quoteLoading.value = false;
      // ... reset all signals
    });
  }
}

// Singleton instance
export const quoteStore = new QuoteStore();

// Usage in components
import { quoteStore } from '@/lib/swap/QuoteStore';

export function SwapForm() {
  // Direct access, no hook needed
  return <div>{quoteStore.quote}</div>;
}
```

---

### Pattern 5: Direct Signal Binding (Bypass VDOM)

**Key Optimization:** Passing signal objects directly to JSX bypasses Virtual DOM diffing

**Before (subscribes component):**
```typescript
<span>{price.value}</span> // Component re-renders on price change
```

**After (direct binding):**
```typescript
<span>{price}</span> // Updates in-place, no component re-render!
```

**Use cases:** High-frequency updates (price tickers, crosshair, live charts)

---

## Migration Checklist

### 1. Identify Candidates

**High Priority (useState → Signal Store):**
- ✅ Multiple related states (7+ useState in useSwap)
- ✅ Cascading state updates (quote → loading → error)
- ✅ High-frequency updates (price feeds, chart data)
- ✅ Map/Set-based state (unnecessary recreation)

**Medium Priority (useMemo → computed):**
- ✅ Derived/filtered data (search results, sorted lists)
- ✅ Complex computations with dependencies
- ✅ Values used in multiple places

**Low Priority (Keep as useState):**
- ❌ Modal open/close (low frequency)
- ❌ Single boolean flags (minor benefit)
- ❌ Form input values (unless high-frequency)

### 2. Create Store Class

```typescript
// src/lib/[feature]/[Feature]Store.ts
import { signal, computed, batch } from '@preact/signals';

export class FeatureStore {
  // 1. Define signals
  public data = signal(null);
  public loading = signal(false);
  public error = signal(null);

  // 2. Add computed signals
  public isReady = computed(() =>
    this.data.value !== null && !this.loading.value
  );

  // 3. Batch update methods
  public setData(d, err = null) {
    batch(() => {
      this.data.value = d;
      this.error.value = err;
      this.loading.value = false;
    });
  }

  // 4. Reset method
  public reset() {
    batch(() => {
      this.data.value = null;
      this.loading.value = false;
      this.error.value = null;
    });
  }
}

export const featureStore = new FeatureStore();
```

### 3. Update Hook/Component

```typescript
// Before
export function useFeature() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  useEffect(() => {
    setLoading(true);
    fetchData().then(d => {
      setData(d);
      setLoading(false);
    });
  }, []);

  return { data, loading, error };
}

// After
import { useMemo } from 'preact/hooks';
import { FeatureStore } from '@/lib/feature/FeatureStore';

export function useFeature() {
  const store = useMemo(() => new FeatureStore(), []);

  useEffect(() => {
    store.loading.value = true;
    fetchData().then(d => store.setData(d));
  }, [store]);

  return {
    data: store.data.value,
    loading: store.loading.value,
    error: store.error.value,
    isReady: store.isReady.value, // computed!
  };
}
```

### 4. Use effect() for Side Effects

```typescript
import { effect } from '@preact/signals';

// Auto-run when signals change
effect(() => {
  if (quoteStore.quote.value) {
    // Check allowance when quote updates
    checkAllowance(quoteStore.quote.value);
  }
});
```

---

## Migration Status

### ✅ Completed Migrations

| File | Before | After | Impact |
|------|--------|-------|--------|
| `useSwap.ts` | 7 useState | QuoteStore | 4 renders → 1 render |
| `LiquidityStore.ts` | Method filtering | computed() + method | Reactive filtering |
| `SwapStore.ts` | ✅ Already using signals | - | Reference implementation |

### 🔄 In Progress

| File | States | Priority | Effort |
|------|--------|----------|--------|
| `usePriceChartEngine.ts` | 5 states | HIGH | HIGH |
| `useWalletConnection.ts` | 8 states | MEDIUM | MEDIUM |
| `usePriceFeed.ts` | 3 per hook | HIGH | HIGH |

### 📋 Planned

| File | States | Priority | Effort |
|------|--------|----------|--------|
| `usePoolsAPI.ts` | 3 states | MEDIUM | LOW |
| `useHealthMonitor.ts` | Complex object | MEDIUM | MEDIUM |
| `ChartPage.tsx` | 5 URL states | LOW | LOW |
| `SwapForm.tsx` | 3 modal states | LOW | LOW |

---

## Best Practices

### ✅ Do

1. **Use `batch()` for multiple updates**
   ```typescript
   batch(() => {
     signal1.value = a;
     signal2.value = b;
     signal3.value = c;
   });
   ```

2. **Create stores for related state**
   ```typescript
   class UserStore {
     public profile = signal(null);
     public settings = signal({});
     public preferences = signal({});
   }
   ```

3. **Use `computed()` for derived values**
   ```typescript
   const fullName = computed(() =>
     `${firstName.value} ${lastName.value}`
   );
   ```

4. **Bind signals directly in JSX for performance**
   ```typescript
   <span>{priceSignal}</span> // Not priceSignal.value
   ```

5. **Use `effect()` for side effects**
   ```typescript
   effect(() => {
     console.log('Price changed:', price.value);
   });
   ```

### ❌ Don't

1. **Don't use signals for low-frequency UI state**
   ```typescript
   // ❌ Overkill for modal state
   const isOpen = signal(false);

   // ✅ useState is fine here
   const [isOpen, setIsOpen] = useState(false);
   ```

2. **Don't forget to use `.value`**
   ```typescript
   // ❌ Wrong
   if (loading) { ... }

   // ✅ Correct
   if (loading.value) { ... }
   ```

3. **Don't create signals in render**
   ```typescript
   // ❌ Creates new signal every render
   function Component() {
     const count = signal(0);
   }

   // ✅ Use useMemo or module-level
   const count = signal(0);
   function Component() { ... }
   ```

4. **Don't mix useState and signals for same concern**
   ```typescript
   // ❌ Inconsistent
   const [quote, setQuote] = useState(null);
   const loading = signal(false);

   // ✅ All signals or all useState
   class QuoteStore {
     quote = signal(null);
     loading = signal(false);
   }
   ```

---

## Performance Metrics

### Before Signals (useSwap)
- **State calls:** 7 useState
- **Re-renders per quote:** 4 (loading, error, quote, loading)
- **Allowance check:** Separate useEffect → 2 more renders
- **Total renders:** 6+ per quote cycle

### After Signals (QuoteStore)
- **State calls:** 1 store instance
- **Re-renders per quote:** 1 (batched update)
- **Allowance check:** Automatic via store method
- **Total renders:** 1 per quote cycle

**Improvement:** 6x reduction in render cycles

---

## Common Pitfalls & Solutions

### Pitfall 1: Signal not updating component

**Problem:**
```typescript
const count = signal(0);
count.value++; // Component doesn't re-render
```

**Solution:** Reassign, don't mutate
```typescript
count.value = count.value + 1; // ✅ Triggers update
```

### Pitfall 2: Accessing .value outside effect

**Problem:**
```typescript
effect(() => {
  const val = count.value; // ✅ Tracked
});
const val = count.value; // ❌ Not tracked
```

**Solution:** Always access .value inside effect/computed/component

### Pitfall 3: Stale closure in effect

**Problem:**
```typescript
const store = new Store();
effect(() => {
  // Uses stale store reference
  console.log(store.data.value);
});
```

**Solution:** Use effect dependencies carefully, or access signals directly

---

## Next Steps

1. ✅ Complete QuoteStore migration (useSwap.ts)
2. ✅ Add computed() to LiquidityStore
3. ⏳ Create ChartDataStore for chart engine
4. ⏳ Create WalletStore for wallet connection
5. ⏳ Optimize usePriceFeed with batching
6. ⏳ Audit remaining high-frequency useState
7. ⏳ Performance benchmarking (before/after)

---

## References

- [Preact Signals Guide](https://preactjs.com/guide/v10/signals/)
- [Why no memo in core?](https://github.com/preactjs/preact/discussions/4116)
- [Signals vs useState](https://github.com/preactjs/preact/discussions/3765)
- Internal: `src/lib/swap/QuoteStore.ts` (reference implementation)
- Internal: `src/lib/swap/SwapStore.ts` (existing pattern)
