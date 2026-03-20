/**
 * Example: Running a circuit breaker guardian
 * This monitors for de-pegging events and triggers circuit breakers
 */

import { CircuitBreakerGuardian, type OracleProvider, type PricePoint } from '../src/guardians/circuit-breaker.js';
import { AIMM_ABI } from '../src/abis/AIMM.js';
import type { Address, Eip1193Provider } from '../src/eth/types.js';
import { logger } from '../src/utils/logger.js';

const log = logger.withContext('circuitBreakerGuardian');

// Simple oracle provider implementation using Binance
class BinanceOracleProvider implements OracleProvider {
  async getPrice(asset: Address): Promise<bigint> {
    // Map addresses to Binance symbols
    const symbolMap: Record<string, string> = {
      '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48': 'USDC',
      '0x6B175474E89094C44Da98b954EedeAC495271d0F': 'DAI',
      '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2': 'ETH',
      '0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0': 'wstETH',
    };

    const symbol = symbolMap[asset.toLowerCase()];
    if (!symbol) throw new Error(`Unknown asset: ${asset}`);

    // For stablecoins, return 1.0
    if (symbol === 'USDC' || symbol === 'DAI') {
      return 10n ** 18n; // 1.0 in 1e18
    }

    // For others, fetch from Binance
    const response = await fetch(
      `https://api.binance.com/api/v3/ticker/price?symbol=${symbol}USDT`
    );
    const data = await response.json();
    const price = parseFloat(data.price);

    return BigInt(Math.floor(price * 10 ** 18));
  }

  async getHistoricalPrices(
    asset: Address,
    fromTimestamp: number,
    toTimestamp: number
  ): Promise<PricePoint[]> {
    // Simplified implementation - in production, use proper historical data
    const symbolMap: Record<string, string> = {
      '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2': 'ETHUSDT',
      '0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0': 'ETHUSDT', // Use ETH as proxy for wstETH
    };

    const symbol = symbolMap[asset.toLowerCase()];
    if (!symbol) throw new Error(`Unknown asset: ${asset}`);

    // Fetch klines (candlestick data)
    const response = await fetch(
      `https://api.binance.com/api/v3/klines?symbol=${symbol}&interval=1d&startTime=${fromTimestamp * 1000}&endTime=${toTimestamp * 1000}`
    );
    const klines = await response.json();

    return klines.map((kline: any) => ({
      timestamp: Math.floor(kline[0] / 1000),
      price: BigInt(Math.floor(parseFloat(kline[4]) * 10 ** 18)), // Close price
    }));
  }
}

async function main() {
  log.info('Starting Circuit Breaker Guardian...\n');

  // Setup EIP-1193 provider
  const rpcUrl = process.env.RPC_URL || 'https://eth.llamarpc.com';
  const provider: Eip1193Provider = {
    request: async (args: { method: string; params: any[] }) => {
      const response = await fetch(rpcUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          jsonrpc: '2.0',
          method: args.method,
          params: args.params,
          id: 1,
        }),
      });
      const data = await response.json();
      if (data.error) throw new Error(data.error.message);
      return data.result;
    },
  };

  const oracleProvider = new BinanceOracleProvider();

  // Configure guardian
  const guardian = new CircuitBreakerGuardian(
    provider,
    {
      poolAddress: process.env.POOL_ADDRESS as `0x${string}`,
      assets: [
        {
          address: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', // USDC
          name: 'USDC',
          referenceAsset: '0x6B175474E89094C44Da98b954EedeAC495271d0F', // DAI
          maxDivergence: 100, // 1% - freeze if USDC deviates > 1% from DAI
        },
        {
          address: '0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0', // wstETH
          name: 'wstETH',
          referenceAsset: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2', // WETH
          maxDivergence: 300, // 3% - freeze if weekly relative change differs by > 3%
        },
      ],
      checkInterval: 300000, // Check every 5 minutes
      cooldownPeriod: 3600, // 1 hour cooldown
      maxDivergence: 0, // Not used here, per-asset configs are used
    },
    AIMM_ABI,
    oracleProvider
  );

  // Start monitoring (runs indefinitely)
  // The guardian will:
  // 1. Check each asset every 5 minutes
  // 2. For stablecoins: Compare direct prices
  // 3. For correlated assets: Compare weekly relative changes
  // 4. Trigger circuit breaker if thresholds exceeded
  await guardian.start();

  // Graceful shutdown on SIGINT
  process.on('SIGINT', () => {
    log.info('\nShutting down guardian...');
    guardian.stop();
    process.exit(0);
  });
}

main().catch((error) => {
  log.error('Fatal error:', error);
  process.exit(1);
});
