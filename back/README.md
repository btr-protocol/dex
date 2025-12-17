# BTR DEX Backend

Central backend services for the BTR DEX platform.

## Structure

```
back/
├── collector/          # Market data collector with OHLC caching
├── .env.example       # Backend configuration template
└── README.md          # This file
```

## Services

### Collector

Market data collection service with OHLC caching. Fetches and caches market data from various sources.

**Development:**
```bash
bun --watch collector/src/index.ts
```

**Production:**
```bash
bun collector/src/index.ts
```

## Configuration

Copy `.env.example` to `.env` and configure backend settings:

```bash
cp .env.example .env
```

Available variables:
- `COLLECTOR_PORT` - Port for collector service (default: 3001)
- `COLLECTOR_HOST` - Host for collector service (default: localhost)
- `DATA_DIR` - Directory for data storage (default: ./data)
- `CACHE_INTERVAL` - Cache update interval in ms (default: 60000)
- `DEFAULT_TIMEFRAME` - Default timeframe for data (default: 1h)
- `LOG_LEVEL` - Logging level (default: info)

## Development

Start all services (frontend + backend):

```bash
cd front && bun run dev
```

Or from project root:

```bash
bun run dev --cwd front
```

## Adding New Services

When adding new backend services:

1. Create a new folder under `back/`
2. Add configuration to `.env.example`
3. Update this README with service documentation
4. Update `scripts/dev.sh` to include the new service
