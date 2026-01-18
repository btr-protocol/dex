# AIMM DEX Frontend

Lightweight frontend for the Balanced Automated Market Maker (AIMM) DEX built with Preact + Tailwind.

## Stack

- **Framework**: Preact (light alternative to React)
- **UI**: Tailwind with custom BTR theme and components
- **Web3**: Custom lightweight RPC client, multicall etc
- **Charts**: Chartist.js + TradingView Lightweight Charts for time series
- **Router**: Homemade virtual router (no dependencies)
- **Build**: Vite + TypeScript

## Quick Start

```bash
# Install dependencies
bun install

# Start dev server (connects to Anvil by default)
bun run dev

# Build for production
bun run build

# Type check
bun run typecheck
```

## Development

The frontend is configured to connect to local Anvil (localhost:8545) by default. Make sure you have Anvil running:

```bash
# From ../contracts directory
cd ../contracts
anvil --fork-url <RPC_URL> --port 8545
```

## Features

- **Dashboard**: Real-time pool metrics, TVL, volume, coverage ratios
- **Swap**: Token swapping interface with price impact display
- **Liquidity**: Deposit/withdraw liquidity with fee breakdown
- **Web3 Modal**: Lightweight wallet connection (Injected, WalletConnect)
- **Anvil Test Accounts**: Quick dev account switching (dev mode only)

## Configuration

### RPC Endpoints

Multi-chain RPC endpoints with automatic fallbacks are configured in `src/lib/rpcs.ts`:

- Ethereum Mainnet (15+ fallbacks)
- Optimism, Base, Arbitrum
- Polygon, Avalanche
- And 10+ more chains

### Theme

BTR-inspired dark theme in `src/styles/theme.ts`:

- Primary: Blue (#3d7eff)
- Secondary: Orange (#E99339)
- Background: Near-black (#0c0c0c)
- Fonts: Inter (UI), JetBrains Mono (code)

## Bundle Size

- **Production build**: ~472 KB (153 KB gzipped)
- **Preact compat**: Seamless React library support at 1/10th the size

## Project Structure

```
front/
├── src/
│   ├── components/     # Reusable UI components
│   │   └── Web3Modal.tsx
│   ├── lib/            # Core utilities
│   │   ├── rpcs.ts     # RPC endpoint config
│   │   ├── router.tsx  # Virtual router
│   │   └── web3.ts     # Wagmi config
│   ├── pages/          # Page components
│   │   ├── Dashboard.tsx
│   │   ├── Swap.tsx
│   │   └── Liquidity.tsx
│   ├── styles/         # Theme config
│   │   └── theme.ts
│   ├── App.tsx         # Root component
│   └── main.tsx        # Entry point
├── public/
│   └── icon.svg        # Favicon
├── index.html
└── vite.config.ts
```

## Next Steps

- [ ] Add contract ABIs
- [ ] Create `usePool` hook for reading pool state
- [ ] Integrate TradingView charts
- [ ] Add transaction confirmation modals
- [ ] Implement slippage protection
- [ ] Add event log streaming
