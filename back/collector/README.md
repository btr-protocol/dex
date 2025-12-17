# Market Data Collector

Lightweight market data collector with OHLC caching using bun + ccxt + SQLite.

Extracted from 1edge-v1 project.

## Features

- Real-time price aggregation from multiple exchanges (Binance, Bybit, OKX, Gate, etc.)
- Weighted average pricing based on exchange reliability
- OHLC candle generation and storage in SQLite
- Automatic historical data backfill from Binance
- Lightweight and fast with Bun runtime

## Installation

```bash
cd collector
bun install
```

## Usage

```bash
# Development mode with auto-reload
bun run dev

# Production mode
bun run start
```

## Configuration

Edit `src/config.ts` to:
- Add/remove trading pairs
- Adjust exchange weights
- Configure timeframes
- Set historical data requirements

### Token Wrapper Aliases

The collector automatically resolves wrapper token aliases to their underlying assets, making it transparent for frontend applications:

**Supported Aliases:**
- `WETH`, `UETH` → `ETH`
- `WBTC`, `CBBTC`, `TBTC`, `UBTC`, `BTCB` → `BTC`

**Examples:**
```bash
# Frontend requests WETHUSDC, backend returns ETHUSDT data
curl http://localhost:3000/api/candles?symbol=WETHUSDC&timeframe=60

# Frontend requests WBTCUSDT, backend returns BTCUSDT data
curl http://localhost:3000/api/candles?symbol=WBTCUSDT&timeframe=60
```

The response includes both the requested symbol and the resolved symbol:
```json
{
  "symbol": "WETHUSDC",
  "resolvedSymbol": "ETHUSDT",
  "candles": [...]
}
```

Test alias resolution:
```bash
bun run test:aliases
```

## Data Storage

OHLC data is stored in SQLite at `./data/collector.db` with tables:
- `candles_1m` - 1-minute candles
- `candles_5m` - 5-minute candles
- `candles_30m` - 30-minute candles

## API

The collector exposes price data through the `MarketCollector` class:

```typescript
import { MarketCollector } from './collector';
import { config } from './config';

const collector = new MarketCollector(config.tickers);
await collector.start();

// Get latest aggregated price
const ethPrice = collector.getLatestPrice('agg:spot:ETHUSDT');
```

## Architecture

- `collector.ts` - Main collector service with exchange polling
- `storage.ts` - SQLite OHLC storage and historical data fetching
- `config.ts` - Configuration for tickers and exchanges
- `types.ts` - TypeScript type definitions
