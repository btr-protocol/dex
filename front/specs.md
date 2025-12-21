# BTR DEX Frontend Specifications

**Version**: 0.1.0
**Date**: 2025-01-11
**Status**: Specification Draft

---

## Table of Contents

1. [Overview](#overview)
2. [Tech Stack](#tech-stack)
3. [Architecture](#architecture)
4. [Core Views](#core-views)
5. [Data Flow & State Management](#data-flow--state-management)
6. [UI Components](#ui-components)
7. [Pool & Chain Selection](#pool--chain-selection)
8. [Swap View](#swap-view)
9. [Liquidity View](#liquidity-view)
10. [Asset Management (Admin)](#asset-management-admin)
11. [Metrics View](#metrics-view)
12. [Wallet Integration](#wallet-integration)
13. [Design System](#design-system)
14. [Error Handling](#error-handling)

---

## Overview

BTR (btr.markets) is an Adaptive Inventory Market Maker (AIMM) DEX with sophisticated liquidity management. The frontend enables:

- **Swaps**: Token exchange with real-time pricing, slippage tracking, and spread visualization
- **Liquidity Provision**: Deposit/withdraw liquidity with per-asset LP tokens and real-time coverage ratio monitoring
- **Asset Management**: Pool owners can add assets with oracle config, risk parameters, fee bounds, and liquidity profiles
- **Metrics**: Pool health, volume, fees, and staking data (placeholder for future expansion)

**Key Design Principle**: Uniswap V2-like simplicity with Curve/Aave sophistication for pool owners.

---

## Tech Stack

**Stack (mandatory, no deviations)**:
- **UI Framework**: Preact + Preact Compact (production)
- **Bundler**: Vite
- **Package Manager**: Bun (exclusively)
- **Routing**: Minimal homemade router (`lib/router.tsx`)
- **Styling**: Tailwind CSS + Radix UI components
- **Charts**: Chart.js for spline visualization
- **Blockchain**: Viem (no wagmi) with native Viem connectors
- **State**: Viem context + local hooks (no Redux/Zustand)

**Production build target**: < 500KB (gzipped)

---

## Architecture

### Directory Structure

```
front/
├── specs.md                    # This file
├── src/
│   ├── main.tsx               # App entry
│   ├── App.tsx                # Root component
│   ├── index.css              # Global styles
│   ├── lib/
│   │   ├── router.tsx         # Router implementation
│   │   ├── wallet.tsx         # Viem setup + hooks
│   │   ├── hooks.ts           # Reusable React hooks
│   │   ├── constants.ts       # ABI, addresses, chains
│   │   └── utils.ts           # Helpers (formatting, math, etc.)
│   ├── components/
│   │   ├── layout/
│   │   │   ├── Header.tsx     # Nav + wallet button + chain/pool selector
│   │   │   └── Footer.tsx     # Links, docs, social
│   │   ├── ui/                # Radix + Tailwind components
│   │   │   ├── Button.tsx
│   │   │   ├── Dialog.tsx
│   │   │   ├── Input.tsx
│   │   │   ├── Select.tsx
│   │   │   ├── Slider.tsx
│   │   │   └── ... (core Radix primitives)
│   │   ├── wallet/
│   │   │   ├── WalletModal.tsx   # Wallet connection (viem connectors)
│   │   │   └── WalletButton.tsx
│   │   ├── ChainPoolSelector.tsx  # Combined chain+pool dropdown
│   │   ├── SwapForm.tsx           # Swap input/output + slippage
│   │   ├── LiquidityTable.tsx     # Asset list + deposit/withdraw
│   │   ├── AssetAddModal.tsx      # Admin: add asset form
│   │   ├── LiquidityShaper.tsx    # Admin: spline editor for liquidity profile
│   │   ├── OracleConfig.tsx       # Admin: oracle selection (internal/external)
│   │   └── ... (other domain components)
│   └── pages/
│       ├── SwapPage.tsx       # Route: /swap
│       ├── LiquidityPage.tsx  # Route: /liquidity
│       ├── AddAssetPage.tsx   # Route: /admin/add-asset (only owner)
│       ├── MetricsPage.tsx    # Route: /metrics
│       └── NotFound.tsx       # 404
├── public/
│   ├── token-icons/           # ERC20 token SVGs
│   ├── chain-logos/           # Network chain logos
│   ├── wallet-icons/          # Wallet connector icons
│   └── docs/                  # Markdown docs (served, searchable)
├── tailwind.config.js         # Tailwind + Radix plugin
├── vite.config.ts             # Vite config
└── package.json
```

### Component Hierarchy

```
App
├── Header
│   ├── ChainPoolSelector (modal)
│   ├── WalletButton
│   │   └── WalletModal (modal)
│   └── Nav (Swap | Liquidity | Metrics)
├── Routes
│   ├── SwapPage
│   │   └── SwapForm (center, stateful)
│   ├── LiquidityPage
│   │   ├── LiquidityTable
│   │   └── (Optional) WithdrawModal
│   ├── AddAssetPage (admin only)
│   │   ├── AssetAddForm
│   │   ├── OracleConfigPanel
│   │   ├── RiskConfigPanel
│   │   ├── FeeBoundsPanel
│   │   ├── LiquidityShaper
│   │   ├── GammaShaper
│   │   ├── VegaShaper
│   │   └── LambdaShaper
│   ├── MetricsPage (placeholder)
│   └── NotFound
└── Footer
```

---

## Data Flow & State Management

**Principle**: Minimal state, maximum clarity. No Redux/Zustand.

### Context & Hooks

```typescript
// lib/wallet.tsx
export const useAccount() // Returns connected account + chain
export const usePool(chain, poolAddress) // Returns IPoolV1 data
export const useAsset(poolAddress, tokenAddress) // Returns Asset struct
export const useQuote(tokenIn, tokenOut, amountIn) // Returns SwapQuote
export const useWrite(functionName, args) // Returns { write(), isPending, isSuccess, error }
```

### State Flow for Swap

1. User selects chain + pool (stored in URL params + localStorage)
2. User enters `amountIn` → triggers `useQuote()`
3. Quote updates → show `amountOut`, spread, fees, slippage
4. User clicks "Swap" → `useWrite('swap', [tokenIn, tokenOut, amountIn, minAmountOut, recipient])`
5. Transaction pending → show spinner
6. Success → show confirmation toast + update balances

### State Flow for Liquidity Deposit

1. User selects asset from table → opens modal
2. User enters amount → triggers `useWrite('deposit', [token, amount])`
3. Pending state → show spinner
4. Success → update LP balance in table

---

## Core Views

### View 1: Swap Page (`/swap`)

**Layout**: Center-aligned swap form on clean background

**Components**:
- `SwapForm`: Two-token input (in/out), slippage tolerance slider, swap button
- Real-time quote (fetch on input change, debounced 300ms)
- Display: Amount out, spread (bps), fees (proto + LP), estimated impact

**Key Features**:
- Token selection via modal (search by name/symbol)
- Native token (WETH) auto-wrapping
- Min output calculation based on slippage tolerance (default 0.5%)
- Swap button disabled during pending or if quote is stale (>30s)

**UX Details**:
- Input box with "Max" button
- Token icon + symbol display
- Real-time balance display below input
- "Swap" button primary color, full width
- Show fees breakdown: "X proto + Y LP"
- Slippage tolerance is a modal (not always on)

---

### View 2: Liquidity Page (`/liquidity`)

**Layout**: Two-column or responsive table + deposit/withdraw modals

**Components**:
- `LiquidityTable`: One row per asset in pool
  - Columns: Token icon, Name, Reserves, Liabilities, Coverage Ratio, Your LP, Deposit/Withdraw actions
  - Coverage ratio as colored pill (green >80%, yellow 50-80%, red <50%)
  - Each row is clickable → opens deposit/withdraw modal

**Key Features**:
- Display all assets in the selected pool
- Show LP token balance per asset (user's liquidity)
- Show pool reserves + liabilities (on-chain state)
- Calculate and display coverage ratio per asset: `reserves / (reserves + liabilities)`
- Deposit modal: Input amount → shows LP tokens received + coverage impact
- Withdraw modal: Input LP amount → shows expected asset output + haircut (if coverage < threshold)

**Admin Features** (if `msg.sender == pool.owner()`):
- "Add Asset" button above table (opens `/admin/add-asset`)
- This navigates to asset management page

**UX Details**:
- Deposit/withdraw buttons per row
- Green/red indicators for coverage health
- Loading state while fetching on-chain data

---

### View 3: Metrics Page (`/metrics`)

**Current Status**: Placeholder

**Placeholder Content**:
- Section headers: "Volume", "Fees", "Coverage", "Staking" (all disabled/grayed)
- Message: "Metrics coming soon"

**Future Expansion** (post-v1):
- 24h volume, fees collected (proto + LP)
- Average spread, slippage distribution
- Coverage ratio evolution chart
- Staking APY, total staked BTR
- Governance dashboard

---

## Pool & Chain Selection

### Combined Chain/Pool Selector

**Design**: Single dropdown in header, expandable by chain

**Behavior**:
- Default display: "Chain Name → Pool Name" (e.g., "Ethereum → Genesis")
- Click to expand → tree view:
  ```
  ▼ Ethereum
    ◎ Genesis (Genesis Pool)  [primary, always first]
    ○ Custom Pool A
    ○ Custom Pool B
  ▼ Arbitrum
    ◎ Genesis
    ○ Custom Pool C
  ▼ Optimism
    ...
  ```
- Search box at top (filters by chain or pool name)
- Selected pool highlighted
- Click to select → closes dropdown + updates URL params + localStorage

**Storage**:
- URL params: `?chain=ethereum&pool=0x...`
- localStorage: `{ lastChain: 'ethereum', lastPool: '0x...' }` for persistence
- On app load, restore from localStorage or use Genesis on Ethereum as default

**Implementation**:
- Component: `ChainPoolSelector.tsx`
- Fetches deployed pools per chain from `public/deployments.json`
- Each pool has: name, address, baseToken, deployedAt
- Chain list hardcoded or from `lib/constants.ts`

---

## Swap View Details

### SwapForm Component

**Structure**:
```
┌─────────────────────────────────┐
│  Swap                       ⚙️   │
├─────────────────────────────────┤
│ From:                           │
│ [Token Selector] ___________    │
│                       [Max]     │
│ Balance: X.XX ETH               │
│                                 │
│           ⇅ (flip button)        │
│                                 │
│ To:                             │
│ [Token Selector] ___________    │
│ Estimated: Y.YY ETH             │
│                                 │
│ Slippage Tolerance: 0.5% [set]  │
│ Price Impact: +0.2%             │
│ Liquidity Spread: 12 bps        │
│                                 │
│ [Swap Button]                   │
│ Proto Fee: 0.03 ETH             │
│ LP Fee: 0.07 ETH                │
│                                 │
└─────────────────────────────────┘
```

**Token Selector Modal**:
- Search box (by symbol, name, address)
- Popular tokens at top
- Scrollable list with balance display
- Click to select

**Quote Calculation**:
- Call `getSwapQuote(tokenIn, tokenOut, amountIn)` on input change
- Debounce 300ms to avoid too many RPC calls
- Display results: `amountOut`, `spreadBps`, `protoFee`, `lpFee`, `priceImpact`
- Calculate: min = A_out × (1 - s / 10000)
  where: A_out = expected output amount, s = slippage tolerance (basis points)

**Validation**:
- Disable swap if: no account, amountIn = 0, quote is stale (>30s), insufficient balance
- Show error message for invalid pairs

---

## Liquidity View Details

### LiquidityTable Component

**Columns**:
1. Token (icon + symbol)
2. Reserves (formatted with decimals)
3. Liabilities (formatted with decimals)
4. Coverage Ratio (% with color)
5. Your LP Balance (formatted)
6. Actions (Deposit/Withdraw buttons)

**Display Logic**:
- Fetch `getAsset(token)` for each token in pool
- Coverage = (R / (R + L)) × 100%
  where: R = reserves, L = liabilities
- Color coding:
  - Green: >80%
  - Yellow: 50-80%
  - Red: <50%
  - Gray: 0% (no liabilities)

**Deposit Flow**:
1. Click "Deposit" → `DepositModal` opens
2. Input amount → call `getAsset(token)` to show min liquidity requirement
3. Submit → `useWrite('deposit', [token, amount])`
4. Show confirmation → close modal + refresh table

**Withdraw Flow**:
1. Click "Withdraw" → `WithdrawModal` opens
2. Input LP amount → fetch `getAsset()` to calculate haircut if coverage < threshold
3. Show: "LP Amount: X → Expected Output: Y" (with haircut notation if applies)
4. Submit → `useWrite('withdraw', [token, lpAmount, minAmountOut])`
5. Show confirmation → close modal + refresh table

**Refresh Strategy**:
- Fetch on mount
- Refetch every 10s (or on user action)
- Show "Loading..." while fetching

---

## Asset Management (Admin)

**Access Control**: Show "Add Asset" button only if `msg.sender == pool.owner()`

### Asset Adding Flow (`/admin/add-asset`)

**Page Layout** (multi-panel or scrollable):
1. **Asset Selection Panel**
   - ERC20 address input (with validation)
   - Button to validate token (fetch decimals, symbol)
   - Show selected token info

2. **Oracle Config Panel**
   - Radio: "Internal (Curve-style)" vs "External Oracle"
   - If Internal:
     - Dropdown to select anchor token (only assets already in pool)
     - Note: First asset = no anchor (numeraire)
     - Second asset anchors to first
     - Subsequent: can anchor to any existing asset
   - If External:
     - Oracle address input
     - Feed ID input
     - Button to verify: call `oracle.getFeed(feedId)` and `oracle.isFeedFresh()` (multicall)
     - Show verification status (✓ or ✗)

3. **Risk Config Panel**
   - `decayStartRatioBps`: threshold (default 980000 = 98%)
   - `coverageFloor`: critical floor (default 500000 = 50%)
   - `decaySlope`: decay rate (WAD units per second)
   - `depthAmplifier`: depth curve amplifier (basis 10000)
   - Show tooltips explaining each parameter
   - Validation: ensure values are reasonable (0-100% for ratios)

4. **Fee Bounds Panel**
   - `minFeeBps`: minimum fee (basis points)
   - `maxFeeBps`: maximum fee (basis points)
   - Slider or input boxes for both
   - Show fee range as bps

5. **Liquidity Profile Panel** (most complex)
   - **Spline Editor** (visual + table)
     - Canvas chart showing liquidity profile (horizontal axis: -100 to +100, vertical: weight)
     - 0 = mid price (TWAP), ±100 = extreme prices
     - Click on chart to create knot at price level
     - Drag knots to adjust
     - Double-click to delete knot
     - **Table below chart**:
       - Columns: Price Offset (%), Weight (%), Actions (delete)
       - Rows are knots, sorted by price
       - Knots highlight when chart knot is selected
       - Manual edit: click cell to edit value, press Enter to confirm
       - Newly created knots auto-insert in correct sorted position
     - **Validation**:
       - Weights must be 0-255 (uint8)
       - First zero weight marks end of profile
       - Max 16 knots
     - **Chart.js** visualization with interactivity

6. **Gamma, Vega, Lambda Panels** (visual parameter shapers)
   - For each parameter, show:
     - Formula explanation (tooltip)
     - Slider (0-100 basis points for sensitivity)
     - Chart showing impact (e.g., how gamma affects price offset at different inventory levels)
     - Chart axes: inventory deviation (x), price impact (y)
   - **Gamma Chart**: Shows price offset curve across inventory skew (-1 to +1)
   - **Vega Chart**: Shows dispersion (spread) change across volatility levels
   - **Lambda Chart**: Shows fee surcharge across deviation levels
   - Interaction: drag on chart to adjust value, or use slider

7. **Initial State Panel**
   - `initialPrice`: B64-encoded spot price (can use current TWAP)
   - `initialFastVolEMA`: fast volatility estimate
   - `initialSlowVolEMA`: slow volatility estimate
   - Buttons: "Use Current" (fetch from oracle) or manual input

**Submit Button**:
- Call `requestAddAsset(token, oracleCfg, riskCfg, profile, minFeeBps, decimals, initialPrice, fastVol, slowVol)`
- Timelock delay: transaction queued, not immediate
- Show "Pending approval" state
- Link to execute after timelock period (probably on admin page)

---

## Liquidity Shaper Component

**Purpose**: Visual editor for spline-based liquidity profiles

**Key Requirements**:
- **Chart Display**:
  - Chart.js line chart
  - X-axis: price offset from mid-price (-100 to +100, representing range around TWAP)
  - Y-axis: weight (0-255)
  - Smooth interpolation between knots (spline)
  - Grid for reference

- **Interactivity**:
  - Click on chart → create knot (or select existing)
  - Drag knot → move left/right + up/down (adjust price + weight)
  - Double-click knot → delete (confirm)
  - Selected knot → highlighted in chart + table

- **Knot Table**:
  - Columns: Price Offset (%), Weight (0-255), Delete
  - Rows sorted by price offset
  - Click to edit inline (cell becomes input field)
  - Escape to cancel, Enter to confirm
  - New knots auto-inserted in sorted order

- **Validation**:
  - Weights must be 0-255 (uint8)
  - First zero marks end
  - Max 16 weights
  - Show validation errors in red

- **Implementation**:
  ```typescript
  interface SplineKnot {
    priceOffset: number;  // -100 to +100
    weight: number;       // 0 to 255
  }

  export function LiquidityShaper({
    initialKnots: SplineKnot[],
    onKnotsChange: (knots: SplineKnot[]) => void,
  }) {
    // Chart rendering
    // Drag handlers
    // Table rendering + edit handlers
  }
  ```

---

## UI Components

### Existing Radix Components (use these)

From `package.json`:
- `@radix-ui/react-checkbox`
- `@radix-ui/react-dialog`
- `@radix-ui/react-dropdown-menu`
- `@radix-ui/react-label`
- `@radix-ui/react-select`
- `@radix-ui/react-slot`

**Implementation approach**:
- Wrap Radix primitives with Tailwind styling in `components/ui/`
- Reuse across all views
- Example: `components/ui/Select.tsx` wraps `@radix-ui/react-select`

### Recommended New Components

```
components/ui/
├── Button.tsx          (Radix + Tailwind)
├── Input.tsx           (native + Tailwind)
├── Dialog.tsx          (Radix + Tailwind)
├── Select.tsx          (Radix + Tailwind)
├── Checkbox.tsx        (Radix + Tailwind)
├── Slider.tsx          (custom or Radix + Tailwind)
├── Tooltip.tsx         (Radix + Tailwind)
├── Toast.tsx           (custom or Headless UI)
├── Badge.tsx           (Tailwind only)
├── Spinner.tsx         (SVG or Tailwind animate)
├── Modal.tsx           (wrapper around Dialog)
├── Tab.tsx             (Radix or custom)
└── ... (other primitives as needed)
```

### Domain Components

```
components/
├── SwapForm.tsx
├── LiquidityTable.tsx
├── TokenSelector.tsx       (modal for token selection)
├── ChainPoolSelector.tsx   (dropdown tree)
├── AssetAddModal.tsx       (multi-step form or modal container)
├── LiquidityShaper.tsx     (spline editor)
├── OracleConfig.tsx        (internal/external radio + inputs)
├── RiskConfig.tsx          (parameter inputs)
├── FeeBoundsPanel.tsx      (min/max fee sliders)
├── GammaShaper.tsx         (parameter shaper with chart)
├── VegaShaper.tsx          (parameter shaper with chart)
├── LambdaShaper.tsx        (parameter shaper with chart)
└── ... (other reusable components)
```

---

## Wallet Integration

### Viem Setup (`lib/wallet.tsx`)

**Configuration**:
- Use Viem's `createConfig()` with public + wallet clients
- Support connectors: MetaMask, WalletConnect, Coinbase, Safe, Frame
- Chain list: Ethereum, Arbitrum, Optimism, Base, etc.

**Key Hooks**:
```typescript
export const useAccount() // { address, chain, isConnecting, isConnected }
export const usePublicClient() // Viem PublicClient
export const useWalletClient() // Viem WalletClient
export const useBalance(address, token?) // { formatted, decimals }
export const useWrite(contract, functionName, args) // { write(), isPending, isSuccess, error }
export const useRead(contract, functionName, args) // { data, isLoading, error }
```

**Wallet Modal** (`components/wallet/WalletModal.tsx`):
- Show available connectors with icons (from `public/wallet-icons/`)
- Connect button per connector
- Show connected account + chain in header
- Disconnect button

**Reference**: Consider reusing 1edge-v1's wallet connection code (it's well-built)

---

## Design System

### Color Palette

**Semantic Colors**:
- **Primary**: #0070f3 (blue, CTAs)
- **Success**: #10b981 (green, coverage >80%, success states)
- **Warning**: #f59e0b (amber, coverage 50-80%, cautions)
- **Danger**: #ef4444 (red, coverage <50%, errors)
- **Surface**: #f9fafb (light gray, cards/panels)
- **Text**: #111827 (dark gray/black, main text)
- **Muted**: #6b7280 (medium gray, secondary text)

**Tailwind Config**:
- Extend defaults with semantic colors
- Use `text-xs`, `text-sm`, `text-base` for hierarchy
- Use `gap-4`, `p-4`, `rounded-lg` as defaults

### Typography

- **Font**: Inter Variable (already in `package.json`)
- **Headings**: Prefers semibold (`font-semibold`)
- **Body**: Regular weight (`font-normal`)
- **Code**: Monospace (inline `<code>` tags, pre blocks)

### Spacing

- Base unit: 4px (Tailwind default)
- Common: `p-4`, `gap-4`, `mb-4`, `mt-2`
- Modals: `p-6` padding
- Cards: `p-4` padding

### Shadows & Borders

- Cards: `shadow-sm` (light)
- Modals: `shadow-lg`
- Borders: `border border-gray-200`
- Rounded corners: `rounded-lg` (default)

---

## Error Handling

### User-Facing Errors

**Toast Notifications** (top-right, auto-dismiss):
- Success: "Swap executed", green background
- Error: "Insufficient balance", red background, no auto-dismiss
- Pending: "Confirming transaction...", blue background

**Form Validation**:
- Show inline error messages below inputs
- Red text, red border on input
- Example: "Invalid token address" or "Slippage must be 0-100%"

**Transaction Errors**:
- Catch revert reasons from smart contract
- Display human-readable message
- Link to block explorer if hash is available
- Retry button

### Developer Errors

**Console Logging**:
- Log RPC calls (in dev mode)
- Log state changes (router, account, etc.)
- Use `console.warn()` for recoverable errors
- Use `console.error()` for critical issues

---

## Implementation Priorities

### Phase 1 (MVP)

- [x] Router setup
- [x] Header + wallet connection
- [x] Chain/pool selector
- [ ] Swap form (quote calculation, transaction)
- [ ] Liquidity table (deposit/withdraw)
- [ ] Metrics placeholder

### Phase 2 (Admin Features)

- [ ] Asset adding form
- [ ] Oracle config (internal/external)
- [ ] Liquidity shaper (spline editor)
- [ ] Risk config panel
- [ ] Fee bounds panel

### Phase 3 (Polish & Optimization)

- [ ] Parameter shapers (gamma, vega, lambda charts)
- [ ] Transaction history
- [ ] Mobile responsiveness
- [ ] Offline state handling
- [ ] Dark mode (optional)

---

## API Integration

### Contracts to Interface

**Primary**: `IPoolV1` (PoolProxyV1)

**Key Functions**:
- `getSwapQuote(tokenIn, tokenOut, amountIn)` → SwapQuote
- `swap(tokenIn, tokenOut, amountIn, minAmountOut, recipient)` → amountOut
- `getAsset(token)` → Asset
- `deposit(token, amount)` → DepositResult
- `withdraw(token, lpAmount, minAmountOut)` → WithdrawResult
- `requestAddAsset(...)` → timelock
- `getFeedConfig(token)` → OracleConfig
- `getRiskConfig(token)` → RiskConfig
- `getLiquidityProfile(token)` → LiquidityProfile
- `getCoverageRatio(token)` → uint256

### Multicall

- Use Viem's `multicall()` for batch reads
- Example: fetch all assets + coverage ratios in one call

---

## Testing & QA

### Unit Tests (optional for v1)

- `LiquidityShaper`: knot creation, deletion, sorting
- `SwapForm`: slippage calculation, validation
- `ChainPoolSelector`: tree rendering, filtering

### Manual Testing Checklist

- [ ] Swap with native token (WETH) wrapping
- [ ] Deposit/withdraw at different coverage levels (verify haircut)
- [ ] Asset adding with internal oracle + anchor validation
- [ ] Liquidity profile editing (create, drag, delete knots)
- [ ] Responsive UI on mobile + desktop
- [ ] Wallet disconnection + reconnection
- [ ] Multiple chains + pools (ensure selector works)

---

## Performance Notes

### Bundle Size Target

- **Goal**: <500KB gzipped
- **Preact Compact**: ~3KB (vs React 42KB)
- **Tailwind + Radix**: ~150KB combined
- **Viem**: ~50KB
- **Chart.js**: ~30KB
- **Remaining**: 267KB for app code + icons

### Optimization Techniques

1. **Code Splitting**:
   - Lazy load admin pages (`/admin/add-asset`)
   - Use Vite's dynamic imports: `const AddAssetPage = lazy(() => import('./pages/AddAssetPage'))`

2. **Image Optimization**:
   - Token icons: SVG (vector, small)
   - Chain logos: SVG or WebP
   - Compress with `ImageOptim` or Squoosh

3. **API Calls**:
   - Debounce quote requests (300ms)
   - Cache on-chain data for 10s
   - Use Viem's native caching where available

4. **CSS**:
   - Tailwind PurgeCSS removes unused classes
   - No unused dependencies (check `package.json`)

---

## Accessibility

### WCAG 2.1 AA Compliance

- [ ] Semantic HTML (`<button>`, `<label>`, `<dialog>`)
- [ ] ARIA labels on interactive elements
- [ ] Color contrast >4.5:1 for text
- [ ] Keyboard navigation (Tab, Enter, Escape)
- [ ] Focus indicators visible
- [ ] Error messages linked to inputs

### Keyboard Navigation

- Tab through form inputs
- Enter to submit
- Escape to close modals
- Arrow keys in dropdowns

---

## Deployment

### Build Process

```bash
bun install
bun run build
# Output: dist/
```

### Hosting Options

- Vercel (recommended, auto-deploys from git)
- Cloudflare Pages (fast, good caching)
- IPFS + Pinata (decentralized)

### Environment Variables

```
VITE_RPC_URL_ETHEREUM=
VITE_RPC_URL_ARBITRUM=
VITE_POOL_ADDRESS_GENESIS=
VITE_BRIDGE_ADDRESS=
```

---

## Future Enhancements

### v2 Features

- **Multi-hop routing**: Via LCA algorithm (anchor tree)
- **Liability swaps**: Swap LP tokens across assets
- **Flash loans**: UI for flash borrow + repay
- **Staking**: sLP + BTR staking dashboard
- **Governance**: Vote on parameter updates
- **Advanced charts**: Price history, volume, fees (TradingView Lightweight Charts)
- **Slippage estimator**: Historical impact analysis
- **Pool creation**: Factory UI for custom pool instantiation

### Optimizations

- Worker threads for price calculations
- GraphQL subgraph for faster queries
- Real-time WebSocket updates for quotes
- Dark mode toggle
- Mobile app (React Native)

---

## Glossary

| Term | Definition |
|------|-----------|
| **AIMM** | Adaptive Inventory Market Maker |
| **Coverage Ratio** | Reserves / (Reserves + Liabilities), measures pool health |
| **Haircut** | Withdrawal penalty when coverage is low (< threshold) |
| **Liquidity Profile** | Spline of weights across price offsets, determines LP concentration |
| **Spread** | Bid-ask spread in bps, set by gamma/vega/lambda |
| **B64** | Base64 encoding for fixed-point prices |
| **TWAP** | Time-Weighted Average Price (mid-price reference) |
| **Anchor** | Parent asset in pricing tree (for oracle routing) |
| **LP Token** | ERC20 representing liquidity share per asset |
| **Proto Fee** | Protocol treasury share of spread |
| **LP Fee** | Liquidity provider share of spread |

---

## References

**On-Chain**:
- `contracts/src/interfaces/IPoolV1.sol`
- `contracts/src/interfaces/modules/ICoreV1.sol`
- `contracts/src/interfaces/modules/IAdminV1.sol`
- `docs/` (architecture, parameters, etc.)

**External**:
- Uniswap V2 UI (UX reference)
- Curve.fi (liquidity profiles reference)
- Aave Protocol (admin panel reference)
- 1edge-v1 (wallet connection + panel resizing reference)

**Viem Docs**:
- https://viem.sh

---

**End of Specifications**

