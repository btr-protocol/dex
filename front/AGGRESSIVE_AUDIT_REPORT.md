# Aggressive Codebase Duplication Audit

## Summary
- **Components analyzed**: 40+
- **Potential redundancy found**: 500+ lines
- **Hook consolidation candidates**: 6 files
- **Component breakdown candidates**: 5 large components (300+ lines)

---

## 1. STATE MANAGEMENT PATTERNS (14 useState, 18 useCallback/useMemo)

### 1.1 WalletModal.tsx - 10 useState calls
```
Components with 6+ useState calls are candidates for custom hooks:
- agreedToTerms
- connectingWallet
- error
- searchQuery
- view (modal state)
- isLoadingWC
- qrCodeUrl
- wcUri
- copied
- [hidden state]
```
**Opportunity**: Extract wallet connection logic into `useWalletConnection` hook
**Savings**: ~80 lines

### 1.2 Other Multi-useState Components
- NotificationsModal.tsx: 3 useState
- SearchModal.tsx: 3 useState
- LiquidityShaper.tsx: 4 useState
- Header.tsx: 3 useState

**Opportunity**: Create custom hooks for common state patterns
**Potential savings**: ~100 lines

---

## 2. MODAL/DIALOG PATTERNS (15 modal files)

### Common Pattern Found:
All modals follow identical structure:
1. Open/close state boolean
2. BaseModal wrapper
3. Header with close button
4. Content section
5. Footer with buttons

**Files affected**:
- WalletModal.tsx (501 lines)
- SearchModal.tsx (324 lines)
- NotificationsModal.tsx (253 lines)
- SettingsModal.tsx (153 lines)
- DisclaimerPage.tsx (164 lines)
- ExternalLinkModal.tsx
- DownloadModal.tsx
- IndicatorParamsModal.tsx
- MultiSelectModal.tsx (232 lines)

**Opportunity**: Create ModalLayout component
```tsx
<ModalLayout
  isOpen={isOpen}
  onClose={onClose}
  title="Title"
  actions={<Button>Action</Button>}
>
  Content here
</ModalLayout>
```

**Savings**: ~150 lines across 9 modals

---

## 3. COMPONENT COMPOSITION PATTERNS

### 3.1 List + Item Pattern
**Locations**: SelectableList (used in ChartToolbar, SearchModal)
- Custom item rendering with consistent styling
- Selection state management
- Empty state handling

**Current**: Reinvented in each modal
**Opportunity**: Extract ListItem component with variants
**Savings**: ~40 lines

### 3.2 Icon + Text + Action Pattern
**Locations**: 16+ files
- Icon (MaskIcon or lucide)
- Text label
- Optional badge/count
- Optional action button

**Current**: Repeated 20+ times
**Opportunity**: `IconLabel` component already exists but underused
**Savings**: ~60 lines

### 3.3 Input with Icon Pattern
**Locations**: 7 files (SearchModal, TokenSelector, etc)
- Input field
- Icon on left side
- Placeholder text
- Optional validation

**Opportunity**: Create `IconInput` component
**Savings**: ~30 lines

---

## 4. BUTTON/ACTION PATTERNS

### 4.1 Toggle Button Pattern
```tsx
onClick={() => setOpen(!open)}  // 2 instances
onClick={() => setModal(!modal)} // common pattern
```
**Opportunity**: Create `useToggle` hook
**Savings**: ~10 lines

### 4.2 Close Button Pattern (103 instances)
```tsx
// Repeated in every modal/dialog
<button onClick={onClose} className="...">
  <X className="w-4 h-4" />
</button>
```
**Opportunity**: Create `CloseButton` component
**Savings**: ~40 lines

### 4.3 Button Groups (px-4 py-3, px-3 py-2 patterns)
- Most common: `px-3 py-2` (17 instances)
- Next: `px-4 py-3` (13 instances)

**Opportunity**: Create spacing constants
**Savings**: ~20 lines

---

## 5. WRAPPER/LAYOUT PATTERNS (73 border patterns)

### 5.1 Card Wrapper Pattern
```tsx
// Repeated 11+ times
<div className="bg-bg-1 border border-border rounded-lg p-3">
```
**Opportunity**: Create `Card` component (partially exists but underused)
**Savings**: ~30 lines

### 5.2 Scrollable Container Pattern (8 instances)
```tsx
<div className="overflow-y-auto max-h-[80vh]">
<div className="overflow-x-auto">
```
**Opportunity**: Create `ScrollContainer` component
**Savings**: ~15 lines

### 5.3 Divider Pattern (73 instances)
```tsx
// Various: border-t, border-b, border-l, border-r
<div className="border-t border-border" />
```
**Opportunity**: Create `Divider` component
**Savings**: ~25 lines

---

## 6. DATA FETCHING PATTERNS (6 custom hooks)

### Current State:
- `useContract` - Contract interactions
- `usePool` - Pool state
- `usePoolState` - Pool state (different?)
- `useTokenInfo` - Token data
- `usePriceFeed` - Price data (9442 lines!)
- `useHealthMonitor` - Health monitoring

### Issues:
- **Duplication**: `usePool` and `usePoolState` likely overlap
- **Monster hook**: `usePriceFeed.ts` is 9442 lines (should be split)
- **Inconsistent patterns**: Different error/loading handling

**Opportunity**:
1. Merge `usePool` and `usePoolState`
2. Split `usePriceFeed` into smaller hooks
3. Create base data-fetching hook pattern

**Savings**: ~200 lines

---

## 7. LOADING/ERROR/EMPTY STATE PATTERNS

### Current State:
- 15 instances of LoadingState/ErrorState
- 16 instances of empty state handling
- 24 instances of loading state patterns

### Current Pattern:
```tsx
if (isLoading) return <LoadingState />;
if (error) return <ErrorState />;
if (!data || data.length === 0) return <EmptyState />;
return <Content />;
```

**Opportunity**: Create `DataView` wrapper component
```tsx
<DataView
  isLoading={isLoading}
  error={error}
  isEmpty={!data?.length}
  emptyMessage="No data found"
>
  {data.map(...)}
</DataView>
```

**Savings**: ~80 lines

---

## 8. TRANSITION/ANIMATION PATTERNS (85 instances)

### Most Used:
- `transition-colors` (38 instances)
- `transition-opacity` (12 instances)
- `transition-all` (8 instances)

**Opportunity**: Create transition utility class presets
**Savings**: ~15 lines (className shorter)

---

## 9. HOOK-LEVEL DUPLICATION

### Pattern: fetch + useState + useEffect
All data hooks follow:
```tsx
const [data, setData] = useState(null);
useEffect(() => {
  fetchData().then(setData);
}, [dependencies]);
```

**Opportunity**: Create generic `useAsync` hook
```tsx
const { data, loading, error } = useAsync(fetchFunction, dependencies);
```
**Savings**: ~150 lines across all hooks

---

## HIGH-VALUE CONSOLIDATION TARGETS

### Priority 1 (500+ lines potential savings):
1. **Extract Modal Layout** - 9 modals using identical pattern
2. **useWalletConnection hook** - WalletModal has 10 useState calls
3. **Split usePriceFeed** - 9442 lines should be 3-4 smaller hooks
4. **Create useAsync** - Replace data fetch pattern in 6 hooks

### Priority 2 (200+ lines):
5. **Modal footer/actions** - Create ModalActions variant
6. **Merge usePool/usePoolState** - Overlapping logic
7. **Extract search input** - 7+ files have similar pattern
8. **Create CloseButton** - 103 close button instances

### Priority 3 (100+ lines):
9. **Create IconInput** - Input with icon pattern
10. **Create DataView wrapper** - Loading/error/empty states
11. **Create Divider component** - 73 instances
12. **Extract WalletListItem** - Wallet connection rows

---

## IMPLEMENTATION ROADMAP

### Phase 1: Foundation (400 lines saved)
- [ ] Create `useAsync` hook - replaces 6 data hooks
- [ ] Create `ModalLayout` component - consolidates 9 modals
- [ ] Extract `useWalletConnection` - simplifies WalletModal

### Phase 2: Components (200 lines saved)
- [ ] Create `CloseButton` component
- [ ] Create `IconInput` component
- [ ] Create `DataView` wrapper
- [ ] Create `Divider` component

### Phase 3: Utilities (100 lines saved)
- [ ] Create `useToggle` hook
- [ ] Merge `usePool`/`usePoolState`
- [ ] Split `usePriceFeed` into 3-4 hooks
- [ ] Create spacing/transition utility presets

---

## QUICK WINS (30-60 lines each)

1. **CloseButton component**: 103 instances → single component
2. **Card wrapper**: 11 instances → Card component
3. **Divider**: 73 instances → single component
4. **DataView**: 16 empty states → single component pattern
5. **useToggle**: 2+ toggle patterns → hook

---

## ESTIMATED TOTAL SAVINGS: 800-1000 lines

- Phase 1: 400 lines
- Phase 2: 200 lines
- Phase 3: 150 lines
- Quick wins: 150 lines
- **Total: 900 lines**

---

## METRICS

| Category | Count | Savings (lines) |
|----------|-------|-----------------|
| Modal files | 9 | 200 |
| useState patterns | 10+ | 150 |
| Data hooks | 6 | 200 |
| Close buttons | 103 | 50 |
| Empty states | 16 | 80 |
| Wrapper patterns | 44 | 80 |
| Dividers | 73 | 25 |
| Input patterns | 7 | 30 |
| **Total** | **~260** | **~815** |

---

## Files to Create/Refactor

### New Components:
- `ui/ModalLayout.tsx` (80 lines)
- `ui/CloseButton.tsx` (20 lines)
- `ui/IconInput.tsx` (40 lines)
- `ui/Divider.tsx` (15 lines)
- `ui/DataView.tsx` (60 lines)

### New Hooks:
- `hooks/useAsync.ts` (40 lines)
- `hooks/useToggle.ts` (10 lines)
- `hooks/useWalletConnection.ts` (80 lines)

### Refactor:
- `hooks/usePriceFeed.ts` → 3-4 smaller hooks
- `hooks/usePool.ts` + `usePoolState.ts` → merged
- All modals to use ModalLayout

---

## Next Steps

1. Start with `useAsync` hook - biggest ROI
2. Create `ModalLayout` - affects 9 files
3. Extract `useWalletConnection` - removes 10 useState calls
4. Roll out quickly with incremental PRs
