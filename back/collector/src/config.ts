/**
 * Market data collector configuration
 */

import type { CollectorConfig } from './types';

export const config: CollectorConfig = {
  pollIntervalMs: 1000,
  tickers: {
    'agg:spot:BTCUSDT': {
      id: 'agg:spot:BTCUSDT',
      name: 'BTC/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:BTCUSDT': { weight: 0.4 },
        'bybit:spot:BTCUSDT': { weight: 0.25 },
        'okx:spot:BTC-USDT': { weight: 0.2 },
        'bitget:spot:BTCUSDT': { weight: 0.15 }
      }
    },
    'agg:spot:ETHUSDT': {
      id: 'agg:spot:ETHUSDT',
      name: 'ETH/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:ETHUSDT': { weight: 0.4 },
        'bybit:spot:ETHUSDT': { weight: 0.25 },
        'okx:spot:ETH-USDT': { weight: 0.2 },
        'gate:spot:ETH_USDT': { weight: 0.15 }
      }
    },
    'agg:spot:SOLUSDT': {
      id: 'agg:spot:SOLUSDT',
      name: 'SOL/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:SOLUSDT': { weight: 0.4 },
        'bybit:spot:SOLUSDT': { weight: 0.25 },
        'okx:spot:SOL-USDT': { weight: 0.2 },
        'gate:spot:SOL_USDT': { weight: 0.15 }
      }
    },
    'agg:spot:BNBUSDT': {
      id: 'agg:spot:BNBUSDT',
      name: 'BNB/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:BNBUSDT': { weight: 0.55 },
        'htx:spot:bnbusdt': { weight: 0.2 },
        'mexc:spot:BNBUSDT': { weight: 0.15 },
        'bybit:spot:BNBUSDT': { weight: 0.1 },
      }
    },
    'agg:spot:HYPEUSDT': {
      id: 'agg:spot:HYPEUSDT',
      name: 'HYPE/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'bybit:spot:HYPEUSDT': { weight: 0.4 },
        'gate:spot:HYPE_USDT': { weight: 0.25 },
        'mexc:spot:HYPEUSDT': { weight: 0.2 },
        'okx:spot:HYPE-USDT': { weight: 0.15 }
      }
    },
    'agg:spot:SUIUSDT': {
      id: 'agg:spot:SUIUSDT',
      name: 'SUI/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:SUIUSDT': { weight: 0.4 },
        'htx:spot:suiusdt': { weight: 0.3 },
        'okx:spot:SUI-USDT': { weight: 0.15 },
        'bybit:spot:SUIUSDT': { weight: 0.15 }
      }
    },
    'agg:spot:ZECUSDT': {
      id: 'agg:spot:ZECUSDT',
      name: 'ZEC/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:ZECUSDT': { weight: 0.6 },
        'mexc:spot:ZECUSDT': { weight: 0.2 },
        'okx:spot:ZEC-USDT': { weight: 0.1 },
        'htx:spot:zecusdt': { weight: 0.1 }
      }
    },
    'agg:spot:USDCUSDT': {
      id: 'agg:spot:USDCUSDT',
      name: 'USDC/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:USDCUSDT': { weight: 0.4 },
        'bybit:spot:USDCUSDT': { weight: 0.25 },
        'okx:spot:USDC-USDT': { weight: 0.2 },
        'mexc:spot:USDCUSDT': { weight: 0.15 }
      }
    },
    'agg:spot:USDEUSDT': {
      id: 'agg:spot:USDEUSDT',
      name: 'USDE/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'bybit:spot:USDEUSDT': { weight: 0.4 },
        'mexc:spot:USDEUSDT': { weight: 0.25 },
        'gate:spot:USDE_USDT': { weight: 0.2 },
        'bitget:spot:USDEUSDT': { weight: 0.15 }
      }
    },
    'agg:spot:DAIUSDT': {
      id: 'agg:spot:DAIUSDT',
      name: 'DAI/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:USDTDAI': { weight: 0.4 },
        'mexc:spot:DAIUSDT': { weight: 0.25 },
        'htx:spot:daiusdt': { weight: 0.2 },
        'okx:spot:DAI-USDT': { weight: 0.15 }
      }
    },
    // 'agg:spot:1INCHUSDT': {
    //   id: 'agg:spot:1INCHUSDT',
    //   name: '1INCH/USDT Aggregate',
    //   tf: 60,
    //   lookback: 86400,
    //   sources: {
    //     'binance:spot:1INCHUSDT': { weight: 0.4 },
    //     'okx:spot:1INCH-USDT': { weight: 0.25 },
    //     'gate:spot:1INCH_USDT': { weight: 0.2 },
    //     'mexc:spot:1INCHUSDT': { weight: 0.15 }
    //   }
    // },
    'agg:spot:AAVEUSDT': {
      id: 'agg:spot:AAVEUSDT',
      name: 'AAVE/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:AAVEUSDT': { weight: 0.4 },
        'bybit:spot:AAVEUSDT': { weight: 0.25 },
        'htx:spot:aaveusdt': { weight: 0.2 },
        'gate:spot:AAVE_USDT': { weight: 0.15 }
      }
    },
    'agg:spot:MORPHOUSDT': {
      id: 'agg:spot:MORPHOUSDT',
      name: 'MORPHO/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:MORPHOUSDT': { weight: 0.4 },
        'gate:spot:MORPHO_USDT': { weight: 0.2 },
        'okx:spot:MORPHO-USDT': { weight: 0.2 },
        'bybit:spot:MORPHOUSDT': { weight: 0.2 },
      }
    },
    'agg:spot:ENAUSDT': {
      id: 'agg:spot:ENAUSDT',
      name: 'ENA/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:ENAUSDT': { weight: 0.4 },
        'mexc:spot:ENAUSDT': { weight: 0.25 },
        'bybit:spot:ENAUSDT': { weight: 0.2 },
        'gate:spot:ENA_USDT': { weight: 0.15 }
      }
    },
    'agg:spot:UNIUSDT': {
      id: 'agg:spot:UNIUSDT',
      name: 'UNI/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:UNIUSDT': { weight: 0.4 },
        'okx:spot:UNI-USDT': { weight: 0.25 },
        'gate:spot:UNI_USDT': { weight: 0.2 },
        'bybit:spot:UNIUSDT': { weight: 0.15 }
      }
    },
    'agg:spot:CAKEUSDT': {
      id: 'agg:spot:CAKEUSDT',
      name: 'CAKE/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:CAKEUSDT': { weight: 0.4 },
        'mexc:spot:CAKEUSDT': { weight: 0.25 },
        'htx:spot:cakeusdt': { weight: 0.2 },
        'gate:spot:CAKE_USDT': { weight: 0.15 }
      }
    },
    'agg:spot:CRVUSDT': {
      id: 'agg:spot:CRVUSDT',
      name: 'CRV/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:CRVUSDT': { weight: 0.4 },
        'okx:spot:CRV-USDT': { weight: 0.2 },
        'bybit:spot:CRVUSDT': { weight: 0.2 },
        'gate:spot:CRV_USDT': { weight: 0.2 },
      }
    },
    'agg:spot:PENDLEUSDT': {
      id: 'agg:spot:PENDLEUSDT',
      name: 'PENDLE/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:PENDLEUSDT': { weight: 0.4 },
        'bybit:spot:PENDLEUSDT': { weight: 0.25 },
        'mexc:spot:PENDLEUSDT': { weight: 0.2 },
        'gate:spot:PENDLE_USDT': { weight: 0.15 }
      }
    },
    'agg:spot:LINKUSDT': {
      id: 'agg:spot:LINKUSDT',
      name: 'LINK/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:LINKUSDT': { weight: 0.4 },
        'bybit:spot:LINKUSDT': { weight: 0.25 },
        'mexc:spot:LINKUSDT': { weight: 0.2 },
        'gate:spot:LINK_USDT': { weight: 0.15 }
      }
    },
    'agg:spot:ZROUSDT': {
      id: 'agg:spot:ZROUSDT',
      name: 'ZRO/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:ZROUSDT': { weight: 0.4 },
        'bybit:spot:ZROUSDT': { weight: 0.25 },
        'mexc:spot:ZROUSDT': { weight: 0.2 },
        'gate:spot:ZRO_USDT': { weight: 0.15 }
      }
    },
    'agg:spot:AXLUSDT': {
      id: 'agg:spot:AXLUSDT',
      name: 'AXL/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:AXLUSDT': { weight: 0.4 },
        'bybit:spot:AXLUSDT': { weight: 0.25 },
        'htx:spot:waxlusdt': { weight: 0.2 },
        'bitget:spot:AXLUSDT': { weight: 0.15 }
      }
    }, 
    'agg:spot:XAUTUSDT': {
      id: 'agg:spot:XAUTUSDT',
      name: 'XAU/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'bybit:spot:XAUTUSDT': { weight: 0.4 },
        'htx:spot:xautusdt': { weight: 0.25 },
        'okx:spot:XAUT-USDT': { weight: 0.20 },
        'gate:spot:XAUT_USDT': { weight: 0.15 }
      }
    },
    'agg:spot:PAXGUSDT': {
      id: 'agg:spot:PAXGUSDT',
      name: 'PAXG/USDT Aggregate',
      tf: 60,
      lookback: 86400,
      sources: {
        'binance:spot:PAXGUSDT': { weight: 0.5 },
        'mexc:spot:PAXGUSDT': { weight: 0.3 },
        'okx:spot:PAXG-USDT': { weight: 0.1 },
        'gate:spot:PAXG_USDT': { weight: 0.1 }
      }
    }
  }
};

export const STORAGE_CONFIG = {
  dbPath: './data/collector.db',
  storedTimeframes: [60, 300, 900, 1800, 3600, 14400, 43200], // M1, M5, M15, M30, H1, H4, H12
  historicalDataDays: 3 // Reduced for faster testing
};

/**
 * Token wrapper aliases - maps wrapper tokens to their underlying asset
 * Frontend can request WETHUSDC and backend transparently returns ETHUSDT data
 */
export const TOKEN_ALIASES: Record<string, string> = {
  // Wrapped ETH variants
  'WETH': 'ETH',
  'UETH': 'ETH',

  // Wrapped BTC variants
  'WBTC': 'BTC',
  'CBBTC': 'BTC',
  'TBTC': 'BTC',
  'UBTC': 'BTC',
  'BTCB': 'BTC',
};

/**
 * Resolve token aliases in a trading pair
 * Examples:
 *   WETHUSDC -> ETHUSDT  (handles USDC->USDT too)
 *   WBTCUSDT -> BTCUSDT
 *   agg:spot:WETHUSDC -> agg:spot:ETHUSDT
 */
export function resolveAlias(pair: string): string {
  // Extract prefix (agg:spot:) if present
  const parts = pair.split(':');
  const actualPair = parts[parts.length - 1];
  const prefix = parts.slice(0, -1).join(':');

  // Try to match common patterns: BASEUSDT, BASEUSDC, BASE/USDT, etc.
  const match = actualPair.match(/^([A-Z0-9]+?)(USDT|USDC|USDE|DAI|USD)$/i);
  if (!match) {
    // Try slash format: BASE/QUOTE
    const slashMatch = actualPair.match(/^([A-Z0-9]+)\/([A-Z0-9]+)$/i);
    if (slashMatch) {
      const [_, base, quote] = slashMatch;
      const resolvedBase = TOKEN_ALIASES[base.toUpperCase()] || base;
      const resolvedQuote = TOKEN_ALIASES[quote.toUpperCase()] || quote;
      const resolved = `${resolvedBase}${resolvedQuote}`;
      return prefix ? `${prefix}:${resolved}` : resolved;
    }
    return pair; // No pattern match, return as-is
  }

  const [_, base, quote] = match;

  // Resolve base token alias
  const resolvedBase = TOKEN_ALIASES[base.toUpperCase()] || base;

  // Normalize quote to USDT (our canonical denomination)
  const resolvedQuote = quote.toUpperCase() === 'USDC' ? 'USDT' : quote.toUpperCase();

  const resolved = `${resolvedBase}${resolvedQuote}`;
  return prefix ? `${prefix}:${resolved}` : resolved;
}
